/*
 * Implementation of the skimming step of the analysis
 *
 * The skimming step reduces the inital generic samples to a dataset optimized
 * for this specific analysis. Most important, the skimming removes all events
 * from the initial dataset, which are not of interest for our study
 */


#include "ROOT/RDataFrame.hxx"
#include "ROOT/RVec.hxx"

#include "Math/Vector4D.h"
#include "Math/VectorUtil.h"
#include "TStopwatch.h"

#include <string>
#include <vector>
#include <map>
#include <iostream>
#include <cmath>
#include <exception>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <algorithm>


/*
 * Base path to local filesystem or to EOS containing the datasets
 */
const std::string samplesBasePath = "/Users/anotherdev/workspace/udea/gfif/Analysis/rootfiles/";


/*
 * Names of the datasets to be found in the base path and processed for the analysis and
 * the final states described by the dataset
 */
std::map<std::string, std::vector<std::string>> samples = {
    {"TTbar", {""}},
    {"VV", {""}},
    {"WJets", {""}},
    {"Wprime", {""}},
};

std::map<std::string, std::string> madGraphBatchDirs = {
    {"TTbar", "TTbar"},
    {"VV", "VV_new"},
    {"WJets", "Wjets"},
};

std::map<std::string, std::string> fallbackRootFiles = {
    {"Wprime", "WPrime.root"},
};


/*
 * Compute event weights to be used for the respective datasets
 *
 * The event weight reweights the full dataset so that the sum of the weights
 * is equal to the expected number of events in data. The expectation is given by
 * multiplying the integrated luminosity of the data with the cross-section of
 * the process in the datasets divided by the number of simulated events.
 */
const float integratedLuminosity = 150.0 * 1000.0; // pb^-1



std::map<std::string, float> crossSections = {
    {"TTbar", 504.57},   // poner xs real de MadGraph
    {"VV", 89.2137}, // pb
    {"WJets", 1616.07761},  // poner xs real
    {"Wprime", 0.1}  // dummy del paper, si estás reproduciendo
};

std::map<std::string, float> nGenerated = {
    {"TTbar", 1000000.0},
    {"VV", 100000.0},
    {"WJets", 100000.0},
    {"Wprime", 100000.0}

};

std::map<std::string, float> eventWeights = {
    {"VV", crossSections["VV"] * integratedLuminosity / nGenerated["VV"]},
    {"TTbar",   crossSections["TTbar"]   * integratedLuminosity / nGenerated["TTbar"]},
    {"WJets",  crossSections["WJets"]   * integratedLuminosity / nGenerated["WJets"]},
    {"Wprime", crossSections["Wprime"]  * integratedLuminosity / nGenerated["Wprime"]},
};

struct SampleInput {
    std::vector<std::string> files;
    double generatedEvents = 0.0;
    double crossSection = 0.0;
    double eventWeight = 0.0;
};

std::map<std::string, std::string> ReadSummary(const std::filesystem::path& summaryPath) {
    std::map<std::string, std::string> values;
    std::ifstream input(summaryPath);
    std::string line;

    while (std::getline(input, line)) {
        const auto tab = line.find('\t');
        if (tab == std::string::npos) {
            continue;
        }
        values[line.substr(0, tab)] = line.substr(tab + 1);
    }

    return values;
}

double ToDoubleOrZero(const std::map<std::string, std::string>& values, const std::string& key) {
    const auto it = values.find(key);
    if (it == values.end()) {
        return 0.0;
    }
    try {
        return std::stod(it->second);
    } catch (const std::exception&) {
        return 0.0;
    }
}

std::string MetadataValueOrEmpty(const std::map<std::string, std::string>& values, const std::string& key) {
    const auto it = values.find(key);
    return it == values.end() ? "" : it->second;
}

std::string SkimEventWeightTarget() {
    const char* target = std::getenv("SKIM_EVENT_WEIGHT_TARGET");
    if (target == nullptr) {
        return "10";
    }
    return std::string(target);
}

