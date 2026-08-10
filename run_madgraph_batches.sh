#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s nullglob

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"

# Ajusta estos valores antes de correr.
MG_DIR="${MG_DIR:-$HOME/tools/Madgraph}"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_DIR/Analysis/rootfiles/madgraph_batches}"
# 150 fb^-1 = 150 * 1000 pb^-1. Mantener R0_VALUES en pb.
LUMINOSITY="${LUMINOSITY:-150000}"
# Cantidad generada por modelo: ceil(LUMINOSITY * R0 / EVENT_WEIGHT_TARGET).
# EVENT_WEIGHT_TARGET=1 genera aproximadamente L*R0 eventos; 5 genera 1/5 de eso.
EVENT_WEIGHT_TARGET="${EVENT_WEIGHT_TARGET:-5}"
# Si RUNS_PER_MODEL=0, EVENTS_PER_RUN es el maximo por run para partir automaticamente.
EVENTS_PER_RUN="${EVENTS_PER_RUN:-50000}"
RUNS_PER_MODEL="${RUNS_PER_MODEL:-0}"
START_SEED="${START_SEED:-1}"
# Con MG_NB_CORE=8, PARALLEL_JOBS=1 evita saturar un Mac de 10 cores.
# Si quieres varios modelos a la vez, baja MG_NB_CORE o sube PARALLEL_JOBS conscientemente.
PARALLEL_JOBS="${PARALLEL_JOBS:-1}"
KEEP_FAILED_WORKDIRS="${KEEP_FAILED_WORKDIRS:-1}"
RESUME="${RESUME:-1}"
FORCE_RERUN="${FORCE_RERUN:-0}"
AUTO_R0_EVENTS="${AUTO_R0_EVENTS:-10000}"
AUTO_R0_LASTSTEP="${AUTO_R0_LASTSTEP:-parton}"
# Vacio = dejar que MadGraph decida segun las cards/configuracion.
# Usa LASTSTEP=parton si quieres solo LHE, o LASTSTEP=delphes si tu MG tiene esa cadena configurada.
LASTSTEP="${LASTSTEP:-}"
RUN_PREFIX="${RUN_PREFIX:-batch}"
DRY_RUN="${DRY_RUN:-0}"
PROGRESS_WIDTH="${PROGRESS_WIDTH:-30}"
PROGRESS_INTERVAL="${PROGRESS_INTERVAL:-60}"
DISABLE_SYSTEMATICS="${DISABLE_SYSTEMATICS:-0}"
# MadGraph multicore: equivalente a `set run_mode 2`, `set nb_core 8`, `save options`.
# Para run serio sin usar el Mac: MG_NB_CORE=10. Para paralelizar modelos: usa algo como PARALLEL_JOBS=2 MG_NB_CORE=4.
MG_RUN_MODE="${MG_RUN_MODE:-2}"
MG_NB_CORE="${MG_NB_CORE:-8}"

JOB_PIDS=()
PROGRESS_MONITOR_PID=""
PROGRESS_ROOT=""

# Arreglo de modelos/procesos ya generados en MadGraph.
# Cada entrada debe tener una seccion eficaz R0 en la misma posicion.
MODELS=(
  "TTbar"
  "VV_new"
  "Wjets"
)

# R0: seccion eficaz por modelo en pb. Usa "auto" para medirla con una corrida piloto.
R0_VALUES=(
  "auto"
  "auto"
  "auto"
)

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

handle_interrupt() {
  local pid

  log "Interrupcion recibida; deteniendo jobs activos. Puedes reanudar con el mismo comando."
  if [[ -n "$PROGRESS_MONITOR_PID" ]]; then
    kill "$PROGRESS_MONITOR_PID" 2>/dev/null || true
  fi
  for pid in "${JOB_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  exit 130
}

trap handle_interrupt INT TERM

event_weight_for_lumi() {
  awk -v lumi="$1" -v r0="$2" -v generated="$3" '
    BEGIN {
      if (generated <= 0) {
        exit 2
      }
      printf "%.12g\n", (lumi * r0) / generated
    }'
}

expected_events_for_lumi() {
  awk -v lumi="$1" -v r0="$2" '
    BEGIN {
      printf "%.12g\n", lumi * r0
    }'
}

generated_events_for_lumi() {
  awk -v lumi="$1" -v r0="$2" -v target_weight="$3" '
    BEGIN {
      if (target_weight <= 0) {
        exit 2
      }
      n = (lumi * r0) / target_weight
      if (n <= 0) {
        print 0
      } else {
        print int(n) + (n > int(n))
      }
    }'
}

ceil_div() {
  awk -v numerator="$1" -v denominator="$2" '
    BEGIN {
      if (denominator <= 0) {
        exit 2
      }
      print int((numerator + denominator - 1) / denominator)
    }'
}

progress_init() {
  local progress_root="$1"

  PROGRESS_ROOT="$progress_root/progress"
  mkdir -p "$PROGRESS_ROOT/done" "$PROGRESS_ROOT/running"
  : > "$PROGRESS_ROOT/plan.tsv"
}

progress_add_plan() {
  local model="$1"
  local total_events="$2"
  local total_runs="$3"

  [[ -n "$PROGRESS_ROOT" ]] || return 0
  mkdir -p "$PROGRESS_ROOT/done/$model" "$PROGRESS_ROOT/running/$model"
  printf '%s\t%s\t%s\n' "$model" "$total_events" "$total_runs" >> "$PROGRESS_ROOT/plan.tsv"
}

progress_write_run_state() {
  local state="$1"
  local model="$2"
  local run_name="$3"
  local events="$4"
  local start_epoch="${5:-0}"
  local duration_seconds="${6:-0}"
  local dir="$PROGRESS_ROOT/$state/$model"
  local tmp

  [[ -n "$PROGRESS_ROOT" ]] || return 0
  mkdir -p "$dir"
  tmp="$(mktemp "$dir/.${run_name}.XXXXXX")"
  printf '%s\t%s\t%s\t%s\t%s\n' "$run_name" "$state" "$events" "$start_epoch" "$duration_seconds" > "$tmp"
  mv "$tmp" "$dir/$run_name.tsv"
}

