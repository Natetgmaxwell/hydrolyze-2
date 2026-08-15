// ThreeMTSaveCLITest — V0.38 Slice 4 — pure-logic CLI test of the
// 3MT save flow's NEW pieces. Exercises the production code path
// (groupSplitsPerSwimmer + assembleTestProfiles + the real
// ThreeMinuteTestAnalyzer) against synthetic LapAssignments and
// per-swimmer split groups, so the analyzer wiring + row assembly
// can be regression-gated on the orchestrator Mac without a Supabase
// client or booted simulator.
//
// What it covers:
//   1. trial-number increment: existingMax[swimmer]=N → trial=N+1;
//      missing key → trial=1
//   2. per-swimmer split grouping: assignments → [String: [Lap]]
//      ordered by lapNumber
//   3. analyzer wiring: the produced peak/CS/battery match the
//      analyzer's hand-recomputed values for the same splits
//   4. profile row assembly: dates are ISO8601, trial_number is Int,
//      meter columns are Double, quality_flags are the rawValue strings,
//      swimmer_id / session_id / workout_set_id flow through, no
//      fewer than 3 splits produces no row
//   5. quality_flags rawValue forwarding (flat_curve + learning_trial
//      rawValues match the migration's jsonb column expectations)
//
// Usage: ThreeMTSaveCLITest
// Compiled by build_and_run_3mtsave.sh.

import Foundation

// MARK: - Helpers

func fmt(_ x: Double, decimals: Int = 4) -> String {
    return String(format: "%.\(decimals)f", x)
}

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

func assertTrue(_ label: String, _ condition: Bool, extra: String = "") -> Bool {
    let mark = condition ? "PASS" : "FAIL"
    let suffix = extra.isEmpty ? "" : " (\(extra))"
    print("  [\(mark)] \(label)\(suffix)")
    return condition
}

func assertEq<T: Equatable>(_ label: String, _ actual: T, _ expected: T) -> Bool {
    let ok = actual == expected
    let mark = ok ? "PASS" : "FAIL"
    print("  [\(mark)] \(label): actual=\(actual) expected=\(expected)")
    return ok
}

/// Build a [Lap] from split times in seconds, like the slice-2 CLI
/// test does. Laps are 1-indexed; `elapsedMs` is the cumulative sum.
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

// MARK: - TEST 1 — trial-number increment