SampleInput CollectMadGraphBatchInput(const std::string& sampleName, const std::string& batchDirName) {
    SampleInput input;
    const auto batchRoot = std::filesystem::path(samplesBasePath) / "madgraph_batches" / batchDirName;
    const auto targetWeight = SkimEventWeightTarget();

    if (!std::filesystem::exists(batchRoot)) {
        return input;
    }

    for (const auto& entry : std::filesystem::recursive_directory_iterator(batchRoot)) {
        if (!entry.is_regular_file() || entry.path().filename() != "summary.tsv") {
            continue;
        }

        const auto summary = ReadSummary(entry.path());
        if (!targetWeight.empty() && MetadataValueOrEmpty(summary, "event_weight_target") != targetWeight) {
            continue;
        }

        const auto events = ToDoubleOrZero(summary, "events_requested");
        const auto xsec = ToDoubleOrZero(summary, "r0_cross_section");
        if (events <= 0.0 || xsec <= 0.0) {
            continue;
        }

        const auto runDir = entry.path().parent_path().parent_path();
        const auto rootDir = runDir / "root";
        if (!std::filesystem::exists(rootDir)) {
            continue;
        }

        std::vector<std::string> runRoots;
        for (const auto& rootEntry : std::filesystem::recursive_directory_iterator(rootDir)) {
            if (rootEntry.is_regular_file() && rootEntry.path().extension() == ".root") {
                runRoots.push_back(rootEntry.path().string());
            }
        }

        if (runRoots.empty()) {
            continue;
        }

        std::sort(runRoots.begin(), runRoots.end());
        input.files.insert(input.files.end(), runRoots.begin(), runRoots.end());
        input.generatedEvents += events;
        if (input.crossSection <= 0.0) {
            input.crossSection = xsec;
        } else if (std::abs(input.crossSection - xsec) / input.crossSection > 0.01) {
            std::cout << ">>> Warning: " << sampleName
                      << " has a batch with a different cross-section: " << xsec
                      << " pb, using " << input.crossSection << " pb for weights." << std::endl;
        }
    }

    std::sort(input.files.begin(), input.files.end());
    if (input.generatedEvents > 0.0 && input.crossSection > 0.0) {
        input.eventWeight = input.crossSection * integratedLuminosity / input.generatedEvents;
    }

    return input;
}

SampleInput ResolveSampleInput(const std::string& sampleName) {
    const auto batchIt = madGraphBatchDirs.find(sampleName);
    if (batchIt != madGraphBatchDirs.end()) {
        auto input = CollectMadGraphBatchInput(sampleName, batchIt->second);
        if (!input.files.empty()) {
            return input;
        }
    }

    SampleInput input;
    const auto fallbackIt = fallbackRootFiles.find(sampleName);
    const auto fileName = fallbackIt == fallbackRootFiles.end() ? sampleName + ".root" : fallbackIt->second;
    const auto filePath = std::filesystem::path(samplesBasePath) / fileName;
    if (std::filesystem::exists(filePath)) {
        input.files.push_back(filePath.string());
        input.generatedEvents = nGenerated[sampleName];
        input.crossSection = crossSections[sampleName];
        input.eventWeight = eventWeights[sampleName];
    }
    return input;
}

/*
 * Perform a selection on the minimal requirements of an event
 */
ROOT::RDF::RNode MinimalSelection(ROOT::RDF::RNode df) {
    return df
        .Filter("Muon_size == 1",
                "Exactly one muon")
        .Filter("Sum(Electron.PT > 25.0) == 0",
                "Lepton veto: no electron with pT > 25 GeV")
        .Filter("Jet_size >= 2",
                "At least two jets")
        .Filter("Sum(Jet.PT > 60.0) >= 2",
                "At least two jets with pT > 60 GeV")
        .Filter("Sum(Jet.BTag > 0) == 0",
                "b-jet veto")
        .Filter("MissingET_size > 0 && MissingET.MET[0] > 50.0",
                "MET > 50 GeV")
        .Filter("Muon.PT[0] > 25.0",
                "Muon pT > 25 GeV");
}