progress_clear_run_state() {
  local state="$1"
  local model="$2"
  local run_name="$3"

  [[ -n "$PROGRESS_ROOT" ]] || return 0
  rm -f "$PROGRESS_ROOT/$state/$model/$run_name.tsv"
}

progress_sum_events() {
  local state="$1"
  local model="$2"
  local dir="$PROGRESS_ROOT/$state/$model"
  local -a files

  [[ -d "$dir" ]] || {
    printf '0\t0\n'
    return
  }

  files=("$dir"/*.tsv)
  [[ "${#files[@]}" -gt 0 ]] || {
    printf '0\t0\n'
    return
  }

  awk -F '\t' -v state="$state" -v now="$(date '+%s')" '
    {
      runs += 1
      events += $3
      if (state == "running" && $4 > 0) {
        elapsed = now - $4
        if (elapsed < 0) {
          elapsed = 0
        }
        duration += elapsed
        timed_runs += 1
      } else if ($5 > 0) {
        duration += $5
        timed_runs += 1
      }
    }
    END { printf "%d\t%d\t%d\t%d\n", events, runs, duration, timed_runs }' "${files[@]}"
}

format_duration() {
  local seconds="$1"

  awk -v seconds="$seconds" '
    BEGIN {
      if (seconds < 0) {
        seconds = 0
      }
      days = int(seconds / 86400)
      seconds %= 86400
      hours = int(seconds / 3600)
      seconds %= 3600
      minutes = int(seconds / 60)
      seconds = int(seconds % 60)
      if (days > 0) {
        printf "%dd %02dh %02dm", days, hours, minutes
      } else if (hours > 0) {
        printf "%dh %02dm %02ds", hours, minutes, seconds
      } else if (minutes > 0) {
        printf "%dm %02ds", minutes, seconds
      } else {
        printf "%ds", seconds
      }
    }'
}

progress_rate_stats() {
  local done_events="$1"
  local done_duration="$2"
  local timed_runs="$3"
  local remaining_events="$4"

  awk -v events="$done_events" -v duration="$done_duration" -v timed_runs="$timed_runs" -v remaining="$remaining_events" '
    BEGIN {
      if (duration > 0 && timed_runs > 0 && events > 0) {
        eps = events / duration
        sec_per_event = duration / events
        avg_run = duration / timed_runs
        eta = remaining / eps
        printf "%.2f\t%.6f\t%.0f\t%.0f", eps, sec_per_event, avg_run, eta
      } else {
        printf "NA\tNA\tNA\tNA"
      }
    }'
}

progress_bar() {
  local done_events="$1"
  local running_events="$2"
  local total_events="$3"

  awk -v done="$done_events" -v running="$running_events" -v total="$total_events" -v width="$PROGRESS_WIDTH" '
    BEGIN {
      pct = total > 0 ? (100 * done / total) : 100
      active_pct = total > 0 ? (100 * (done + running) / total) : 100
      if (pct > 100) {
        pct = 100
      }
      if (active_pct > 100) {
        active_pct = 100
      }
      filled = int(width * pct / 100)
      active_filled = int(width * active_pct / 100)
      if (active_filled < filled) {
        active_filled = filled
      }
      bar = ""
      for (i = 0; i < filled; i++) {
        bar = bar "#"
      }
      for (i = filled; i < active_filled; i++) {
        bar = bar "+"
      }
      for (i = active_filled; i < width; i++) {
        bar = bar "-"
      }
      printf "%s\t%.2f", bar, pct
    }'
}

progress_print_locked() {
  local reason="$1"
  local timestamp

  [[ -n "$PROGRESS_ROOT" && -f "$PROGRESS_ROOT/plan.tsv" ]] || return 0
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '[%s] Progreso: %s\n' "$timestamp" "$reason" >&2

  while IFS=$'\t' read -r model total_events total_runs; do
    local done_stats
    local running_stats
    local done_events
    local done_runs
    local done_duration
    local timed_runs
    local running_events
    local running_runs
    local running_duration
    local running_timed_runs
    local bar_stats
    local bar
    local pct
    local remaining_events
    local rate_stats
    local events_per_second
    local seconds_per_event
    local avg_run_seconds
    local eta_seconds
    local avg_run_text
    local eta_text
    local active_avg_seconds
    local active_avg_text

    [[ -n "$model" ]] || continue
    done_stats="$(progress_sum_events done "$model")"
    running_stats="$(progress_sum_events running "$model")"
    IFS=$'\t' read -r done_events done_runs done_duration timed_runs <<< "$done_stats"
    IFS=$'\t' read -r running_events running_runs running_duration running_timed_runs <<< "$running_stats"
    bar_stats="$(progress_bar "$done_events" "$running_events" "$total_events")"
    bar="${bar_stats%%$'\t'*}"
    pct="${bar_stats#*$'\t'}"
    remaining_events=$((total_events - done_events))
    if [[ "$remaining_events" -lt 0 ]]; then
      remaining_events=0
    fi
    rate_stats="$(progress_rate_stats "$done_events" "$done_duration" "$timed_runs" "$remaining_events")"
    IFS=$'\t' read -r events_per_second seconds_per_event avg_run_seconds eta_seconds <<< "$rate_stats"

    printf '  %-12s [%s] %6s%%  %d/%d eventos  (%d/%d runs, activos: %d runs / %d eventos)\n' \
      "$model" "$bar" "$pct" "$done_events" "$total_events" "$done_runs" "$total_runs" "$running_runs" "$running_events" >&2
    if [[ "$running_runs" -gt 0 && "$running_duration" -gt 0 ]]; then
      active_avg_seconds=$((running_duration / running_runs))
      active_avg_text="$(format_duration "$active_avg_seconds")"
      printf '  %-12s activos_promedio=%s\n' "" "$active_avg_text" >&2
    fi
    if [[ "$events_per_second" != "NA" ]]; then
      avg_run_text="$(format_duration "$avg_run_seconds")"
      eta_text="$(format_duration "$eta_seconds")"
      printf '  %-12s tasa=%s eventos/s  %.6fs/evento  avg/run=%s  ETA=%s  muestras=%d\n' \
        "" "$events_per_second" "$seconds_per_event" "$avg_run_text" "$eta_text" "$timed_runs" >&2
    else
      printf '  %-12s tasa=pendiente  ETA=pendiente  muestras=%d\n' "" "$timed_runs" >&2
    fi
  done < "$PROGRESS_ROOT/plan.tsv"
}

progress_print() {
  local reason="$1"
  local lock_dir

  [[ -n "$PROGRESS_ROOT" ]] || return 0
  lock_dir="$PROGRESS_ROOT/.lock"
  while ! mkdir "$lock_dir" 2>/dev/null; do
    sleep 0.1
  done
  progress_print_locked "$reason"
  rmdir "$lock_dir"
}

adopt_legacy_archive() {
  local model="$1"
  local run_name="$2"
  local archive_dir="$OUTPUT_DIR/$model/$run_name"
  local legacy_dir="$OUTPUT_DIR/$run_name"

  [[ -d "$legacy_dir" ]] || return 0
  [[ ! -e "$archive_dir" ]] || return 0
  [[ "$DRY_RUN" != "1" ]] || return 0

  mkdir -p "$OUTPUT_DIR/$model"
  mv "$legacy_dir" "$archive_dir"
  log "$model: movi salida legacy $legacy_dir -> $archive_dir"
}

start_progress_monitor() {
  [[ -n "$PROGRESS_ROOT" ]] || return 0
  [[ "$PROGRESS_INTERVAL" -gt 0 ]] || return 0

  (
    while true; do
      sleep "$PROGRESS_INTERVAL"
      progress_print "actualizacion periodica"
    done
  ) &
  PROGRESS_MONITOR_PID="$!"
}

stop_progress_monitor() {
  if [[ -n "$PROGRESS_MONITOR_PID" ]]; then
    kill "$PROGRESS_MONITOR_PID" 2>/dev/null || true
    wait "$PROGRESS_MONITOR_PID" 2>/dev/null || true
    PROGRESS_MONITOR_PID=""
  fi
}

card_has_param() {
  local card="$1"
  local param="$2"

  [[ -f "$card" ]] || return 1
  awk -v param="$param" '
    {
      line = $0
      sub(/[!#].*/, "", line)
      if (line ~ "=[[:space:]]*" param "([[:space:]]|$)") {
        found = 1
      }
    }
    END { exit found ? 0 : 1 }' "$card"
}

