// ThreeMTCopyCLITest — V0.38 Slice 5 — pure-logic CLI test of the
// 3MT review surface's coach-vocabulary mapping, pace conversion,
// and signal-color logic. Exercises the production helpers in
// `ThreeMTReviewSupport.swift` against synthetic flag strings and
// speed inputs so the strings the coach sees can be
// regression-gated on the orchestrator Mac without a booted
// simulator or a Supabase client.
//
// What it covers:
//   1. flagCopy(_:) per-flag mapping — each of the four
//      analyzer rawValues (learning_trial, paced_start,
//      flat_curve, peak_below_expected) maps to its exact coach-
//      copy phrase. The phrase strings are the canonical
//      user-facing surface — a typo here ships to coaches.
//   2. flagCopy(qualityFlags:) — the multi-flag joiner uses
//      " · " between phrases, returns nil for an empty array
//      (the view hides the line in that case).
//   3. thresholdPaceString(criticalSpeedMps:) — the m/s →
//      per-100m pace conversion matches the app's existing
//      "m:ss" format. Worked examples: 1.25 m/s → "1:20/100m";
//      1.00 m/s → "1:40/100m"; 2.00 m/s → "0:30/100m".
//      Edge cases: <=0 → nil, non-finite → nil.
//   4. threeMTSignal(profile:) — the deterministic signal
//      mapping: learningTrial-only → gray, any other flag →
//      amber, no flags → green, profile missing → red.
//
// Usage: ThreeMTCopyCLITest
// Compiled by build_and_run_3mtcopy.sh.

import Foundation

// MARK: - Helpers

func assertEq<T: Equatable>(_ label: String, _ actual: T, _ expected: T) -> Bool {
    let ok = actual == expected
    let mark = ok ? "PASS" : "FAIL"
    print("  [\(mark)] \(label): actual=\(actual) expected=\(expected)")
    return ok
}

func assertTrue(_ label: String, _ condition: Bool, extra: String = "") -> Bool {
    let mark = condition ? "PASS" : "FAIL"
    let suffix = extra.isEmpty ? "" : " (\(extra))"
    print("  [\(mark)] \(label)\(suffix)")
    return condition
}

// MARK: - TEST 1 — flagCopy(_:) per-flag mapping

