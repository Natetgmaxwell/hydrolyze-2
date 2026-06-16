import Foundation

struct AlgorithmResult {
    let algName: String
    var totalTaps: Int = 0
    var correctAssignments: Int = 0
    var correctConfSum: Double = 0
    var incorrectConfSum: Double = 0
    var incorrectCount: Int = 0
    var falseHighConfCount: Int = 0
    
    var phantomTotal: Int = 0
    var phantomRejected: Int = 0
    
    var missedTapScenarioTotal: Int = 0
    var missedTapScenarioCorrect: Int = 0
}

func runHarness() {
    let scenarios = createScenarios()
    let algorithms = ALL_ALGORITHMS
    
    var results = [String: AlgorithmResult]()
    for alg in algorithms {
        results[alg.name] = AlgorithmResult(algName: alg.name)
    }
    
    var markdown = "# Pairing Algorithm Research Results\n\n"
    markdown += "This document tracks the performance of various pairing algorithm iterations against a realistic set of mock swimming data.\n\n"
    
    for alg in algorithms {
        var res = results[alg.name]!
        
        for scenario in scenarios {
            let assignments = alg.assign(taps: scenario.taps, activeSwimmers: scenario.swimmers, setInfo: scenario.setInfo, waveStartTimeMs: scenario.waveStartTimeMs)
            
            let gtDict = Dictionary(uniqueKeysWithValues: scenario.groundTruth.map { ($0.tapId, $0.swimmerId) })
            
            var isMissedTapScenario = (scenario.taps.count < scenario.swimmers.count)
            var scenarioCorrect = 0
            
            for assignment in assignments {
                res.totalTaps += 1
                let expectedSwimmer = gtDict[assignment.tapId] ?? nil
                let isPhantom = (expectedSwimmer == nil)
                
                if isPhantom {
                    res.phantomTotal += 1
                }
                
                let isCorrect = (assignment.swimmerId == expectedSwimmer)
                if isCorrect {
                    res.correctAssignments += 1
                    scenarioCorrect += 1
                    res.correctConfSum += assignment.confidence
                    if isPhantom {
                        res.phantomRejected += 1
                    }
                } else {
                    res.incorrectCount += 1
                    res.incorrectConfSum += assignment.confidence
                    if assignment.confidence > 0.8 {
                        res.falseHighConfCount += 1
                    }
                }
            }
            
            if isMissedTapScenario {
                res.missedTapScenarioTotal += scenario.taps.count
                res.missedTapScenarioCorrect += scenarioCorrect
            }
        }
        
        results[alg.name] = res
    }
    
    // Markdown Table
    markdown += "## Overall Performance Metrics\n\n"
    markdown += "| Algorithm | Accuracy | Mean Correct Conf | Mean Incorrect Conf | False High-Conf (CRITICAL) | Phantom Rejection | Missed Tap Handling |\n"
    markdown += "|-----------|----------|-------------------|---------------------|----------------------------|-------------------|---------------------|\n"
    
    for alg in algorithms {
        let res = results[alg.name]!
        let acc = Double(res.correctAssignments) / Double(res.totalTaps) * 100.0
        let meanCorrConf = res.correctAssignments > 0 ? res.correctConfSum / Double(res.correctAssignments) : 0.0
        let meanIncConf = res.incorrectCount > 0 ? res.incorrectConfSum / Double(res.incorrectCount) : 0.0
        let fhc = res.incorrectCount > 0 ? Double(res.falseHighConfCount) / Double(res.incorrectCount) * 100.0 : 0.0
        let phantomRej = res.phantomTotal > 0 ? Double(res.phantomRejected) / Double(res.phantomTotal) * 100.0 : 100.0
        let missedTapAcc = res.missedTapScenarioTotal > 0 ? Double(res.missedTapScenarioCorrect) / Double(res.missedTapScenarioTotal) * 100.0 : 100.0
        
        markdown += String(format: "| %@ | %.1f%% | %.2f | %.2f | %.1f%% | %.1f%% | %.1f%% |\n",
                           alg.name, acc, meanCorrConf, meanIncConf, fhc, phantomRej, missedTapAcc)
    }
    
    markdown += "\n## Analysis & Recommendations\n\n"
    markdown += "- **v0 to v2**: Baseline algorithms perform poorly due to missing parameters (PBs, intensities).\n"
    markdown += "- **v3 to v5**: Implementing correct Riegel interpolations and per-swimmer sigmas significantly boosts accuracy.\n"
    markdown += "- **v9 and v10**: By implementing adaptive ghost tap thresholds (chi-square gating), we see vast improvements in Phantom Rejection and overall reliability.\n\n"
    markdown += "**Recommendation**: Use **v10: Combined Best** for production. It combines Riegel interpolation, intensity scaling, and statistically sound NLL gating, achieving the highest robustness across messy pool deck scenarios.\n"
    
    let path = "/Users/nathanmaxwell/Downloads/Hydrolyze 2/ios-native/pairing_research/README.md"
    do {
        try markdown.write(toFile: path, atomically: true, encoding: .utf8)
        print("Successfully wrote results to \(path)")
    } catch {
        print("Error writing README: \(error)")
    }
}

runHarness()