set_card_param() {
  local card="$1"
  local param="$2"
  local value="$3"
  local tmp

  tmp="$(mktemp "${TMPDIR:-/tmp}/mgcard.XXXXXX")"
  awk -v param="$param" -v value="$value" '
    {
      original = $0
      code = original
      sub(/[!#].*/, "", code)
      if (code ~ "=[[:space:]]*" param "([[:space:]]|$)") {
        comment = ""
        if (match(original, /[!#].*/)) {
          comment = substr(original, RSTART)
        }
        printf "  %s = %s", value, param
        if (comment != "") {
          printf " %s", comment
        }
        printf "\n"
        updated = 1
      } else {
        print original
      }
    }
    END { exit updated ? 0 : 42 }' "$card" > "$tmp" || {
      local status=$?
      rm -f "$tmp"
      return "$status"
    }

  mv "$tmp" "$card"
}

set_mg_param() {
  local process_dir="$1"
  local param="$2"
  local value="$3"
  local run_card="$process_dir/Cards/run_card.dat"
  local param_card="$process_dir/Cards/param_card.dat"

  if card_has_param "$run_card" "$param"; then
    set_card_param "$run_card" "$param" "$value"
    return
  fi

  if card_has_param "$param_card" "$param"; then
    set_card_param "$param_card" "$param" "$value"
    return
  fi

  die "No encontre '$param' en run_card.dat ni param_card.dat para $process_dir"
}

set_optional_mg_param() {
  local process_dir="$1"
  local param="$2"
  local value="$3"
  local run_card="$process_dir/Cards/run_card.dat"
  local param_card="$process_dir/Cards/param_card.dat"

  if card_has_param "$run_card" "$param"; then
    set_card_param "$run_card" "$param" "$value"
    return
  fi

  if card_has_param "$param_card" "$param"; then
    set_card_param "$param_card" "$param" "$value"
    return
  fi
}

set_mg_config_value() {
  local process_dir="$1"
  local key="$2"
  local value="$3"
  local config="$process_dir/Cards/me5_configuration.txt"
  local tmp

  [[ -f "$config" ]] || return 0
  tmp="$(mktemp "${TMPDIR:-/tmp}/mgconfig.XXXXXX")"
  awk -v key="$key" -v value="$value" '
    {
      original = $0
      line = original
      sub(/#.*/, "", line)
      if (line ~ "^[[:space:]]*" key "[[:space:]]*=") {
        print key " = " value
        updated = 1
      } else if (!updated && original ~ "^[[:space:]]*#[[:space:]]*" key "[[:space:]]*=") {
        print key " = " value
        updated = 1
      } else {
        print original
      }
    }
    END {
      if (!updated) {
        print key " = " value
      }
    }' "$config" > "$tmp"
  mv "$tmp" "$config"
}

apply_speed_options() {
  local process_dir="$1"

  if [[ "$DISABLE_SYSTEMATICS" == "1" ]]; then
    set_optional_mg_param "$process_dir" "use_syst" "False"
  fi

  if [[ -n "$MG_RUN_MODE" ]]; then
    set_mg_config_value "$process_dir" "run_mode" "$MG_RUN_MODE"
  fi

  if [[ -n "$MG_NB_CORE" ]]; then
    set_mg_config_value "$process_dir" "nb_core" "$MG_NB_CORE"
  fi
}

safe_remove_run_dir() {
  local events_dir="$1"
  local run_dir="$2"
  local events_real
  local run_real

  [[ -d "$run_dir" ]] || return 0
  events_real="$(cd "$events_dir" && pwd -P)"
  run_real="$(cd "$run_dir" && pwd -P)"

  case "$run_real" in
    "$events_real/$RUN_PREFIX"_*)
      rm -rf "$run_dir"
      ;;
    *)
      die "Me rehuso a borrar una ruta inesperada: $run_dir"
      ;;
  esac
}

safe_remove_html_dir() {
  local html_root="$1"
  local html_dir="$2"
  local html_real
  local root_real

  [[ -d "$html_dir" ]] || return 0
  root_real="$(cd "$html_root" && pwd -P)"
  html_real="$(cd "$html_dir" && pwd -P)"

  case "$html_real" in
    "$root_real/$RUN_PREFIX"_*)
      rm -rf "$html_dir"
      ;;
    *)
      die "Me rehuso a borrar una ruta HTML inesperada: $html_dir"
      ;;
  esac
}