/// Verifies the four canonical flag→copy mappings. These strings
/// are user-facing surface — a regression here ships to coaches
/// as a typo. The work order (line 27) pins each phrase.
func runFlagCopyMapping() -> Bool {
    print("\n=== TEST 1: flagCopy(_:) per-flag mapping ===")

    var allPass = true
    allPass = assertEq(
        "learning_trial → coach phrase",
        flagCopy("learning_trial"),
        "Learning trial — repeat before using for zones"
    ) && allPass
    allPass = assertEq(
        "paced_start → coach phrase",
        flagCopy("paced_start"),
        "Started paced — not a true all-out"
    ) && allPass
    allPass = assertEq(
        "flat_curve → coach phrase",
        flagCopy("flat_curve"),
        "Even pace throughout — sprint the start next time"
    ) && allPass
    allPass = assertEq(
        "peak_below_expected → coach phrase",
        flagCopy("peak_below_expected"),
        "Top speed below their usual — check effort"
    ) && allPass

    // Banned-vocabulary check (work order line 5). The four
    // phrases must NOT contain the jargon the spec bans.
    let banned = ["anaerobic", "D′", "D'", "confidence"]
    for (flag, phrase) in [
        ("learning_trial", flagCopy("learning_trial")),
        ("paced_start", flagCopy("paced_start")),
        ("flat_curve", flagCopy("flat_curve")),
        ("peak_below_expected", flagCopy("peak_below_expected"))
    ] {
        for word in banned {
            allPass = assertTrue(
                "phrase for \(flag) does not contain banned term \"\(word)\"",
                !phrase.contains(word),
                extra: "phrase=\"\(phrase)\""
            ) && allPass
        }
    }

    // Unknown flag → pass-through (defensive so the coach sees
    // something rather than a silent drop).
    allPass = assertEq(
        "unknown flag passes through unchanged",
        flagCopy("some_future_flag"),
        "some_future_flag"
    ) && allPass

    print("  -> TEST 1: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - TEST 2 — multi-flag joiner

/// Verifies the joiner: empty array → nil (view hides the line),
/// single flag → that flag's phrase, multiple flags → joined
/// with " · " in input order.
func runFlagJoiner() -> Bool {
    print("\n=== TEST 2: multi-flag joiner ===")

    var allPass = true

    // Empty → nil
    allPass = assertTrue(
        "empty flags → nil",
        flagCopy(qualityFlags: []) == nil
    ) && allPass

    // Single flag → that phrase
    allPass = assertEq(
        "single flag → single phrase",
        flagCopy(qualityFlags: ["learning_trial"]),
        "Learning trial — repeat before using for zones"
    ) && allPass

    // Two flags → joined
    allPass = assertEq(
        "two flags → joined with \" · \"",
        flagCopy(qualityFlags: ["learning_trial", "paced_start"]),
        "Learning trial — repeat before using for zones · Started paced — not a true all-out"
    ) && allPass

    // Three flags → joined (input order preserved)
    allPass = assertEq(
        "three flags → joined, input order preserved",
        flagCopy(qualityFlags: ["paced_start", "flat_curve", "peak_below_expected"]),
        "Started paced — not a true all-out · Even pace throughout — sprint the start next time · Top speed below their usual — check effort"
    ) && allPass

    print("  -> TEST 2: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - TEST 3 — pace conversion

/// Verifies thresholdPaceString(criticalSpeedMps:) produces the
/// expected "m:ss/100m" strings for representative critical-speed
/// values. The "m:ss" format mirrors the app's existing
/// `WorkoutParser.parseInterval` and `TimingSession.formatMs`
/// format.
func runPaceConversion() -> Bool {
    print("\n=== TEST 3: pace conversion (m/s → per-100m) ===")

    var allPass = true

    // The work order's worked example (line 42):
    //   1.25 m/s → "1:20/100m"  (100/1.25 = 80s = 1:20)
    allPass = assertEq(
        "1.25 m/s → \"1:20/100m\"",
        thresholdPaceString(criticalSpeedMps: 1.25) ?? "nil",
        "1:20/100m"
    ) && allPass

    // 1.00 m/s → 100s → 1:40/100m
    allPass = assertEq(
        "1.00 m/s → \"1:40/100m\"",
        thresholdPaceString(criticalSpeedMps: 1.00) ?? "nil",
        "1:40/100m"
    ) && allPass

    // 2.00 m/s → 50s → 0:50/100m
    allPass = assertEq(
        "2.00 m/s → \"0:50/100m\"",
        thresholdPaceString(criticalSpeedMps: 2.00) ?? "nil",
        "0:50/100m"
    ) && allPass

    // 1.50 m/s → 66.67s → rounds to 67s → 1:07/100m
    allPass = assertEq(
        "1.50 m/s → \"1:07/100m\" (66.67s rounds to 67)",
        thresholdPaceString(criticalSpeedMps: 1.50) ?? "nil",
        "1:07/100m"
    ) && allPass

    // Sub-30s pace (a fast sprinter's CS): 4.00 m/s → 25s → 0:25/100m
    allPass = assertEq(
        "4.00 m/s → \"0:25/100m\"",
        thresholdPaceString(criticalSpeedMps: 4.00) ?? "nil",
        "0:25/100m"
    ) && allPass

    // Edge cases
    allPass = assertTrue(
        "0 m/s → nil (undefined pace)",
        thresholdPaceString(criticalSpeedMps: 0.0) == nil
    ) && allPass
    allPass = assertTrue(
        "negative m/s → nil (defensive)",
        thresholdPaceString(criticalSpeedMps: -1.0) == nil
    ) && allPass
    allPass = assertTrue(
        "non-finite m/s → nil (defensive)",
        thresholdPaceString(criticalSpeedMps: .nan) == nil
    ) && allPass
    allPass = assertTrue(
        "infinity m/s → nil (defensive)",
        thresholdPaceString(criticalSpeedMps: .infinity) == nil
    ) && allPass

    // The pace string must contain "/100m" — coach vocabulary
    // pins the unit so the coach reads it as per-100m pace, not
    // per-25m (the actual 3MT split distance).
    let sample = thresholdPaceString(criticalSpeedMps: 1.25) ?? ""
    allPass = assertTrue(
        "pace string contains \"/100m\" unit suffix",
        sample.contains("/100m"),
        extra: "sample=\"\(sample)\""
    ) && allPass

    // Banned-vocabulary check — no jargon in the pace string.
    let banned = ["anaerobic", "D′", "D'", "confidence", "critical"]
    for word in banned {
        allPass = assertTrue(
            "pace string does not contain banned term \"\(word)\"",
            !sample.contains(word),
            extra: "sample=\"\(sample)\""
        ) && allPass
    }

    print("  -> TEST 3: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - TEST 4 — signal color mapping

/// Verifies threeMTSignal(profile:) produces the right signal for
/// each combination of profile presence + flags.
///
/// Deterministic mapping per the work order:
///   - learningTrial only        → gray
///   - learningTrial + other     → amber (other wins)
///   - any other flag (alone)    → amber
///   - no flags                  → green
///   - profile missing (nil)     → red
func runSignalColor() -> Bool {
    print("\n=== TEST 4: signal color mapping ===")

    var allPass = true

    // Profile missing → red
    allPass = assertEq(
        "nil profile → .red",
        threeMTSignal(profile: nil),
        .red
    ) && allPass

    // No flags → green
    let clean = makeProfile(flags: [])
    allPass = assertEq(
        "no flags → .green",
        threeMTSignal(profile: clean),
        .green
    ) && allPass

    // learningTrial alone → gray
    let learningOnly = makeProfile(flags: ["learning_trial"])
    allPass = assertEq(
        "learning_trial alone → .gray",
        threeMTSignal(profile: learningOnly),
        .gray
    ) && allPass

    // paced_start alone → amber
    let pacedOnly = makeProfile(flags: ["paced_start"])
    allPass = assertEq(
        "paced_start alone → .amber",
        threeMTSignal(profile: pacedOnly),
        .amber
    ) && allPass

    // flat_curve alone → amber
    let flatOnly = makeProfile(flags: ["flat_curve"])
    allPass = assertEq(
        "flat_curve alone → .amber",
        threeMTSignal(profile: flatOnly),
        .amber
    ) && allPass

    // peak_below_expected alone → amber
    let peakOnly = makeProfile(flags: ["peak_below_expected"])
    allPass = assertEq(
        "peak_below_expected alone → .amber",
        threeMTSignal(profile: peakOnly),
        .amber
    ) && allPass

    // learning_trial + paced_start → amber (the non-learning flag
    // wins; learning is "familiarisation noise" and shouldn't
    // mask a real data issue).
    let learningPlusPaced = makeProfile(flags: ["learning_trial", "paced_start"])
    allPass = assertEq(
        "learning_trial + paced_start → .amber (paced wins)",
        threeMTSignal(profile: learningPlusPaced),
        .amber
    ) && allPass

    // learning_trial + flat_curve → amber
    let learningPlusFlat = makeProfile(flags: ["learning_trial", "flat_curve"])
    allPass = assertEq(
        "learning_trial + flat_curve → .amber (flat wins)",
        threeMTSignal(profile: learningPlusFlat),
        .amber
    ) && allPass

    // All four flags → amber (still amber, not gray; the data
    // issue wins over familiarisation).
    let allFlags = makeProfile(flags: [
        "learning_trial", "paced_start", "flat_curve", "peak_below_expected"
    ])
    allPass = assertEq(
        "all four flags → .amber",
        threeMTSignal(profile: allFlags),
        .amber
    ) && allPass

    print("  -> TEST 4: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - Helpers — SwimmerTestProfile synthesis

/// Build a `SwimmerTestProfile` with the given quality flags. All
/// other fields use placeholder values — the signal mapper only
/// reads `qualityFlags`. The CLI runner doesn't have a Supabase
/// client so it can't decode a real row; this shim fills in
/// reasonable defaults and the mapper exercises the same code
/// path either way.
func makeProfile(flags: [String]) -> SwimmerTestProfile {
    return SwimmerTestProfile(
        id: UUID().uuidString,
        swimmerId: UUID().uuidString,
        sessionId: nil,
        workoutSetId: nil,
        stroke: "Free",
        poolLength: 25,
        testDate: ISO8601DateFormatter().string(from: Date()),
        trialNumber: 1,
        peakSpeedMps: 1.9,
        criticalSpeedMps: 1.3,
        batteryMeters: 25.0,
        qualityFlags: flags
    )
}

// MARK: - Main

@main
struct ThreeMTCopyCLITest {
    static func main() {
        print("=== ThreeMTCopyCLI Test — V0.38 Slice 5 ===")
        print("=== Pure-logic gate for the 3MT review surface ===")
        print("=== Coach vocabulary, pace conversion, signal colors ===")
        print("=== Exercises real flagCopy / thresholdPaceString / ===")
        print("=== threeMTSignal from ThreeMTReviewSupport.swift ===")
        print("")

        let flagPass = runFlagCopyMapping()
        let joinPass = runFlagJoiner()
        let pacePass = runPaceConversion()
        let signalPass = runSignalColor()

        let results: [(String, Bool)] = [
            ("TEST 1 flagCopy(_:) per-flag mapping", flagPass),
            ("TEST 2 multi-flag joiner",              joinPass),
            ("TEST 3 pace conversion",                pacePass),
            ("TEST 4 signal color mapping",           signalPass),
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
            exit(1)
        }
    }
}
