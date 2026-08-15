// ThreeMinuteTestCLITest — runs the pure 3MT math service against synthetic
// 25m splits. Verifies the Slice 2 contract from V0.38_SPEC §Slice 2:
//
//   1. Sprinter curve → correct peak/CS/battery; no paced-start, no flat-curve
//   2. Distance curve → correct peak/CS; no flat-curve (drop ~25%)
//   3. Paced-start curve → .pacedStart flag set
//   4. Flat curve → .flatCurve flag set
//   5. Learning trial → trialNumber 1 sets .learningTrial, trialNumber 3 doesn't
//   6. peakBelowExpected → only when supplied AND peak < 95% of expected
//
// Usage: ThreeMinuteTestCLITest
// Compiled by build_and_run_3mt.sh.
//
// stdlib only, NO XCTest, @main entry (matches the PairingEngineCLITest pattern).

import Foundation

// MARK: - Helpers

/// Build a [Lap] from an array of split times in seconds. The first lap's
/// `elapsedMs` is the first split time; subsequent laps' `elapsedMs` is the
/// cumulative sum. `splitMs` is the per-lap value (the spec's tᵢ).
func makeLaps(splitTimesSec: [Double]) -> [Lap] {
    var laps: [Lap] = []
    var cumulativeMs = 0
    for (i, t) in splitTimesSec.enumerated() {
        let splitMs = Int((t * 1000.0).rounded())
        cumulativeMs += splitMs
        laps.append(Lap(
            id: "lap-\(i + 1)",
            lapNumber: i + 1,
            elapsedMs: cumulativeMs,
            splitMs: splitMs
        ))
    }
    return laps
}

/// Format a Double with N decimals for readable output.
func fmt(_ x: Double, decimals: Int = 4) -> String {
    return String(format: "%.\(decimals)f", x)
}

/// Tiny assertion helper: compares `actual` against `expected` within `tolerance`,
/// prints PASS/FAIL with diagnostics, returns true on pass.
func assertClose(
    _ label: String,
    actual: Double,
    expected: Double,
    tolerance: Double
) -> Bool {
    let diff = abs(actual - expected)
    let ok = diff <= tolerance
    let mark = ok ? "PASS" : "FAIL"
    print("  [\(mark)] \(label): actual=\(fmt(actual)) expected=\(fmt(expected)) diff=\(fmt(diff)) tol=\(fmt(tolerance))")
    return ok
}

/// Asserts a boolean predicate. Prints PASS/FAIL with the label, returns bool.
func assertTrue(_ label: String, _ condition: Bool, extra: String = "") -> Bool {
    let mark = condition ? "PASS" : "FAIL"
    let suffix = extra.isEmpty ? "" : " (\(extra))"
    print("  [\(mark)] \(label)\(suffix)")
    return condition
}

/// Asserts `flags` contains the named flag. Prints PASS/FAIL, returns bool.
func assertFlagPresent(
    _ label: String,
    flags: [ThreeMinuteTestAnalyzer.QualityFlag],
    _ expected: ThreeMinuteTestAnalyzer.QualityFlag
) -> Bool {
    let present = flags.contains(expected)
    let rawList = flags.map { $0.rawValue }.joined(separator: ",")
    return assertTrue(
        label,
        present,
        extra: present ? "flag=\(expected.rawValue) present in [\(rawList)]" : "flag=\(expected.rawValue) MISSING from [\(rawList)]"
    )
}

/// Asserts `flags` does NOT contain the named flag.
func assertFlagAbsent(
    _ label: String,
    flags: [ThreeMinuteTestAnalyzer.QualityFlag],
    _ unexpected: ThreeMinuteTestAnalyzer.QualityFlag
) -> Bool {
    let absent = !flags.contains(unexpected)
    let rawList = flags.map { $0.rawValue }.joined(separator: ",")
    return assertTrue(
        label,
        absent,
        extra: absent ? "no \(unexpected.rawValue) in [\(rawList)]" : "\(unexpected.rawValue) UNEXPECTEDLY in [\(rawList)]"
    )
}

// MARK: - Test cases

