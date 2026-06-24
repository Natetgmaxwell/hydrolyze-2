import Foundation

// MARK: - Algorithm Implementations

class BaseAlgorithm: PairingAlgorithm {
    var name: String { "Base" }
    func assign(taps: [Tap], activeSwimmers: [Swimmer], setInfo: SetInfo, waveStartTimeMs: Double) -> [Assignment] {
        return []
    }
}

// v0: Broken baseline
class V0_Broken: BaseAlgorithm {
    override var name: String { "v0: Broken Baseline" }
    override func assign(taps: [Tap], activeSwimmers: [Swimmer], setInfo: SetInfo, waveStartTimeMs: Double) -> [Assignment] {
        let expected = activeSwimmers.map { (id: $0.id, expectedMs: 0.0, sigma: 1500.0) }
        return optimizeAssignment(taps: taps, expected: expected).assignments
    }
}

// v1: Fix PB lookup
class V1_PBLookup: BaseAlgorithm {
    override var name: String { "v1: PB Lookup" }
    override func assign(taps: [Tap], activeSwimmers: [Swimmer], setInfo: SetInfo, waveStartTimeMs: Double) -> [Assignment] {
        let expected = activeSwimmers.map { swimmer -> (id: String, expectedMs: Double, sigma: Double) in
            let key = "\(setInfo.distance)_\(setInfo.stroke)"
            let pb = swimmer.pbs[key] ?? 60000.0 // Default 60s if missing
            return (id: swimmer.id, expectedMs: waveStartTimeMs + pb, sigma: 1500.0)
        }
        return optimizeAssignment(taps: taps, expected: expected).assignments
    }
}

// v2: Intensity scaling
class V2_IntensityScaling: BaseAlgorithm {
    override var name: String { "v2: Intensity Scaling" }
    override func assign(taps: [Tap], activeSwimmers: [Swimmer], setInfo: SetInfo, waveStartTimeMs: Double) -> [Assignment] {
        let mult = INTENSITY_MULT[setInfo.intensity] ?? 1.0
        let expected = activeSwimmers.map { swimmer -> (id: String, expectedMs: Double, sigma: Double) in
            let key = "\(setInfo.distance)_\(setInfo.stroke)"
            let pb = swimmer.pbs[key] ?? 60000.0
            return (id: swimmer.id, expectedMs: waveStartTimeMs + pb * mult, sigma: 1500.0)
        }
        return optimizeAssignment(taps: taps, expected: expected).assignments
    }
}

// v3: Per-swimmer sigma
class V3_PerSwimmerSigma: BaseAlgorithm {
    override var name: String { "v3: Per-Swimmer Sigma" }
    override func assign(taps: [Tap], activeSwimmers: [Swimmer], setInfo: SetInfo, waveStartTimeMs: Double) -> [Assignment] {
        let mult = INTENSITY_MULT[setInfo.intensity] ?? 1.0
        let expected = activeSwimmers.map { swimmer -> (id: String, expectedMs: Double, sigma: Double) in
            let key = "\(setInfo.distance)_\(setInfo.stroke)"
            let pb = swimmer.pbs[key] ?? 60000.0
            return (id: swimmer.id, expectedMs: waveStartTimeMs + pb * mult, sigma: swimmer.baseSigma)
        }
        return optimizeAssignment(taps: taps, expected: expected).assignments
    }
}

// v4: Log(sigma) normalization
class V4_LogSigma: BaseAlgorithm {
    override var name: String { "v4: Log(Sigma) Norm" }
    override func assign(taps: [Tap], activeSwimmers: [Swimmer], setInfo: SetInfo, waveStartTimeMs: Double) -> [Assignment] {
        let mult = INTENSITY_MULT[setInfo.intensity] ?? 1.0
        let expected = activeSwimmers.map { swimmer -> (id: String, expectedMs: Double, sigma: Double) in
            let key = "\(setInfo.distance)_\(setInfo.stroke)"
            let pb = swimmer.pbs[key] ?? 60000.0
            return (id: swimmer.id, expectedMs: waveStartTimeMs + pb * mult, sigma: swimmer.baseSigma)
        }
        return optimizeAssignment(taps: taps, expected: expected, useLogSigma: true).assignments
    }
}

// v5: Riegel Interpolation
class V5_Riegel: BaseAlgorithm {
    override var name: String { "v5: Riegel Interpolation" }
    
    func estimateTime(swimmer: Swimmer, distance: Int, stroke: String) -> Double {
        let key = "\(distance)_\(stroke)"
        if let pb = swimmer.pbs[key] { return pb }
        
        // Find best fallback in same stroke
        for (pbKey, time) in swimmer.pbs {
            let parts = pbKey.split(separator: "_")
            if parts.count == 2, String(parts[1]) == stroke, let d = Int(parts[0]) {
                let ratio = Double(distance) / Double(d)
                return time * pow(ratio, K_RIEGEL)
            }
        }
        // Fallback to cross-stroke (crude)
        for (pbKey, time) in swimmer.pbs {
            let parts = pbKey.split(separator: "_")
            if parts.count == 2, let d = Int(parts[0]) {
                let ratio = Double(distance) / Double(d)
                return time * pow(ratio, K_RIEGEL)
            }
        }
        return 60000.0
    }
    
    override func assign(taps: [Tap], activeSwimmers: [Swimmer], setInfo: SetInfo, waveStartTimeMs: Double) -> [Assignment] {
        let mult = INTENSITY_MULT[setInfo.intensity] ?? 1.0
        let expected = activeSwimmers.map { swimmer -> (id: String, expectedMs: Double, sigma: Double) in
            let pb = estimateTime(swimmer: swimmer, distance: setInfo.distance, stroke: setInfo.stroke)
            return (id: swimmer.id, expectedMs: waveStartTimeMs + pb * mult, sigma: swimmer.baseSigma)
        }
        return optimizeAssignment(taps: taps, expected: expected, useLogSigma: true).assignments
    }
}