prepare_run_workdir() {
  local source_dir="$1"
  local model="$2"
  local run_name="$3"
  local work_root="$4"
  local work_dir="$work_root/${model}_${run_name}"

  mkdir -p "$work_root"
  rsync -a --delete \
    --exclude 'Events/*' \
    --exclude 'HTML/*' \
    "$source_dir/" "$work_dir/"
  mkdir -p "$work_dir/Events" "$work_dir/HTML"
  printf '%s\n' "$work_dir"
}

extract_cross_section_pb() {
  local run_dir="$1"
  local xsec

  xsec="$(
    find "$run_dir" -type f \( -name '*banner*.txt' -o -name '*.txt' -o -name '*.log' \) -print0 |
      xargs -0 grep -hE '(^|[^A-Za-z])Integrated weight[[:space:]]*\([[:space:]]*pb[[:space:]]*\)[[:space:]]*:' 2>/dev/null |
      grep -v 'Matched Integrated weight' |
      tail -n 1 |
      sed -E 's/.*:[[:space:]]*([+-]?[0-9]+([.][0-9]*)?([eE][+-]?[0-9]+)?).*/\1/'
  )"

  if [[ -z "$xsec" ]]; then
    xsec="$(
      find "$run_dir" -type f \( -name '*banner*.txt' -o -name '*.txt' -o -name '*.log' \) -print0 |
        xargs -0 grep -hE '^[[:space:]]*Cross-section[[:space:]]*:' 2>/dev/null |
        tail -n 1 |
        sed -E 's/.*:[[:space:]]*([+-]?[0-9]+([.][0-9]*)?([eE][+-]?[0-9]+)?).*/\1/'
    )"
  fi

  [[ -n "$xsec" ]] || return 1
  printf '%s\n' "$xsec"
}

r0_cache_file() {
  local model="$1"
  printf '%s/%s/_xsec/r0.tsv\n' "$OUTPUT_DIR" "$model"
}

read_cached_r0() {
  local model="$1"
  local cache_file
  local xsec

  cache_file="$(r0_cache_file "$model")"
  if [[ -f "$cache_file" ]]; then
    awk -F '\t' '$1 == "r0_pb" { print $2; found = 1; exit } END { exit found ? 0 : 1 }' "$cache_file"
    return
  fi

  xsec="$(
    find "$OUTPUT_DIR/$model/_xsec" -type f -name '*.log' -print0 2>/dev/null |
      xargs -0 grep -hE '(^|[^A-Za-z])Integrated weight[[:space:]]*\([[:space:]]*pb[[:space:]]*\)[[:space:]]*:|^[[:space:]]*Cross-section[[:space:]]*:' 2>/dev/null |
      grep -v 'Matched Integrated weight' |
      tail -n 1 |
      sed -E 's/.*:[[:space:]]*([+-]?[0-9]+([.][0-9]*)?([eE][+-]?[0-9]+)?).*/\1/'
  )"
  [[ -n "$xsec" ]] || return 1
  write_cached_r0 "$model" "$xsec"
  printf '%s\n' "$xsec"
}