/// TEST 1 — Sprinter curve. Big peak + big drop. Verifies the slice-2 contract:
/// peak ≈ 25/13.0, CS = mean of last 2 splits (only split 9 lands in the
/// [150s, 180s] window; per spec we fall back to the last 2), battery is the
/// area above CS. No paced-start (split 1 > split 2 and 3). No flat-curve
/// (CS/peak ~54%).
///
/// Hand-recomputed (25m pool):
///   speeds:    1.9231, 1.7241, 1.5625, 1.4286, 1.3158, 1.2195, 1.1364, 1.0638, 1.0000
///   peak:      25 / 13.0 = 1.92308 m/s
///   elapsedMs: 13000, 27500, 43500, 61000, 80000, 100500, 122500, 146000, 171000
///   window:    splits with elapsedMs >= 150000 → only split 9 → fall back to last 2
///   CS:        mean(1.0638, 1.0000) = 1.03191 m/s
///   battery:   Σ(v� − CS) × tᵢ for vᵢ > CS, splits 1–8 = ~49.35 m
func runSprinterCurve() -> Bool {
    print("\n=== TEST 1: Sprinter curve ===")
    let splits = [13.0, 14.5, 16.0, 17.5, 19.0, 20.5, 22.0, 23.5, 25.0]
    let laps = makeLaps(splitTimesSec: splits)

    let result = ThreeMinuteTestAnalyzer.analyze(
        laps: laps,
        poolLengthMeters: 25,
        expectedPeakSpeedMps: nil,
        trialNumber: 3  // not a learning trial — isolate the other flags
    )

    guard let r = result else {
        print("  [FAIL] analyzer returned nil")
        return false
    }

    print("  curveShape: \(r.curveShape.map { fmt($0, decimals: 4) })")
    print("  qualityFlags: \(r.qualityFlags.map { $0.rawValue })")

    var allPass = true
    allPass = assertClose("peakSpeedMps", actual: r.peakSpeedMps, expected: 25.0 / 13.0, tolerance: 1e-4) && allPass
    allPass = assertClose("criticalSpeedMps", actual: r.criticalSpeedMps, expected: 1.03191, tolerance: 1e-3) && allPass
    // Hand-recomputed battery ~49.35 m. Tolerance ±1m per the spec.
    allPass = assertClose("batteryMeters", actual: r.batteryMeters, expected: 49.35, tolerance: 1.0) && allPass
    allPass = assertClose("curveShape.count", actual: Double(r.curveShape.count), expected: 9.0, tolerance: 1e-9) && allPass
    allPass = assertFlagAbsent("no .pacedStart", flags: r.qualityFlags, .pacedStart) && allPass
    allPass = assertFlagAbsent("no .flatCurve", flags: r.qualityFlags, .flatCurve) && allPass
    allPass = assertFlagAbsent("no .learningTrial (trial=3)", flags: r.qualityFlags, .learningTrial) && allPass

    print("  -> TEST 1: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

/// TEST 2 — Distance curve. 10 splits, small peak-to-CS drop (~25%). No
/// flat-curve (CS/peak ~75%). No paced-start (split 1 ≥ splits 2 and 3).
///
/// Hand-recomputed:
///   speeds:    1.6129, 1.5432, 1.4881, 1.4368, 1.3889, 1.3441, 1.3021, 1.2626, 1.2255, 1.1905
///   peak:      25 / 15.5 = 1.61290 m/s
///   elapsedMs: 15500, 31700, 48500, 65900, 83900, 102500, 121700, 141500, 161900, 182900
///   window:    splits 9, 10 (both ≥ 150000ms) → 2 in window
///   CS:        mean(1.2255, 1.1905) = 1.20800 m/s
///   CS/peak:   1.20800 / 1.61290 = 0.7490 → NOT flatCurve (drop is 25%)
func runDistanceCurve() -> Bool {
    print("\n=== TEST 2: Distance curve ===")
    let splits = [15.5, 16.2, 16.8, 17.4, 18.0, 18.6, 19.2, 19.8, 20.4, 21.0]
    let laps = makeLaps(splitTimesSec: splits)

    let result = ThreeMinuteTestAnalyzer.analyze(
        laps: laps,
        poolLengthMeters: 25,
        expectedPeakSpeedMps: nil,
        trialNumber: 3
    )

    guard let r = result else {
        print("  [FAIL] analyzer returned nil")
        return false
    }

    print("  curveShape: \(r.curveShape.map { fmt($0, decimals: 4) })")
    print("  qualityFlags: \(r.qualityFlags.map { $0.rawValue })")

    var allPass = true
    allPass = assertClose("peakSpeedMps", actual: r.peakSpeedMps, expected: 25.0 / 15.5, tolerance: 1e-4) && allPass
    allPass = assertClose("criticalSpeedMps", actual: r.criticalSpeedMps, expected: 1.20800, tolerance: 1e-3) && allPass
    allPass = assertFlagAbsent("no .pacedStart", flags: r.qualityFlags, .pacedStart) && allPass
    allPass = assertFlagAbsent("no .flatCurve (drop ~25%, not flat)", flags: r.qualityFlags, .flatCurve) && allPass
    allPass = assertFlagAbsent("no .learningTrial (trial=3)", flags: r.qualityFlags, .learningTrial) && allPass

    print("  -> TEST 2: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

/// TEST 3 — Paced start. Split 1 (1.39 m/s) is slower than splits 2 (1.79) and
/// 3 (1.85). The .pacedStart flag fires. This is the classic "didn't go
/// all-out from the push-off" signature (research doc §1.5.2).
///
/// Hand-recomputed:
///   speeds:    1.3889, 1.7857, 1.8519, 1.4706, 1.3514, 1.2500, 1.1628, 1.0870, 1.0204
///   v1 < v2:   1.3889 < 1.7857 → TRUE → pacedStart SET
func runPacedStart() -> Bool {
    print("\n=== TEST 3: Paced start ===")
    let splits = [18.0, 14.0, 13.5, 17.0, 18.5, 20.0, 21.5, 23.0, 24.5]
    let laps = makeLaps(splitTimesSec: splits)

    let result = ThreeMinuteTestAnalyzer.analyze(
        laps: laps,
        poolLengthMeters: 25,
        expectedPeakSpeedMps: nil,
        trialNumber: 3
    )

    guard let r = result else {
        print("  [FAIL] analyzer returned nil")
        return false
    }

    print("  curveShape: \(r.curveShape.map { fmt($0, decimals: 4) })")
    print("  qualityFlags: \(r.qualityFlags.map { $0.rawValue })")

    var allPass = true
    allPass = assertFlagPresent(".pacedStart SET (split 1 slower than splits 2 and 3)", flags: r.qualityFlags, .pacedStart) && allPass

    print("  -> TEST 3: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

/// TEST 4 — Flat curve. All splits ≈ 17.0s ±0.2. Peak ≈ CS → .flatCurve SET.
/// We use 11 splits to ensure the test runs >150s and the window catches
/// multiple splits (with all speeds ~1.47 m/s, CS/peak → 1.0, well over 90%).
///
/// Hand-recomputed (using exactly 17.0s for all 11):
///   speed:     25/17.0 = 1.4706 m/s for every split
///   elapsedMs: 17000, 34000, 51000, 68000, 85000, 102000, 119000, 136000, 153000, 170000, 187000
///   window:    splits 9, 10, 11 (all ≥ 150000ms)
///   CS:        mean(1.4706, 1.4706, 1.4706) = 1.4706
///   CS/peak:   1.0000 ≥ 0.90 → flatCurve SET
func runFlatCurve() -> Bool {
    print("\n=== TEST 4: Flat curve ===")
    // Splits ≈ 17.0 ±0.2. We use 11 splits to be safely >150s.
    let splits: [Double] = [16.8, 17.0, 17.2, 16.9, 17.1, 17.0, 16.8, 17.2, 17.0, 16.9, 17.1]
    let laps = makeLaps(splitTimesSec: splits)

    let result = ThreeMinuteTestAnalyzer.analyze(
        laps: laps,
        poolLengthMeters: 25,
        expectedPeakSpeedMps: nil,
        trialNumber: 3
    )

    guard let r = result else {
        print("  [FAIL] analyzer returned nil")
        return false
    }

    print("  curveShape: \(r.curveShape.map { fmt($0, decimals: 4) })")
    print("  qualityFlags: \(r.qualityFlags.map { $0.rawValue })")

    var allPass = true
    // CS and peak should be very close (within the noise).
    let csPeakRatio = r.criticalSpeedMps / r.peakSpeedMps
    allPass = assertClose("CS/peak ratio (flat curve)", actual: csPeakRatio, expected: 1.0, tolerance: 0.05) && allPass
    allPass = assertFlagPresent(".flatCurve SET", flags: r.qualityFlags, .flatCurve) && allPass
    allPass = assertFlagAbsent("no .pacedStart", flags: r.qualityFlags, .pacedStart) && allPass

    print("  -> TEST 4: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

/// TEST 5 — Learning trial flag. The sprinter curve (test 1) with
/// trialNumber=1 → .learningTrial SET. Same curve with trialNumber=3 →
/// .learningTrial NOT SET. Familiarisation is mandatory per Piatrikova 2019.
func runLearningTrial() -> Bool {
    print("\n=== TEST 5: Learning trial flag ===")
    let splits = [13.0, 14.5, 16.0, 17.5, 19.0, 20.5, 22.0, 23.5, 25.0]
    let laps = makeLaps(splitTimesSec: splits)

    var allPass = true

    // trialNumber = 1 → learningTrial SET
    if let r1 = ThreeMinuteTestAnalyzer.analyze(
        laps: laps, poolLengthMeters: 25,
        expectedPeakSpeedMps: nil, trialNumber: 1
    ) {
        print("  trialNumber=1 qualityFlags: \(r1.qualityFlags.map { $0.rawValue })")
        allPass = assertFlagPresent(".learningTrial SET on trial 1", flags: r1.qualityFlags, .learningTrial) && allPass
    } else {
        print("  [FAIL] analyzer returned nil for trial 1")
        allPass = false
    }

    // trialNumber = 3 → learningTrial NOT SET
    if let r3 = ThreeMinuteTestAnalyzer.analyze(
        laps: laps, poolLengthMeters: 25,
        expectedPeakSpeedMps: nil, trialNumber: 3
    ) {
        print("  trialNumber=3 qualityFlags: \(r3.qualityFlags.map { $0.rawValue })")
        allPass = assertFlagAbsent(".learningTrial NOT SET on trial 3", flags: r3.qualityFlags, .learningTrial) && allPass
    } else {
        print("  [FAIL] analyzer returned nil for trial 3")
        allPass = false
    }

    print("  -> TEST 5: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

/// TEST 6 — peakBelowExpected flag. The distance curve (peak ≈ 1.61 m/s) with
/// expectedPeakSpeedMps=2.5 → 1.6129 < 0.95 × 2.5 = 2.375 → SET. With
/// expectedPeakSpeedMps=1.5 → 1.6129 > 0.95 × 1.5 = 1.425 → NOT SET. With
/// nil → not evaluated (not set).
///
/// Hand-recomputed:
///   peak = 25 / 15.5 = 1.61290 m/s
///   expected=2.5 → 95% = 2.37500 → peak (1.61290) < 2.37500 → SET
///   expected=1.5 → 95% = 1.42500 → peak (1.61290) > 1.42500 → NOT SET
func runPeakBelowExpected() -> Bool {
    print("\n=== TEST 6: peakBelowExpected flag ===")
    let splits = [15.5, 16.2, 16.8, 17.4, 18.0, 18.6, 19.2, 19.8, 20.4, 21.0]
    let laps = makeLaps(splitTimesSec: splits)

    var allPass = true

    // expected = 2.5 → peak (1.6129) < 0.95 × 2.5 → SET
    if let r = ThreeMinuteTestAnalyzer.analyze(
        laps: laps, poolLengthMeters: 25,
        expectedPeakSpeedMps: 2.5, trialNumber: 3
    ) {
        print("  expected=2.5 qualityFlags: \(r.qualityFlags.map { $0.rawValue })")
        allPass = assertFlagPresent(".peakBelowExpected SET (peak 1.61 < 95% of 2.5)", flags: r.qualityFlags, .peakBelowExpected) && allPass
    } else {
        print("  [FAIL] analyzer returned nil for expected=2.5")
        allPass = false
    }

    // expected = 1.5 → peak (1.6129) > 0.95 × 1.5 → NOT SET
    if let r = ThreeMinuteTestAnalyzer.analyze(
        laps: laps, poolLengthMeters: 25,
        expectedPeakSpeedMps: 1.5, trialNumber: 3
    ) {
        print("  expected=1.5 qualityFlags: \(r.qualityFlags.map { $0.rawValue })")
        allPass = assertFlagAbsent(".peakBelowExpected NOT SET (peak 1.61 > 95% of 1.5)", flags: r.qualityFlags, .peakBelowExpected) && allPass
    } else {
        print("  [FAIL] analyzer returned nil for expected=1.5")
        allPass = false
    }

    print("  -> TEST 6: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - Main

@main
struct ThreeMinuteTestCLITest {
    static func main() {
        print("=== ThreeMinuteTestAnalyzer CLI Test — V0.38 Slice 2 ===")
        print("=== Pure Swift, stdlib only, no XCTest ===")
        print("=== 6 cases per V0.38_SPEC §Slice 2 acceptance ===")
        print("")

        let results: [(String, Bool)] = [
            ("TEST 1 sprinter curve",   runSprinterCurve()),
            ("TEST 2 distance curve",   runDistanceCurve()),
            ("TEST 3 paced start",      runPacedStart()),
            ("TEST 4 flat curve",       runFlatCurve()),
            ("TEST 5 learning trial",   runLearningTrial()),
            ("TEST 6 peakBelowExpected", runPeakBelowExpected()),
        ]

        print("\n=== Summary ===")
        var allPass = true
        for (name, passed) in results {
            let mark = passed ? "PASS" : "FAIL"
            print("  [\(mark)] \(name)")
            if !passed { allPass = false }
        }
        print("")
        print("=== Overall: \(allPass ? "ALL PASS ✓" : "FAILURES ✗") ===")

        if !allPass {
            // Exit non-zero so CI/scripts detect failures.
            exit(1)
        }
    }
}