// v6: Fatigue Decay
class V6_Fatigue: V5_Riegel {
    override var name: String { "v6: Fatigue Decay" }
    override func assign(taps: [Tap], activeSwimmers: [Swimmer], setInfo: SetInfo, waveStartTimeMs: Double) -> [Assignment] {
        let mult = INTENSITY_MULT[setInfo.intensity] ?? 1.0
        let fatigueMult = 1.0 + Double(setInfo.repIndex) * FATIGUE_PER_REP
        let expected = activeSwimmers.map { swimmer -> (id: String, expectedMs: Double, sigma: Double) in
            let pb = estimateTime(swimmer: swimmer, distance: setInfo.distance, stroke: setInfo.stroke)
            return (id: swimmer.id, expectedMs: waveStartTimeMs + pb * mult * fatigueMult, sigma: swimmer.baseSigma)
        }
        return optimizeAssignment(taps: taps, expected: expected, useLogSigma: true).assignments
    }
}

// v7: Dynamic Recalibration (mock via EMA)
class V7_EMA: V6_Fatigue {
    override var name: String { "v7: Dynamic Recalib (EMA)" }
    override func assign(taps: [Tap], activeSwimmers: [Swimmer], setInfo: SetInfo, waveStartTimeMs: Double) -> [Assignment] {
        let mult = INTENSITY_MULT[setInfo.intensity] ?? 1.0
        let fatigueMult = 1.0 + Double(setInfo.repIndex) * FATIGUE_PER_REP
        let expected = activeSwimmers.map { swimmer -> (id: String, expectedMs: Double, sigma: Double) in
            var pb = estimateTime(swimmer: swimmer, distance: setInfo.distance, stroke: setInfo.stroke)
            
            // Mocking EMA: if a swimmer has a massive outlier day (e.g., A is much slower), EMA would have adjusted.
            // For now, we expand sigma to represent uncertainty during recalibration.
            var adjSigma = swimmer.baseSigma
            if setInfo.repIndex > 0 {
                adjSigma *= 1.2
            }
            return (id: swimmer.id, expectedMs: waveStartTimeMs + pb * mult * fatigueMult, sigma: adjSigma)
        }
        return optimizeAssignment(taps: taps, expected: expected, useLogSigma: true).assignments
    }
}

// v8: K-best confidence (better confidence)
class V8_KBest: V7_EMA {
    override var name: String { "v8: K-Best Confidence" }
    override func assign(taps: [Tap], activeSwimmers: [Swimmer], setInfo: SetInfo, waveStartTimeMs: Double) -> [Assignment] {
        let expected = getExpected(activeSwimmers: activeSwimmers, setInfo: setInfo, waveStartTimeMs: waveStartTimeMs)
        // By setting gateNLL to nil, we don't force gate out, we let it find assignment then compute margin.
        return optimizeAssignment(taps: taps, expected: expected, useLogSigma: true).assignments
    }
    
    func getExpected(activeSwimmers: [Swimmer], setInfo: SetInfo, waveStartTimeMs: Double) -> [(id: String, expectedMs: Double, sigma: Double)] {
        let mult = INTENSITY_MULT[setInfo.intensity] ?? 1.0
        let fatigueMult = 1.0 + Double(setInfo.repIndex) * FATIGUE_PER_REP
        return activeSwimmers.map { swimmer in
            let pb = estimateTime(swimmer: swimmer, distance: setInfo.distance, stroke: setInfo.stroke)
            return (id: swimmer.id, expectedMs: waveStartTimeMs + pb * mult * fatigueMult, sigma: swimmer.baseSigma)
        }
    }
}

// v9: Adaptive ghost tap threshold (Chi-square gate)
class V9_GhostGate: V8_KBest {
    override var name: String { "v9: Ghost Tap Gate" }
    override func assign(taps: [Tap], activeSwimmers: [Swimmer], setInfo: SetInfo, waveStartTimeMs: Double) -> [Assignment] {
        let expected = getExpected(activeSwimmers: activeSwimmers, setInfo: setInfo, waveStartTimeMs: waveStartTimeMs)
        return optimizeAssignment(taps: taps, expected: expected, gateNLL: GHOST_THRESHOLD_NLL, useLogSigma: true).assignments
    }
}

// v10: Combined Best (Tuned)
class V10_CombinedBest: V9_GhostGate {
    override var name: String { "v10: Combined Best" }
    override func assign(taps: [Tap], activeSwimmers: [Swimmer], setInfo: SetInfo, waveStartTimeMs: Double) -> [Assignment] {
        let expected = getExpected(activeSwimmers: activeSwimmers, setInfo: setInfo, waveStartTimeMs: waveStartTimeMs)
        // Use a slightly wider gate for better phantom rejection robustness in swimming context
        let tunedGate = 5.0
        return optimizeAssignment(taps: taps, expected: expected, gateNLL: tunedGate, useLogSigma: true).assignments
    }
}

let ALL_ALGORITHMS: [PairingAlgorithm] = [
    V0_Broken(),
    V1_PBLookup(),
    V2_IntensityScaling(),
    V3_PerSwimmerSigma(),
    V4_LogSigma(),
    V5_Riegel(),
    V6_Fatigue(),
    V7_EMA(),
    V8_KBest(),
    V9_GhostGate(),
    V10_CombinedBest()
]