write_cached_r0() {
  local model="$1"
  local r0="$2"
  local cache_file

  cache_file="$(r0_cache_file "$model")"
  mkdir -p "$(dirname "$cache_file")"
  {
    printf 'key\tvalue\n'
    printf 'r0_pb\t%s\n' "$r0"
    printf 'auto_r0_events\t%s\n' "$AUTO_R0_EVENTS"
    printf 'auto_r0_laststep\t%s\n' "$AUTO_R0_LASTSTEP"
    printf 'created_at\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  } > "$cache_file"
}

resolve_r0_value() {
  local model="$1"
  local r0_value="$2"
  local source_process_dir="$3"
  local work_root="$4"
  local seed="$5"
  local pilot_name
  local pilot_dir
  local pilot_log
  local run_cmd
  local xsec

  if [[ "$r0_value" != "auto" ]]; then
    printf '%s\n' "$r0_value"
    return
  fi

  if [[ "$RESUME" == "1" && "$FORCE_RERUN" != "1" ]]; then
    if xsec="$(read_cached_r0 "$model")"; then
      log "$model: R0 cacheado = $xsec pb"
      printf '%s\n' "$xsec"
      return
    fi
  fi

  pilot_name="$(printf '%s_xsec_%s_seed%s' "$RUN_PREFIX" "$model" "$seed")"
  log "$model: R0=auto -> corrida piloto $pilot_name con $AUTO_R0_EVENTS eventos"

  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY_RUN: mediria R0 con (cd $work_root/${model}_${pilot_name} && ./bin/generate_events $pilot_name -f --laststep=$AUTO_R0_LASTSTEP)"
    printf '1.0\n'
    return
  fi

  pilot_dir="$(prepare_run_workdir "$source_process_dir" "$model" "$pilot_name" "$work_root")"
  pilot_log="$pilot_dir/${pilot_name}.log"
  set_mg_param "$pilot_dir" "nevents" "$AUTO_R0_EVENTS"
  set_mg_param "$pilot_dir" "iseed" "$seed"
  apply_speed_options "$pilot_dir"

  run_cmd=(./bin/generate_events "$pilot_name" -f)
  if [[ -n "$AUTO_R0_LASTSTEP" ]]; then
    run_cmd+=("--laststep=$AUTO_R0_LASTSTEP")
  fi

  if ! (
      cd "$pilot_dir"
      "${run_cmd[@]}" > "$pilot_log" 2>&1
    ); then
    log "$model: fallo la corrida piloto para R0 en $pilot_dir"
    log "$model: log piloto: $pilot_log"
    if [[ "$KEEP_FAILED_WORKDIRS" != "1" ]]; then
      rm -rf "$pilot_dir"
    fi
    return 1
  fi

  xsec="$(extract_cross_section_pb "$pilot_dir/Events/$pilot_name")" || {
    log "$model: no pude extraer Integrated weight (pb) de $pilot_dir/Events/$pilot_name"
    log "$model: log piloto: $pilot_log"
    if [[ "$KEEP_FAILED_WORKDIRS" != "1" ]]; then
      rm -rf "$pilot_dir"
    fi
    return 1
  }

  log "$model: R0 medido = $xsec pb"
  write_cached_r0 "$model" "$xsec"
  mkdir -p "$OUTPUT_DIR/$model/_xsec"
  cp -p "$pilot_log" "$OUTPUT_DIR/$model/_xsec/${pilot_name}.log"
  rm -rf "$pilot_dir"
  printf '%s\n' "$xsec"
}

copy_tree_files() {
  local source_dir="$1"
  local target_dir="$2"
  shift 2

  [[ -d "$source_dir" ]] || return 0
  mkdir -p "$target_dir"

  while IFS= read -r file; do
    local rel
    local dest
    rel="${file#"$source_dir"/}"
    dest="$target_dir/$rel"
    mkdir -p "$(dirname "$dest")"
    cp -p "$file" "$dest"
  done < <(find "$source_dir" -type f "$@")
}

archive_run() {
  local model="$1"
  local process_dir="$2"
  local run_name="$3"
  local seed="$4"
  local events="$5"
  local lumi="$6"
  local r0="$7"
  local total_generated="$8"
  local event_weight="$9"
  local expected_events="${10}"
  local requested_runs="${11}"
  local actual_runs="${12}"
  local started_at_epoch="${13:-0}"
  local finished_at_epoch="${14:-0}"
  local duration_seconds="${15:-0}"
  local run_dir="$process_dir/Events/$run_name"
  local html_dir="$process_dir/HTML/$run_name"
  local archive_dir="$OUTPUT_DIR/$model/$run_name"
  local root_count
  local card

  [[ -d "$run_dir" ]] || die "MadGraph no creo el directorio esperado: $run_dir"

  mkdir -p "$archive_dir/root" "$archive_dir/metadata/Cards"

  root_count=0
  while IFS= read -r file; do
    local rel
    local dest
    rel="${file#"$run_dir"/}"
    dest="$archive_dir/root/$rel"
    mkdir -p "$(dirname "$dest")"
    cp -p "$file" "$dest"
    root_count=$((root_count + 1))
  done < <(find "$run_dir" -type f -name '*.root')

  if [[ "$root_count" -eq 0 ]]; then
    die "No encontre archivos ROOT en $run_dir; dejo el run sin borrar para inspeccion."
  fi

  copy_tree_files "$run_dir" "$archive_dir/metadata/Events" \
    \( -name '*.txt' -o -name '*.log' -o -name '*.dat' -o -name '*.html' -o -name '*.pkl' -o -name '*.json' \) \
    ! -name '*.lhe' ! -name '*.lhe.gz' ! -name '*.hepmc' ! -name '*.hepmc.gz'

  copy_tree_files "$html_dir" "$archive_dir/metadata/HTML" \
    \( -name '*.txt' -o -name '*.log' -o -name '*.dat' -o -name '*.html' -o -name '*.pkl' -o -name '*.json' \)

  for card in run_card.dat param_card.dat pythia8_card.dat delphes_card.dat; do
    if [[ -f "$process_dir/Cards/$card" ]]; then
      cp -p "$process_dir/Cards/$card" "$archive_dir/metadata/Cards/$card"
    fi
  done

  if [[ -f "$process_dir/$run_name.log" ]]; then
    cp -p "$process_dir/$run_name.log" "$archive_dir/metadata/$run_name.log"
  fi

  {
    printf 'key\tvalue\n'
    printf 'model\t%s\n' "$model"
    printf 'run_name\t%s\n' "$run_name"
    printf 'seed\t%s\n' "$seed"
    printf 'events_requested\t%s\n' "$events"
    printf 'expected_events_at_lumi\t%s\n' "$expected_events"
    printf 'total_events_generated_for_model\t%s\n' "$total_generated"
    printf 'luminosity\t%s\n' "$lumi"
    printf 'r0_cross_section\t%s\n' "$r0"
    printf 'event_weight_for_lumi\t%s\n' "$event_weight"
    printf 'event_weight_target\t%s\n' "$EVENT_WEIGHT_TARGET"
    printf 'events_per_run\t%s\n' "$EVENTS_PER_RUN"
    printf 'runs_per_model_requested\t%s\n' "$requested_runs"
    printf 'runs_per_model_actual\t%s\n' "$actual_runs"
    printf 'laststep\t%s\n' "$LASTSTEP"
    printf 'disable_systematics\t%s\n' "$DISABLE_SYSTEMATICS"
    printf 'mg_run_mode\t%s\n' "$MG_RUN_MODE"
    printf 'mg_nb_core\t%s\n' "$MG_NB_CORE"
    printf 'started_at_epoch\t%s\n' "$started_at_epoch"
    printf 'finished_at_epoch\t%s\n' "$finished_at_epoch"
    printf 'duration_seconds\t%s\n' "$duration_seconds"
    printf 'root_files\t%s\n' "$root_count"
    printf 'madgraph_dir\t%s\n' "$MG_DIR"
    printf 'process_dir\t%s\n' "$process_dir"
    printf 'created_at\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  } > "$archive_dir/metadata/summary.tsv"
}

run_is_complete() {
  local model="$1"
  local run_name="$2"
  local events="$3"
  local total_generated="$4"
  local archive_dir="$OUTPUT_DIR/$model/$run_name"
  local legacy_dir="$OUTPUT_DIR/$run_name"
  local summary="$archive_dir/metadata/summary.tsv"

  [[ "$RESUME" == "1" ]] || return 1
  [[ "$FORCE_RERUN" != "1" ]] || return 1
  adopt_legacy_archive "$model" "$run_name"
  if [[ ! -f "$summary" && -f "$legacy_dir/metadata/summary.tsv" ]]; then
    archive_dir="$legacy_dir"
    summary="$legacy_dir/metadata/summary.tsv"
  fi
  [[ -f "$summary" ]] || return 1
  [[ -n "$(find "$archive_dir/root" -type f -name '*.root' -print -quit 2>/dev/null)" ]] || return 1
  awk -F '\t' \
    -v events="$events" \
    -v total_generated="$total_generated" \
    -v target="$EVENT_WEIGHT_TARGET" '
      $1 == "events_requested" { got_events = $2 }
      $1 == "total_events_generated_for_model" { got_total = $2 }
      $1 == "event_weight_target" { got_target = $2 }
      END {
        exit (got_events == events && got_total == total_generated && got_target == target) ? 0 : 1
      }' "$summary"
}

run_duration_from_summary() {
  local model="$1"
  local run_name="$2"
  local archive_dir="$OUTPUT_DIR/$model/$run_name"
  local legacy_dir="$OUTPUT_DIR/$run_name"
  local summary="$archive_dir/metadata/summary.tsv"

  if [[ ! -f "$summary" && -f "$legacy_dir/metadata/summary.tsv" ]]; then
    summary="$legacy_dir/metadata/summary.tsv"
  fi

  [[ -f "$summary" ]] || {
    printf '0\n'
    return
  }

  awk -F '\t' '$1 == "duration_seconds" && $2 > 0 { print int($2); found = 1; exit } END { if (!found) print 0 }' "$summary"
}

events_for_batch() {
  local total_events="$1"
  local actual_runs="$2"
  local batch_number="$3"
  local remaining_events
  local run_start
  local run_end

  if [[ "$RUNS_PER_MODEL" -eq 0 ]]; then
    remaining_events=$((total_events - ((batch_number - 1) * EVENTS_PER_RUN)))
    if [[ "$remaining_events" -lt "$EVENTS_PER_RUN" ]]; then
      printf '%s\n' "$remaining_events"
    else
      printf '%s\n' "$EVENTS_PER_RUN"
    fi
  else
    run_start=$((((batch_number - 1) * total_events) / actual_runs))
    run_end=$(((batch_number * total_events) / actual_runs))
    printf '%s\n' "$((run_end - run_start))"
  fi
}

preload_completed_runs() {
  local model="$1"
  local total_events="$2"
  local actual_runs="$3"
  local model_start_seed="$4"
  local batch_number
  local completed_runs
  local completed_events

  completed_runs=0
  completed_events=0
  batch_number=1

  while [[ "$batch_number" -le "$actual_runs" ]]; do
    local run_seed
    local run_name
    local events_this_run
    local duration_seconds

    run_seed=$((model_start_seed + batch_number - 1))
    run_name="$(printf '%s_%s_%04d_seed%s' "$RUN_PREFIX" "$model" "$batch_number" "$run_seed")"
    events_this_run="$(events_for_batch "$total_events" "$actual_runs" "$batch_number")"

    if run_is_complete "$model" "$run_name" "$events_this_run" "$total_events"; then
      duration_seconds="$(run_duration_from_summary "$model" "$run_name")"
      progress_write_run_state done "$model" "$run_name" "$events_this_run" 0 "$duration_seconds"
      completed_runs=$((completed_runs + 1))
      completed_events=$((completed_events + events_this_run))
    fi

    batch_number=$((batch_number + 1))
  done

  if [[ "$completed_runs" -gt 0 ]]; then
    log "$model: resume encontro $completed_runs/$actual_runs runs completos ($completed_events/$total_events eventos)"
  fi
}

run_batch() {
  local batch_model="$1"
  local batch_r0="$2"
  local batch_number="$3"
  local seed="$4"
  local events="$5"
  local total_generated="$6"
  local event_weight="$7"
  local expected_events="$8"
  local requested_runs="$9"
  local actual_runs="${10}"
  local source_process_dir="${11}"
  local work_root="${12}"
  local process_dir
  local run_name
  local run_cmd
  local run_log
  local started_at_epoch
  local finished_at_epoch
  local duration_seconds

  run_name="$(printf '%s_%s_%04d_seed%s' "$RUN_PREFIX" "$batch_model" "$batch_number" "$seed")"

  if run_is_complete "$batch_model" "$run_name" "$events" "$total_generated"; then
    log "$batch_model: salto $run_name; ya existe ROOT + metadata"
    duration_seconds="$(run_duration_from_summary "$batch_model" "$run_name")"
    progress_write_run_state done "$batch_model" "$run_name" "$events" 0 "$duration_seconds"
    return
  fi

  log "$batch_model: lote $batch_number, eventos=$events, iseed=$seed, run=$run_name"

  if [[ "$DRY_RUN" == "1" ]]; then
    run_cmd=(./bin/generate_events "$run_name" -f)
    if [[ -n "$LASTSTEP" ]]; then
      run_cmd+=("--laststep=$LASTSTEP")
    fi
    log "DRY_RUN: copiaria $source_process_dir a $work_root/${batch_model}_${run_name}"
    log "DRY_RUN: set nevents=$events, iseed=$seed en la copia temporal"
    log "DRY_RUN: (cd $work_root/${batch_model}_${run_name} && ${run_cmd[*]})"
    return
  fi

  started_at_epoch="$(date '+%s')"
  progress_write_run_state running "$batch_model" "$run_name" "$events" "$started_at_epoch" 0
  progress_print "$batch_model/$run_name iniciado"

  process_dir="$(prepare_run_workdir "$source_process_dir" "$batch_model" "$run_name" "$work_root")"
  run_log="$process_dir/$run_name.log"
  run_cmd=(./bin/generate_events "$run_name" -f)
  if [[ -n "$LASTSTEP" ]]; then
    run_cmd+=("--laststep=$LASTSTEP")
  fi

  set_mg_param "$process_dir" "nevents" "$events"
  set_mg_param "$process_dir" "iseed" "$seed"
  apply_speed_options "$process_dir"

  if (
      cd "$process_dir"
      "${run_cmd[@]}" > "$run_log" 2>&1
    ); then
    finished_at_epoch="$(date '+%s')"
    duration_seconds=$((finished_at_epoch - started_at_epoch))
    archive_run "$batch_model" "$process_dir" "$run_name" "$seed" "$events" "$LUMINOSITY" "$batch_r0" "$total_generated" "$event_weight" "$expected_events" "$requested_runs" "$actual_runs" "$started_at_epoch" "$finished_at_epoch" "$duration_seconds"
    rm -rf "$process_dir"
    progress_clear_run_state running "$batch_model" "$run_name"
    progress_write_run_state done "$batch_model" "$run_name" "$events" "$started_at_epoch" "$duration_seconds"
    progress_print "$batch_model/$run_name completo"
  else
    log "$batch_model: fallo $run_name en $process_dir"
    log "$batch_model: log run: $run_log"
    progress_clear_run_state running "$batch_model" "$run_name"
    progress_print "$batch_model/$run_name fallo"
    if [[ "$KEEP_FAILED_WORKDIRS" != "1" ]]; then
      rm -rf "$process_dir"
    fi
    return 1
  fi
}

wait_for_available_slot() {
  local max_jobs="$1"

  while [[ "$(jobs -pr | wc -l | tr -d ' ')" -ge "$max_jobs" ]]; do
    sleep 1
  done
}

wait_for_all_jobs() {
  local status=0
  local pid

  for pid in "${JOB_PIDS[@]}"; do
    if ! wait "$pid"; then
      status=1
    fi
  done

  JOB_PIDS=()
  return "$status"
}

main() {
  local timestamp
  local work_root
  local seed
  local idx
  local grand_total_events
  local -a resolved_r0_values
  local -a planned_models
  local -a planned_r0_values
  local -a planned_process_dirs
  local -a planned_total_events
  local -a planned_expected_events
  local -a planned_event_weights
  local -a planned_actual_runs
  local -a planned_start_seeds
  local max_actual_runs
  local core_budget

  [[ -d "$MG_DIR" ]] || die "No existe MG_DIR=$MG_DIR"
  [[ -x "$MG_DIR/bin/mg5_aMC" ]] || die "No encontre $MG_DIR/bin/mg5_aMC ejecutable"
  command -v rsync >/dev/null || die "No encontre rsync; lo necesito para preparar copias temporales por run"
  [[ "${#MODELS[@]}" -eq "${#R0_VALUES[@]}" ]] || die "MODELS y R0_VALUES deben tener el mismo largo"
  [[ "$EVENT_WEIGHT_TARGET" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]] || die "EVENT_WEIGHT_TARGET debe ser numerico"
  [[ "$EVENTS_PER_RUN" =~ ^[0-9]+$ ]] || die "EVENTS_PER_RUN debe ser entero"
  [[ "$RUNS_PER_MODEL" =~ ^[0-9]+$ ]] || die "RUNS_PER_MODEL debe ser entero"
  [[ "$PARALLEL_JOBS" =~ ^[0-9]+$ ]] || die "PARALLEL_JOBS debe ser entero"
  [[ "$START_SEED" =~ ^[0-9]+$ ]] || die "START_SEED debe ser entero"
  [[ "$PROGRESS_INTERVAL" =~ ^[0-9]+$ ]] || die "PROGRESS_INTERVAL debe ser entero"
  [[ "$DISABLE_SYSTEMATICS" =~ ^[01]$ ]] || die "DISABLE_SYSTEMATICS debe ser 0 o 1"
  [[ -z "$MG_RUN_MODE" || "$MG_RUN_MODE" =~ ^[0-2]$ ]] || die "MG_RUN_MODE debe ser 0, 1 o 2"
  [[ -z "$MG_NB_CORE" || "$MG_NB_CORE" =~ ^[0-9]+$ ]] || die "MG_NB_CORE debe ser entero"
  [[ "$RESUME" =~ ^[01]$ ]] || die "RESUME debe ser 0 o 1"
  [[ "$FORCE_RERUN" =~ ^[01]$ ]] || die "FORCE_RERUN debe ser 0 o 1"
  awk -v value="$EVENT_WEIGHT_TARGET" 'BEGIN { exit (value > 0 ? 0 : 1) }' || die "EVENT_WEIGHT_TARGET debe ser mayor que cero"
  [[ "$EVENTS_PER_RUN" -gt 0 ]] || die "EVENTS_PER_RUN debe ser mayor que cero"
  [[ "$PARALLEL_JOBS" -gt 0 ]] || die "PARALLEL_JOBS debe ser mayor que cero"

  mkdir -p "$OUTPUT_DIR"
  timestamp="$(date '+%Y%m%d_%H%M%S')"
  work_root="${TMPDIR:-/tmp}/madgraph_batches_$timestamp"
  seed="$START_SEED"
  grand_total_events=0
  max_actual_runs=0
  progress_init "$work_root"

  log "MadGraph: $MG_DIR"
  log "Salida: $OUTPUT_DIR"
  log "Paralelo: PARALLEL_JOBS=$PARALLEL_JOBS, work_root=$work_root"
  log "Reanudar: RESUME=$RESUME, FORCE_RERUN=$FORCE_RERUN"
  log "Aceleracion: DISABLE_SYSTEMATICS=$DISABLE_SYSTEMATICS, MG_RUN_MODE=${MG_RUN_MODE:-default}, MG_NB_CORE=${MG_NB_CORE:-default}"
  if [[ -n "$MG_NB_CORE" ]]; then
    core_budget=$((PARALLEL_JOBS * MG_NB_CORE))
    if [[ "$core_budget" -gt 10 ]]; then
      log "Aviso: PARALLEL_JOBS * MG_NB_CORE = $core_budget; esto puede saturar tu Mac de 10 cores."
    fi
  fi
  log "Generacion: eventos = ceil(LUMINOSITY * R0 / EVENT_WEIGHT_TARGET)"
  log "Parametros: LUMINOSITY=$LUMINOSITY pb^-1, EVENT_WEIGHT_TARGET=$EVENT_WEIGHT_TARGET, RUNS_PER_MODEL=$RUNS_PER_MODEL, EVENTS_PER_RUN=$EVENTS_PER_RUN"
  if [[ "$RUNS_PER_MODEL" -eq 0 ]]; then
    log "Particion: automatica, hasta EVENTS_PER_RUN eventos por run"
  else
    log "Particion: exactamente RUNS_PER_MODEL runs por modelo"
  fi
  log "Normalizacion: event_weight_for_lumi = LUMINOSITY * R0 / eventos_generados"
  log "Fase 1: resolviendo R0 para todos los modelos"

  for idx in "${!MODELS[@]}"; do
    local model
    local raw_r0
    local r0
    local process_dir

    model="${MODELS[$idx]}"
    raw_r0="${R0_VALUES[$idx]}"
    process_dir="$MG_DIR/$model"

    [[ -d "$process_dir" ]] || die "No existe el proceso/modelo: $process_dir"
    [[ -x "$process_dir/bin/generate_events" ]] || die "No encontre generate_events para $model"
    [[ -f "$process_dir/Cards/run_card.dat" ]] || die "No encontre Cards/run_card.dat para $model"
    [[ -f "$process_dir/Cards/param_card.dat" ]] || die "No encontre Cards/param_card.dat para $model"

    r0="$(resolve_r0_value "$model" "$raw_r0" "$process_dir" "$work_root" "$seed")" || die "No pude obtener R0 para $model"
    if [[ "$raw_r0" == "auto" ]]; then
      seed=$((seed + 1))
    fi
    awk -v value="$r0" 'BEGIN { exit (value > 0 ? 0 : 1) }' || die "R0 para $model debe ser mayor que cero; valor=$r0"
    resolved_r0_values[$idx]="$r0"
  done

  log "Fase 2: planificando runs"

  for idx in "${!MODELS[@]}"; do
    local model
    local r0
    local process_dir
    local total_events
    local expected_events
    local batch_number
    local event_weight
    local actual_runs
    local generated_so_far

    model="${MODELS[$idx]}"
    r0="${resolved_r0_values[$idx]}"
    process_dir="$MG_DIR/$model"

    [[ -d "$process_dir" ]] || die "No existe el proceso/modelo: $process_dir"
    [[ -x "$process_dir/bin/generate_events" ]] || die "No encontre generate_events para $model"
    [[ -f "$process_dir/Cards/run_card.dat" ]] || die "No encontre Cards/run_card.dat para $model"
    [[ -f "$process_dir/Cards/param_card.dat" ]] || die "No encontre Cards/param_card.dat para $model"

    expected_events="$(expected_events_for_lumi "$LUMINOSITY" "$r0")"
    total_events="$(generated_events_for_lumi "$LUMINOSITY" "$r0" "$EVENT_WEIGHT_TARGET")"
    if [[ "$total_events" -le 0 ]]; then
      log "$model: R0=$r0 pb -> total_events=$total_events, se omite."
      continue
    fi

    if [[ "$RUNS_PER_MODEL" -eq 0 ]]; then
      actual_runs="$(ceil_div "$total_events" "$EVENTS_PER_RUN")"
    else
      actual_runs="$RUNS_PER_MODEL"
    fi
    if [[ "$actual_runs" -gt "$total_events" ]]; then
      log "$model: actual_runs=$actual_runs es mayor que total_events=$total_events; usare $total_events runs de 1 evento."
      actual_runs="$total_events"
    fi

    event_weight="$(event_weight_for_lumi "$LUMINOSITY" "$r0" "$total_events")"
    log "$model: R0=$r0 pb -> esperados=$expected_events, generare=$total_events en $actual_runs runs; peso/evento=$event_weight"
    grand_total_events=$((grand_total_events + total_events))

    planned_models+=("$model")
    planned_r0_values+=("$r0")
    planned_process_dirs+=("$process_dir")
    planned_total_events+=("$total_events")
    planned_expected_events+=("$expected_events")
    planned_event_weights+=("$event_weight")
    planned_actual_runs+=("$actual_runs")
    planned_start_seeds+=("$seed")
    progress_add_plan "$model" "$total_events" "$actual_runs"

    if [[ "$actual_runs" -gt "$max_actual_runs" ]]; then
      max_actual_runs="$actual_runs"
    fi
    seed=$((seed + actual_runs))
  done

  log "Total planeado entre modelos: $grand_total_events eventos"
  log "Precargando progreso desde ROOT + metadata existentes"
  for idx in "${!planned_models[@]}"; do
    preload_completed_runs "${planned_models[$idx]}" "${planned_total_events[$idx]}" "${planned_actual_runs[$idx]}" "${planned_start_seeds[$idx]}"
  done
  progress_print "plan completo"
  log "Fase 3: lanzando runs en rondas por modelo"
  start_progress_monitor

  batch_number=1
  while [[ "$batch_number" -le "$max_actual_runs" ]]; do
    for idx in "${!planned_models[@]}"; do
      local model
      local r0
      local process_dir
      local total_events
      local expected_events
      local event_weight
      local actual_runs
      local model_start_seed
      local run_seed
      local events_this_run

      model="${planned_models[$idx]}"
      r0="${planned_r0_values[$idx]}"
      process_dir="${planned_process_dirs[$idx]}"
      total_events="${planned_total_events[$idx]}"
      expected_events="${planned_expected_events[$idx]}"
      event_weight="${planned_event_weights[$idx]}"
      actual_runs="${planned_actual_runs[$idx]}"
      model_start_seed="${planned_start_seeds[$idx]}"

      [[ "$batch_number" -le "$actual_runs" ]] || continue

      events_this_run="$(events_for_batch "$total_events" "$actual_runs" "$batch_number")"
      run_seed=$((model_start_seed + batch_number - 1))
      wait_for_available_slot "$PARALLEL_JOBS"
      run_batch "$model" "$r0" "$batch_number" "$run_seed" "$events_this_run" "$total_events" "$event_weight" "$expected_events" "$RUNS_PER_MODEL" "$actual_runs" "$process_dir" "$work_root" &
      JOB_PIDS+=("$!")
    done

    batch_number=$((batch_number + 1))
  done

  if ! wait_for_all_jobs; then
    stop_progress_monitor
    die "Uno o mas runs fallaron"
  fi
  stop_progress_monitor
  progress_print "final"
  if [[ -n "$PROGRESS_ROOT" ]]; then
    rm -rf "$PROGRESS_ROOT"
  fi
  rmdir "$work_root" 2>/dev/null || true
  log "Listo."
}

main "$@"