ROOT::RDF::RNode ApplyVBFCuts(ROOT::RDF::RNode df) {
    return df
        .Define("j1_idx", "Reverse(Argsort(Jet.PT))[0]")
        .Define("j2_idx", "Reverse(Argsort(Jet.PT))[1]")

        .Define("j1_pt",  "Jet.PT[j1_idx]")
        .Define("j2_pt",  "Jet.PT[j2_idx]")

        .Define("j1_eta", "Jet.Eta[j1_idx]")
        .Define("j2_eta", "Jet.Eta[j2_idx]")

        .Define("j1_phi", "Jet.Phi[j1_idx]")
        .Define("j2_phi", "Jet.Phi[j2_idx]")

        .Define("j1_vector",
                "ROOT::Math::PtEtaPhiMVector(Jet.PT[j1_idx], Jet.Eta[j1_idx], Jet.Phi[j1_idx], Jet.Mass[j1_idx])")
        .Define("j2_vector",
                "ROOT::Math::PtEtaPhiMVector(Jet.PT[j2_idx], Jet.Eta[j2_idx], Jet.Phi[j2_idx], Jet.Mass[j2_idx])")

        .Define("mu_vector",
                "ROOT::Math::PtEtaPhiMVector(Muon.PT[0], Muon.Eta[0], Muon.Phi[0], 0.)")
        .Define("met_vector",
                "ROOT::Math::PtEtaPhiMVector(MissingET.MET[0], 0., MissingET.Phi[0], 0.)")

        .Define("mjj", "ROOT::Math::VectorUtil::InvariantMass(j1_vector, j2_vector)")

        .Define("delta_eta_jj", "abs(j1_eta-j2_eta)")

        // .Filter("Muon.PT[0] > 200.0",
        //         "Cut 5: muon pT > 200 GeV")

        // .Filter("MissingET.MET[0] > 200.0",
        //         "Cut 6: MET > 200 GeV")

        .Define("delta_phi_mu_met",
                "abs(ROOT::Math::VectorUtil::DeltaPhi(mu_vector, met_vector))");
        // .Filter("delta_phi_mu_met > 1.0",
        //         "Cut 7: DeltaPhi(mu,MET) > 1");
}
/*
 * Declare all variables which we want to study in the analysis
 */
ROOT::RDF::RNode DeclareVariables(ROOT::RDF::RNode df) {
    return df
        .Define("mu_pt", "Muon.PT[0]")
        .Define("mu_eta", "Muon.Eta[0]")
        .Define("mu_phi", "Muon.Phi[0]")

        .Define("met_pt", "MissingET.MET[0]")
        .Define("met_phi", "MissingET.Phi[0]")

        .Define("jet1_pt", "j1_pt")
        .Define("jet2_pt", "j2_pt")

        .Define("jet1_eta", "j1_eta")
        .Define("jet2_eta", "j2_eta")

        .Define("eta_product", "j1_eta*j2_eta");
}

/*
 * Add the event weight to the dataset as the column "weight"
 */
ROOT::RDF::RNode AddEventWeight(ROOT::RDF::RNode df, const double weight) {
    return df.Define("weight", [weight](){ return weight; });
}


/*
 * Declare all variables which shall end up in the final reduced dataset
 */
const std::vector<std::string> finalVariables = {
    "weight",
    "mu_pt", "mu_eta", "mu_phi",
    "met_pt", "met_phi",
    "jet1_pt", "jet1_eta",
    "jet2_pt", "jet2_eta",
    "delta_eta_jj",
    "eta_product",
    "delta_phi_mu_met",
    "mjj"
};


int main() {
    // Delphes uses TClonesArray branches which are not thread-safe.
    // EnableImplicitMT causes deadlocks when processing Delphes files.
    // ROOT::EnableImplicitMT();
    const auto poolSize = ROOT::GetThreadPoolSize();
    std::cout << ">>> Thread pool size for parallel processing: " << poolSize << std::endl;

    for (const auto &sample : samples) {
        const auto name = sample.first;
        const auto finalStates = sample.second;
        std::cout << ">>> Process sample " << name << ":" << std::endl;
        const auto sampleInput = ResolveSampleInput(name);
        if (sampleInput.files.empty()) {
            std::cout << ">>> No input ROOT files found for sample " << name << ", skipping." << std::endl;
            continue;
        }

        std::cout << ">>> Input files: " << sampleInput.files.size()
                  << ", generated events: " << sampleInput.generatedEvents
                  << ", cross-section: " << sampleInput.crossSection
                  << " pb, event weight: " << sampleInput.eventWeight << std::endl;
        ROOT::RDataFrame df("Delphes", sampleInput.files);

        for (const auto &finalState : finalStates) {
            std::cout << ">>> Process final state " << finalState << " for sample " << name << ":" << std::endl;
            TStopwatch time;
            time.Start();

            auto df2 = MinimalSelection(df);
            std::cout << ">>> Apply minimal selection" << std::endl;
            auto df3 = ApplyVBFCuts(df2);
            std::cout << ">>> Declare variables" << std::endl;
            auto df4 = DeclareVariables(df3);
            std::cout << ">>> Add event weight" << std::endl;
            auto df5 = AddEventWeight(df4, sampleInput.eventWeight);
            std::cout << ">>> Write skimmed dataset to file" << std::endl;
            auto dfFinal = df5;
            std::cout << ">>> Generate report" << std::endl;
            auto report = dfFinal.Report(); 
            dfFinal.Snapshot("Events", name + finalState + "Skim.root", finalVariables);
            report->Print();
            time.Stop();
            time.Print();
        }
    }
}