/// Trial-number math: trial = (existing max for this swimmer) + 1.
/// - Swimmer A has existing max = 2 → trial 3
/// - Swimmer B has existing max = 0 → trial 1
/// - Swimmer C has no row at all → trial 1
///
/// The "no row" case is the same path as "max = 0" — both produce
/// trial 1 — so the reduce on a missing key must default to 0.
func runTrialIncrement() -> Bool {
    print("\n=== TEST 1: trial-number increment ===")
    let lapsA = makeLaps(splitTimesSec: [13.0, 14.5, 16.0, 17.5, 19.0, 20.5, 22.0, 23.5, 25.0])
    let lapsB = makeLaps(splitTimesSec: [15.5, 16.2, 16.8, 17.4, 18.0, 18.6, 19.2, 19.8, 20.4, 21.0])
    let lapsC = makeLaps(splitTimesSec: [14.0, 14.5, 15.0, 15.5, 16.0, 16.5, 17.0, 17.5, 18.0])

    let existingMax: [String: Int] = [
        "00000000-0000-0000-0000-000000000001": 2,
        "00000000-0000-0000-0000-000000000002": 0
        // swimmer C intentionally absent
    ]
    let rows = assembleTestProfiles(
        swimmerAssignments: [
            "00000000-0000-0000-0000-000000000001": lapsA,
            "00000000-0000-0000-0000-000000000002": lapsB,
            "00000000-0000-0000-0000-000000000003": lapsC
        ],
        workoutSetId: "ws-1",
        sessionId: "sess-1",
        stroke: "Free",
        poolLengthMeters: 25,
        existingMaxTrialBySwimmer: existingMax,
        testDate: Date(timeIntervalSince1970: 1_700_000_000)
    )

    var allPass = true
    allPass = assertEq("3 rows (all 3 swimmers produced splits ≥ 3)", rows.count, 3) && allPass
    let bySwimmer = Dictionary(uniqueKeysWithValues: rows.map { ($0.swimmer_id, $0) })
    allPass = assertEq("swimmer A trial = 3 (existing max 2 + 1)", bySwimmer["00000000-0000-0000-0000-000000000001"]?.trial_number ?? -1, 3) && allPass
    allPass = assertEq("swimmer B trial = 1 (existing max 0 + 1)", bySwimmer["00000000-0000-0000-0000-000000000002"]?.trial_number ?? -1, 1) && allPass
    allPass = assertEq("swimmer C trial = 1 (no existing row → 0 + 1)", bySwimmer["00000000-0000-0000-0000-000000000003"]?.trial_number ?? -1, 1) && allPass

    print("  -> TEST 1: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - TEST 2 — per-swimmer split grouping

/// `groupSplitsPerSwimmer` takes [LapAssignment] and returns
/// [String: [Lap]] keyed by swimmerId.uuidString, with each value's
/// laps sorted by lapNumber. We synthesize assignments across 3
/// swimmers in intentionally scrambled order to verify the sort.
func runSplitGrouping() -> Bool {
    print("\n=== TEST 2: per-swimmer split grouping ===")

    // Build laps with a single shared timeline so the 1-indexed
    // lapNumber is unambiguous across swimmers.
    let splits = [13.0, 14.0, 14.5, 15.0, 15.5, 16.0, 16.5, 17.0, 17.5]
    let sharedLaps = makeLaps(splitTimesSec: splits)

    // 3 swimmers, 3 splits each. Mix the insertion order to force
    // the sort. The pairing engine emits assignments in a
    // non-deterministic order in practice (it's whatever the
    // engine decided to write).
    let s1 = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let s2 = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    let s3 = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    // Hand-build LapAssignments so we can scramble the order.
    func assignment(swimmerId: UUID, lap: Lap, id: String) -> LapAssignment {
        return LapAssignment(
            id: id,
            lap: lap,
            swimmerId: swimmerId,
            confidence: 90,
            assignmentConfidence: 0.95,
            workoutSetId: "ws-1",
            waveNumber: 0
        )
    }

    // Scrambled insertion: s2 first, then s1, then s3, then s2 again,
    // then s1 again, then s3 again, etc.
    let assignments: [LapAssignment] = [
        assignment(swimmerId: s2, lap: sharedLaps[2], id: "a1"),
        assignment(swimmerId: s1, lap: sharedLaps[0], id: "a2"),
        assignment(swimmerId: s3, lap: sharedLaps[1], id: "a3"),
        assignment(swimmerId: s2, lap: sharedLaps[0], id: "a4"),
        assignment(swimmerId: s1, lap: sharedLaps[1], id: "a5"),
        assignment(swimmerId: s3, lap: sharedLaps[2], id: "a6"),
        assignment(swimmerId: s2, lap: sharedLaps[1], id: "a7"),
        assignment(swimmerId: s1, lap: sharedLaps[2], id: "a8"),
        assignment(swimmerId: s3, lap: sharedLaps[0], id: "a9")
    ]

    let groups = groupSplitsPerSwimmer(assignments: assignments)

    var allPass = true
    allPass = assertEq("3 swimmers in groups", groups.count, 3) && allPass
    allPass = assertEq("s1 has 3 splits", groups[s1.uuidString]?.count ?? -1, 3) && allPass
    allPass = assertEq("s2 has 3 splits", groups[s2.uuidString]?.count ?? -1, 3) && allPass
    allPass = assertEq("s3 has 3 splits", groups[s3.uuidString]?.count ?? -1, 3) && allPass

    // Verify ordering: each group is sorted ascending by lapNumber.
    for (swimmerId, laps) in groups {
        let sorted = laps.sorted { $0.lapNumber < $1.lapNumber }
        allPass = assertEq("\(swimmerId.prefix(8))… sorted by lapNumber", laps.map(\.lapNumber), sorted.map(\.lapNumber)) && allPass
    }
    // Specifically: s1 → [1, 2, 3], s2 → [1, 2, 3], s3 → [1, 2, 3]
    allPass = assertEq("s1 lapNumbers ascending", groups[s1.uuidString]?.map(\.lapNumber) ?? [], [1, 2, 3]) && allPass
    allPass = assertEq("s2 lapNumbers ascending", groups[s2.uuidString]?.map(\.lapNumber) ?? [], [1, 2, 3]) && allPass
    allPass = assertEq("s3 lapNumbers ascending", groups[s3.uuidString]?.map(\.lapNumber) ?? [], [1, 2, 3]) && allPass

    print("  -> TEST 2: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - TEST 3 — analyzer wiring

/// Real `ThreeMinuteTestAnalyzer.analyze` runs on the grouped splits.
/// The sprinter curve from the slice-2 CLI test (peak = 25/13,
/// CS = mean of last 2 splits, battery ~49.35 m) — verifying that
/// the same numbers fall out the other end of the assembly function
/// proves the wiring is correct end-to-end (groupSplits → analyzer
/// → row fields).
func runAnalyzerWiring() -> Bool {
    print("\n=== TEST 3: analyzer wiring (real ThreeMinuteTestAnalyzer) ===")
    let splits = [13.0, 14.5, 16.0, 17.5, 19.0, 20.5, 22.0, 23.5, 25.0]
    let laps = makeLaps(splitTimesSec: splits)

    let swimmerId = "00000000-0000-0000-0000-000000000aaa"
    let rows = assembleTestProfiles(
        swimmerAssignments: [swimmerId: laps],
        workoutSetId: "ws-1",
        sessionId: "sess-1",
        stroke: "Free",
        poolLengthMeters: 25,
        existingMaxTrialBySwimmer: [swimmerId: 3], // NOT a learning trial — isolate other flags
        testDate: Date(timeIntervalSince1970: 1_700_000_000)
    )

    guard let row = rows.first else {
        print("  [FAIL] assembleTestProfiles returned no rows for 9-split swimmer")
        return false
    }

    var allPass = true
    // Hand-recomputed values (from the slice-2 CLI test):
    //   peak = 25/13 = 1.92308 m/s
    //   CS   = mean(1.0638, 1.0000) = 1.03191 m/s (last 2 splits fall
    //         outside the [150s, 180s] window with only 9 splits)
    //   battery ≈ 49.35 m
    allPass = assertClose("peak_speed_mps (real analyzer, wired through assembly)",
                          actual: row.peak_speed_mps, expected: 25.0 / 13.0, tolerance: 1e-4) && allPass
    allPass = assertClose("critical_speed_mps",
                          actual: row.critical_speed_mps, expected: 1.03191, tolerance: 1e-3) && allPass
    allPass = assertClose("battery_m",
                          actual: row.battery_m, expected: 49.35, tolerance: 1.0) && allPass

    // Field-type assertions: dates are ISO8601, trial_number is Int,
    // meter columns are Double, quality_flags are rawValue strings.
    let isoFmt = ISO8601DateFormatter()
    let parsedDate = isoFmt.date(from: row.test_date)
    allPass = assertTrue("test_date is parseable ISO8601",
                         parsedDate != nil,
                         extra: "test_date=\(row.test_date)") && allPass
    allPass = assertTrue("test_date round-trips to the input Date",
                         parsedDate?.timeIntervalSince1970 == 1_700_000_000,
                         extra: "parsed=\(parsedDate?.timeIntervalSince1970 ?? -1)") && allPass
    allPass = assertEq("trial_number is the incremented Int",
                       row.trial_number, 4) && allPass  // existing max 3 + 1
    // Type checks via introspection. We can't `is Int` directly but we
    // can verify the value type through behavior: Int + Double arithmetic
    // should compile only if the types match. Asserts on the magnitudes:
    allPass = assertTrue("peak_speed_mps is a finite Double", row.peak_speed_mps.isFinite) && allPass
    allPass = assertTrue("critical_speed_mps is a finite Double", row.critical_speed_mps.isFinite) && allPass
    allPass = assertTrue("battery_m is a finite Double", row.battery_m.isFinite) && allPass

    // Quality flags as rawValues (lowercase snake_case from the analyzer
    // enum). For a sprinter curve at trial=4 with no expectedPeak, no
    // .learningTrial, no .flatCurve, no .pacedStart, no .peakBelowExpected
    // should fire → empty array.
    allPass = assertEq("quality_flags empty (sprinter, trial 4)", row.quality_flags, []) && allPass

    // Identifiers flow through.
    allPass = assertEq("swimmer_id flows through", row.swimmer_id, swimmerId) && allPass
    allPass = assertEq("session_id flows through", row.session_id, "sess-1") && allPass
    allPass = assertEq("workout_set_id flows through", row.workout_set_id, "ws-1") && allPass
    allPass = assertEq("stroke flows through", row.stroke, "Free") && allPass
    allPass = assertEq("pool_length flows through", row.pool_length, 25) && allPass
    allPass = assertTrue("id is a non-empty UUID string",
                         UUID(uuidString: row.id) != nil,
                         extra: "id=\(row.id)") && allPass

    print("  -> TEST 3: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - TEST 4 — quality flags forward from analyzer

/// Verifies the rawValue strings in `quality_flags` round-trip
/// through the assembly. We use a flat curve (peak ≈ CS) so the
/// `.flatCurve` flag fires, AND trial 1 so the `.learningTrial`
/// flag fires. Both rawValues are the lowercase snake_case strings
/// the Postgres jsonb column expects.
func runQualityFlagsForward() -> Bool {
    print("\n=== TEST 4: quality_flags rawValue forwarding ===")
    // 11 splits, all ≈17s → flat curve (CS/peak ≈ 1.0).
    let splits: [Double] = [16.8, 17.0, 17.2, 16.9, 17.1, 17.0, 16.8, 17.2, 17.0, 16.9, 17.1]
    let laps = makeLaps(splitTimesSec: splits)
    let swimmerId = "00000000-0000-0000-0000-000000000bbb"

    // trial=1 → learningTrial; flat curve → flatCurve. We expect
    // BOTH rawValues in the row's quality_flags array.
    let rows = assembleTestProfiles(
        swimmerAssignments: [swimmerId: laps],
        workoutSetId: nil,  // also exercise the nil path
        sessionId: nil,
        stroke: "Free",
        poolLengthMeters: 25,
        existingMaxTrialBySwimmer: [swimmerId: 0],
        testDate: Date(timeIntervalSince1970: 1_700_000_000)
    )

    guard let row = rows.first else {
        print("  [FAIL] no row for 11-split swimmer")
        return false
    }

    var allPass = true
    allPass = assertTrue("flat_curve rawValue present",
                         row.quality_flags.contains("flat_curve"),
                         extra: "flags=\(row.quality_flags)") && allPass
    allPass = assertTrue("learning_trial rawValue present",
                         row.quality_flags.contains("learning_trial"),
                         extra: "flags=\(row.quality_flags)") && allPass
    allPass = assertEq("trial_number = 1 (existing max 0 + 1)", row.trial_number, 1) && allPass
    allPass = assertTrue("workout_set_id nil flows through as nil", row.workout_set_id == nil) && allPass
    allPass = assertTrue("session_id nil flows through as nil", row.session_id == nil) && allPass

    print("  -> TEST 4: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - TEST 5 — too-few-splits skips the row

/// A swimmer with only 2 splits (below the analyzer's ≥3 threshold)
/// produces no row. Mirrors the spec's "if fewer than 3 splits exist,
/// take the last 2 splits" smoothing rule, but the analyzer still
/// returns nil for the core `peak/CS/battery` numbers — so the
/// assembly function silently drops the row rather than persisting
/// garbage.
func runTooFewSplitsSkipped() -> Bool {
    print("\n=== TEST 5: too-few-splits skipped ===")
    let tooFew = makeLaps(splitTimesSec: [18.0, 19.0])  // only 2
    let plenty = makeLaps(splitTimesSec: [15.0, 16.0, 17.0, 18.0, 19.0, 20.0])

    let rows = assembleTestProfiles(
        swimmerAssignments: [
            "00000000-0000-0000-0000-000000000ccc": tooFew,
            "00000000-0000-0000-0000-000000000ddd": plenty
        ],
        workoutSetId: "ws-2",
        sessionId: "sess-2",
        stroke: "Free",
        poolLengthMeters: 25,
        existingMaxTrialBySwimmer: [:],
        testDate: Date(timeIntervalSince1970: 1_700_000_000)
    )

    var allPass = true
    allPass = assertEq("only the ≥3-split swimmer produces a row", rows.count, 1) && allPass
    allPass = assertTrue("the surviving row is swimmer D",
                         rows.first?.swimmer_id == "00000000-0000-0000-0000-000000000ddd",
                         extra: "actual=\(rows.first?.swimmer_id ?? "nil")") && allPass

    print("  -> TEST 5: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - Main

@main
struct ThreeMTSaveCLITest {
    static func main() {
        print("=== ThreeMTSaveCLI Test — V0.38 Slice 4 ===")
        print("=== Pure-logic gate for the 3MT save flow's NEW pieces ===")
        print("=== Exercises real groupSplitsPerSwimmer + assembleTestProfiles ===")
        print("=== + real ThreeMinuteTestAnalyzer, no Supabase, no XCTest. ===")
        print("")

        let trialPass = runTrialIncrement()
        let groupPass = runSplitGrouping()
        let wirePass = runAnalyzerWiring()
        let flagsPass = runQualityFlagsForward()
        let skipPass = runTooFewSplitsSkipped()

        let results: [(String, Bool)] = [
            ("TEST 1 trial-number increment",  trialPass),
            ("TEST 2 per-swimmer split grouping", groupPass),
            ("TEST 3 analyzer wiring",          wirePass),
            ("TEST 4 quality_flags forwarding", flagsPass),
            ("TEST 5 too-few-splits skipped",   skipPass),
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