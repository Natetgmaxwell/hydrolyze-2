import Foundation

// MARK: - Models

struct Swimmer {
    let id: String
    let name: String
    let pbs: [String: Double]
    let baseSigma: Double
}

let SWIMMERS = [
    Swimmer(id: "A", name: "Alice", pbs: ["100_Free": 58500], baseSigma: 400),
    Swimmer(id: "B", name: "Bob", pbs: ["100_Free": 62300], baseSigma: 800),
    Swimmer(id: "C", name: "Charlie", pbs: ["100_Free": 65800], baseSigma: 1200),
    Swimmer(id: "D", name: "David", pbs: ["100_Free": 69500], baseSigma: 2000),
    Swimmer(id: "E", name: "Eve", pbs: ["100_Free": 74200], baseSigma: 3000),
    Swimmer(id: "F", name: "Frank", pbs: [:], baseSigma: 2000),
    Swimmer(id: "G", name: "Grace", pbs: ["50_Free": 27500], baseSigma: 1500),
    Swimmer(id: "H", name: "Henry", pbs: ["100_Breast": 72000], baseSigma: 1500)
]

let SWIMMERS_DICT = Dictionary(uniqueKeysWithValues: SWIMMERS.map { ($0.id, $0) })

struct Tap {
    let id: String
    let timeMs: Double
}

struct SetInfo {
    let distance: Int
    let stroke: String
    let intensity: String // "easy", "moderate", "hard", "race"
    let repIndex: Int
}

struct Assignment {
    let tapId: String
    let swimmerId: String? // nil if ghost tap
    let confidence: Double // 0.0 to 1.0
}

struct GroundTruth {
    let tapId: String
    let swimmerId: String? // nil if ghost
}

// MARK: - Helper Constants
let K_RIEGEL = 1.03
let INTENSITY_MULT = ["easy": 1.25, "moderate": 1.10, "hard": 1.03, "race": 1.00]
let FATIGUE_PER_REP = 0.005
let GHOST_THRESHOLD_NLL = 3.315 // 99% chi-square

// MARK: - Scenario Model

struct Scenario {
    let name: String
    let swimmers: [Swimmer]
    let setInfo: SetInfo
    let waveStartTimeMs: Double
    let taps: [Tap]
    let groundTruth: [GroundTruth]
}

// MARK: - Base Algorithm Protocol
protocol PairingAlgorithm {
    var name: String { get }
    func assign(taps: [Tap], activeSwimmers: [Swimmer], setInfo: SetInfo, waveStartTimeMs: Double) -> [Assignment]
}

// MARK: - Assignment Logic (Brute Force for small N)
func optimizeAssignment(taps: [Tap], expected: [(id: String, expectedMs: Double, sigma: Double)], gateNLL: Double? = nil, useLogSigma: Bool = false) -> (assignments: [Assignment], cost: Double, confidence: [String: Double]) {
    
    // We want to assign each tap to at most one swimmer, and each swimmer to at most one tap.
    // Taps length M, Swimmers length N.
    
    // N, M <= 8 typically. We can find all subsets and permutations.
    // Actually, simpler: recursively build assignments.
    
    var bestCost = Double.infinity
    var bestMapping: [Int: Int]? = nil // tapIndex -> swimmerIndex
    
    func getCost(tap: Tap, swimmerInfo: (id: String, expectedMs: Double, sigma: Double)) -> Double {
        let diff = tap.timeMs - swimmerInfo.expectedMs
        var cost = (diff * diff) / (2.0 * swimmerInfo.sigma * swimmerInfo.sigma)
        if useLogSigma {
            cost += log(swimmerInfo.sigma)
        }
        return cost
    }
    
    let missedTapCost = 5.0 // Cost of swimmer missing a tap
    let ghostTapCost = gateNLL ?? 5.0 // Cost of a tap being unassigned
    
    func search(tapIndex: Int, currentCost: Double, mapping: [Int: Int], usedSwimmers: Set<Int>) {
        if currentCost >= bestCost { return }
        if tapIndex == taps.count {
            // Add cost for missed swimmers
            let totalCost = currentCost + Double(expected.count - usedSwimmers.count) * missedTapCost
            if totalCost < bestCost {
                bestCost = totalCost
                bestMapping = mapping
            }
            return
        }
        
        let tap = taps[tapIndex]
        
        // Option 1: Tap is unassigned (Ghost)
        search(tapIndex: tapIndex + 1, currentCost: currentCost + ghostTapCost, mapping: mapping, usedSwimmers: usedSwimmers)
        
        // Option 2: Tap is assigned to a swimmer
        for sIdx in 0..<expected.count {
            if !usedSwimmers.contains(sIdx) {
                let cost = getCost(tap: tap, swimmerInfo: expected[sIdx])
                if gateNLL == nil || cost <= gateNLL! {
                    var newMapping = mapping
                    newMapping[tapIndex] = sIdx
                    var newUsed = usedSwimmers
                    newUsed.insert(sIdx)
                    search(tapIndex: tapIndex + 1, currentCost: currentCost + cost, mapping: newMapping, usedSwimmers: newUsed)
                }
            }
        }
    }
    
    search(tapIndex: 0, currentCost: 0, mapping: [:], usedSwimmers: [])
    
    // Now we need k-best assignments for confidence. For now, simple confidence based on margin.
    var confidences: [String: Double] = [:]
    
    if let best = bestMapping {
        for i in 0..<taps.count {
            if let sIdx = best[i] {
                // Approximate confidence
                let cost = getCost(tap: taps[i], swimmerInfo: expected[sIdx])
                var conf = 1.0 / (1.0 + cost) // Rough sigmoid-like
                if conf < 0 { conf = 0 }
                if conf > 1 { conf = 1 }
                confidences[taps[i].id] = conf
            } else {
                confidences[taps[i].id] = 1.0 // Ghost tap confidence
            }
        }
        
        var assignments = [Assignment]()
        for i in 0..<taps.count {
            let tap = taps[i]
            if let sIdx = best[i] {
                let swimmerId = expected[sIdx].id
                assignments.append(Assignment(tapId: tap.id, swimmerId: swimmerId, confidence: confidences[tap.id] ?? 0.5))
            } else {
                assignments.append(Assignment(tapId: tap.id, swimmerId: nil, confidence: confidences[tap.id] ?? 0.5))
            }
        }
        return (assignments, bestCost, confidences)
    }
    
    return (taps.map { Assignment(tapId: $0.id, swimmerId: nil, confidence: 0) }, bestCost, [:])
}
