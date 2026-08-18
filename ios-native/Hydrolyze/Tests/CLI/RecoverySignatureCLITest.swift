// RecoverySignatureCLITest — V0.42 Slice 1 (2026-08-18) — pure-logic
// CLI test for the recovery-signature aggregator. Exercises the
// production `RecoveryAggregator` + `RestEventRecord` against
// synthetic `set_rest_events` rows so the median-at-first-strike
// math, the revert rate, the weeklyTrend bucketing (ISO weeks,
// Monday-start), the coachSignatureLine copy, the coachRevertFlag
// copy, and the rep-count approximation can all be regression-gated
// on the orchestrator Mac without a booted simulator, UIKit, or
// Supabase.
//
// What it covers (V0.42 spec §Slice 1 Acceptance):
//   1. empty events → zeroed signature (median nil, totalStrikes 0,
//      revertRate 0)
//   2. known fixture → correct median ({3,4,5} → 4, {3,3,3} → 3)
//   3. only the FIRST strike per (swimmer, set) counts toward median
//      (within one set, rep 3 + rep 4 → only rep 3 counts)
//   4. avgDeltaSec + avgExtendedRestSec computed across strike rows
//   5. revertRate: 4/14 ≈ 0.2857, 4/10 = 0.4, 0 reverts → 0,
//      only reverts → 1.0
//   6. weeklyTrend buckets by ISO week (Monday-start): strike rows
//      across two weeks → two WeeklyStrainPoints
//   7. coachSignatureLine: nil median → nil; median 3 → the
//      committed coach string
//   8. coachRevertFlag: rate > 0.30 → flag; rate == 0.30 → nil
//      (strict >); rate 0.29 → nil; firstName substitution
//   9. rep-count approximation: set with strikes at rep_index {3,6}
//      contributes reps = 6 (max); two such sets → weekly reps 12
//
// Usage: RecoverySignatureCLITest
// Compiled by build_and_run_recoverysignature.sh.

import Foundation

// MARK: - Helpers

func rsPass(_ label: String, _ ok: Bool, extra: String = "") {
    let mark = ok ? "PASS" : "FAIL"
    let suffix = extra.isEmpty ? "" : " — \(extra)"
    print("  [\(mark)] \(label)\(suffix)")
}

func rsEq<T: Equatable>(_ label: String, _ actual: T, _ expected: T) -> Bool {
    let ok = actual == expected
    rsPass(label, ok, extra: "actual=\(actual) expected=\(expected)")
    return ok
}

func rsClose(_ label: String, _ actual: Double, _ expected: Double, _ tol: Double) -> Bool {
    let diff = abs(actual - expected)
    let ok = diff <= tol
    rsPass(label, ok, extra: "actual=\(actual) expected=\(expected) diff=\(diff) tol=\(tol)")
    return ok
}

func rsNilEq<T: Equatable>(_ label: String, _ actual: T?, _ expected: T?) -> Bool {
    let ok = actual == expected
    rsPass(label, ok, extra: "actual=\(String(describing: actual)) expected=\(String(describing: expected))")
    return ok
}

// MARK: - Fixture helpers

/// Mint a strike `RestEventRecord`. `setIdx` is an arbitrary unique
/// set index (used to differentiate `workout_set_id` between sets);
/// `workoutSetId`/`sessionId` let the test pin the set key when it
/// needs to control grouping (e.g., test 3 wants both rep 3 and
/// rep 4 strikes in the same set).
func mkStrike(
    setIdx: Int,
    repIndex: Int,
    deltaSec: Int = 30,
    extendedRestSec: Int = 210,
    baseRestSec: Int = 180,
    standardMs: Int = 60000,
    repTimeMs: Int = 60700,
    strikeCount: Int = 1,
    workoutSetId: String? = nil,
    sessionId: String? = nil,
    createdAt: String = "2025-08-11T12:00:00Z",
    swimmerId: String = "sw-A"
) -> RestEventRecord {
    return RestEventRecord(
        id: "id-s-\(setIdx)-\(repIndex)",
        session_id: sessionId,
        workout_set_id: workoutSetId ?? "ws-\(setIdx)",
        swimmer_id: swimmerId,
        rep_index: repIndex,
        rep_time_ms: repTimeMs,
        standard_ms: standardMs,
        base_rest_sec: baseRestSec,
        extended_rest_sec: extendedRestSec,
        delta_sec: deltaSec,
        strike_count: strikeCount,
        standard_source: "rep1",
        reverted: false,
        created_at: createdAt
    )
}

/// Mint a revert `RestEventRecord` (the engine learned the coach
/// disagreed). Same shape as a strike row but `reverted = true`.
func mkRevert(
    setIdx: Int,
    repIndex: Int,
    deltaSec: Int = 30,
    extendedRestSec: Int = 210,
    workoutSetId: String? = nil,
    sessionId: String? = nil,
    createdAt: String = "2025-08-11T12:00:00Z",
    swimmerId: String = "sw-A"
) -> RestEventRecord {
    return RestEventRecord(
        id: "id-r-\(setIdx)-\(repIndex)",
        session_id: sessionId,
        workout_set_id: workoutSetId ?? "ws-\(setIdx)",
        swimmer_id: swimmerId,
        rep_index: repIndex,
        rep_time_ms: 60700,
        standard_ms: 60000,
        base_rest_sec: 180,
        extended_rest_sec: extendedRestSec,
        delta_sec: deltaSec,
        strike_count: 1,
        standard_source: "rep1",
        reverted: true,
        created_at: createdAt
    )
}

// MARK: - Test 1: empty events → zeroed signature

func runEmptySignature() -> Bool {
    print("\n=== TEST 1: empty events → zeroed signature ===")
    let sig = RecoveryAggregator.signature(events: [])
    var ok = true
    ok = rsNilEq("empty: medianRepBeforeDrop == nil", sig.medianRepBeforeDrop, nil) && ok
    ok = rsEq("empty: totalStrikes == 0", sig.totalStrikes, 0) && ok
    ok = rsClose("empty: revertRate == 0", sig.revertRate, 0.0, 1e-9) && ok
    ok = rsClose("empty: avgDeltaSec == 0", sig.avgDeltaSec, 0.0, 1e-9) && ok
    ok = rsClose("empty: avgExtendedRestSec == 0", sig.avgExtendedRestSec, 0.0, 1e-9) && ok
    print("  -> TEST 1: \(ok ? "PASS" : "FAIL")")
    return ok
}

// MARK: - Test 2: known fixture → correct median

func runMedianKnownFixture() -> Bool {
    print("\n=== TEST 2a: median {3,4,5} == 4 ===")
    let events = [
        mkStrike(setIdx: 1, repIndex: 3),
        mkStrike(setIdx: 2, repIndex: 4),
        mkStrike(setIdx: 3, repIndex: 5),
    ]
    let sig = RecoveryAggregator.signature(events: events)
    let ok = rsEq("median {3,4,5} == 4", sig.medianRepBeforeDrop, 4)
    print("  -> TEST 2a: \(ok ? "PASS" : "FAIL")")
    return ok
}

func runMedianAllSame() -> Bool {
    print("\n=== TEST 2b: median {3,3,3} == 3 ===")
    let events = [
        mkStrike(setIdx: 1, repIndex: 3),
        mkStrike(setIdx: 2, repIndex: 3),
        mkStrike(setIdx: 3, repIndex: 3),
    ]
    let sig = RecoveryAggregator.signature(events: events)
    let ok = rsEq("median {3,3,3} == 3", sig.medianRepBeforeDrop, 3)
    print("  -> TEST 2b: \(ok ? "PASS" : "FAIL")")
    return ok
}

// MARK: - Test 3: only the FIRST strike per set counts

/// Within one set (same `workout_set_id`), rep 3 and rep 4 both
/// strike — only rep 3 should count (first strike = where the
/// swimmer started to drop, rep 4 is escalation). Median of a
/// single value {3} is 3.
func runOnlyFirstStrikeCounts() -> Bool {
    print("\n=== TEST 3: only first strike per set counts ===")
    let events = [
        mkStrike(setIdx: 1, repIndex: 3, workoutSetId: "ws-A"),
        mkStrike(setIdx: 1, repIndex: 4, workoutSetId: "ws-A"),
    ]
    let sig = RecoveryAggregator.signature(events: events)
    let ok = rsEq("first-strike-only {3} == 3", sig.medianRepBeforeDrop, 3)
    print("  -> TEST 3: \(ok ? "PASS" : "FAIL")")
    return ok
}

// MARK: - Test 4: avgDeltaSec + avgExtendedRestSec

/// Four strikes: delta_sec 30, 60, 30, 60 → avg = 45.0
/// Four strikes: extended_rest_sec 210, 240, 210, 240 → avg = 225.0
func runAverages() -> Bool {
    print("\n=== TEST 4: avgDeltaSec + avgExtendedRestSec ===")
    let events = [
        mkStrike(setIdx: 1, repIndex: 3, deltaSec: 30, extendedRestSec: 210),
        mkStrike(setIdx: 2, repIndex: 4, deltaSec: 60, extendedRestSec: 240),
        mkStrike(setIdx: 3, repIndex: 5, deltaSec: 30, extendedRestSec: 210),
        mkStrike(setIdx: 4, repIndex: 6, deltaSec: 60, extendedRestSec: 240),
    ]
    let sig = RecoveryAggregator.signature(events: events)
    var ok = true
    ok = rsClose("avgDeltaSec == 45.0", sig.avgDeltaSec, 45.0, 1e-9) && ok
    ok = rsClose("avgExtendedRestSec == 225.0", sig.avgExtendedRestSec, 225.0, 1e-9) && ok
    print("  -> TEST 4: \(ok ? "PASS" : "FAIL")")
    return ok
}

// MARK: - Test 5: revertRate fixtures

/// Fixture matrix:
///   - 4 reverted + 10 strike → 4/14 ≈ 0.2857 (tol 0.001)
///   - 4 reverted + 6 strike → 0.4 (tol 0.001)
///   - 0 reverted + 5 strike → 0
///   - only reverted (3 rows) → 1.0
func runRevertRateFixtures() -> Bool {
    print("\n=== TEST 5: revertRate fixtures ===")
    var ok = true

    // 4 reverted + 10 strike
    var events: [RestEventRecord] = []
    for i in 1...10 { events.append(mkStrike(setIdx: i, repIndex: 3)) }
    for i in 1...4 { events.append(mkRevert(setIdx: i, repIndex: 3)) }
    let rate1 = RecoveryAggregator.revertRate(events: events)
    ok = rsClose("4 reverted + 10 strike → 4/14 ≈ 0.2857", rate1, 4.0 / 14.0, 1e-3) && ok
    // And: signature(...).revertRate matches
    let sig1 = RecoveryAggregator.signature(events: events)
    ok = rsClose("signature(...).revertRate matches revertRate(...)", sig1.revertRate, rate1, 1e-9) && ok

    // 4 reverted + 6 strike
    events = []
    for i in 1...6 { events.append(mkStrike(setIdx: i, repIndex: 3)) }
    for i in 1...4 { events.append(mkRevert(setIdx: i, repIndex: 3)) }
    ok = rsClose("4 reverted + 6 strike → 0.4", RecoveryAggregator.revertRate(events: events), 0.4, 1e-3) && ok

    // 0 reverted + 5 strike
    events = []
    for i in 1...5 { events.append(mkStrike(setIdx: i, repIndex: 3)) }
    ok = rsClose("0 reverted → 0", RecoveryAggregator.revertRate(events: events), 0.0, 1e-9) && ok

    // only reverted
    events = []
    for i in 1...3 { events.append(mkRevert(setIdx: i, repIndex: 3)) }
    ok = rsClose("only reverted → 1.0", RecoveryAggregator.revertRate(events: events), 1.0, 1e-9) && ok

    print("  -> TEST 5: \(ok ? "PASS" : "FAIL")")
    return ok
}

// MARK: - Test 6: weeklyTrend buckets by ISO week (Monday-start)

/// Strikes across two ISO weeks:
///   - Week of Aug 11, 2025 (Monday): 2 strikes in 1 set (rep 3, 4)
///   - Week of Aug 18, 2025 (Monday): 1 strike in 1 set (rep 5)
///
/// Expected:
///   - 2 WeeklyStrainPoints (one per week with data)
///   - Week of Aug 11: strikes = 2, reps = max(3,4) = 4,
///     strikesPer100Reps = 2 * 100 / 4 = 50.0
///   - Week of Aug 18: strikes = 1, reps = max(5) = 5,
///     strikesPer100Reps = 1 * 100 / 5 = 20.0
func runWeeklyTrendBucketsByIsoWeek() -> Bool {
    print("\n=== TEST 6: weeklyTrend buckets by ISO week (Monday-start) ===")
    let events = [
        mkStrike(setIdx: 1, repIndex: 3, workoutSetId: "ws-1", createdAt: "2025-08-11T12:00:00Z"),
        mkStrike(setIdx: 1, repIndex: 4, workoutSetId: "ws-1", createdAt: "2025-08-13T12:00:00Z"),
        mkStrike(setIdx: 2, repIndex: 5, workoutSetId: "ws-2", createdAt: "2025-08-19T12:00:00Z"),
    ]
    let trend = RecoveryAggregator.weeklyTrend(events: events, weeks: 8)
    var ok = rsEq("trend count == 2", trend.count, 2)
    let week1 = trend.first { $0.weekStartISO == "2025-08-11T00:00:00Z" }
    let week2 = trend.first { $0.weekStartISO == "2025-08-18T00:00:00Z" }
    ok = rsEq("week 1 present", week1 != nil, true) && ok
    ok = rsEq("week 2 present", week2 != nil, true) && ok
    if let w1 = week1 {
        ok = rsEq("week1 strikes == 2", w1.strikes, 2) && ok
        ok = rsEq("week1 reps == 4", w1.reps, 4) && ok
        ok = rsClose("week1 strikesPer100Reps == 50.0", w1.strikesPer100Reps, 50.0, 1e-9) && ok
    }
    if let w2 = week2 {
        ok = rsEq("week2 strikes == 1", w2.strikes, 1) && ok
        ok = rsEq("week2 reps == 5", w2.reps, 5) && ok
        ok = rsClose("week2 strikesPer100Reps == 20.0", w2.strikesPer100Reps, 20.0, 1e-9) && ok
    }
    // Reversed-event ordering must still produce the same buckets.
    let trendRev = RecoveryAggregator.weeklyTrend(events: events.reversed(), weeks: 8)
    ok = rsEq("trend (reversed) count == 2", trendRev.count, 2) && ok
    if trend.count == 2 && trendRev.count == 2 {
        ok = rsEq("week1 strikes (reversed) == 2", trendRev[0].strikes, 2) && ok
    }
    print("  -> TEST 6: \(ok ? "PASS" : "FAIL")")
    return ok
}

// MARK: - Test 7: coachSignatureLine

/// median == nil → nil (data absent → the view hides the section).
/// median == 3 → committed coach string. We commit to the reduced
/// form `"Drops on rep 3 of hard sets."` — see the // why comment in
/// `RecoveryAggregator.coachSignatureLine(_:)`.
func runCoachSignatureLine() -> Bool {
    print("\n=== TEST 7: coachSignatureLine ===")
    let emptySig = RecoverySignature(
        medianRepBeforeDrop: nil,
        totalStrikes: 0,
        avgDeltaSec: 0,
        avgExtendedRestSec: 0,
        revertRate: 0
    )
    let sig3 = RecoverySignature(
        medianRepBeforeDrop: 3,
        totalStrikes: 5,
        avgDeltaSec: 45.0,
        avgExtendedRestSec: 225.0,
        revertRate: 0.1
    )
    let committed = "Drops on rep 3 of hard sets."
    var ok = rsNilEq("nil median → nil line", RecoveryAggregator.coachSignatureLine(emptySig), nil)
    ok = rsEq("median 3 → committed line", RecoveryAggregator.coachSignatureLine(sig3), committed) && ok
    print("  -> TEST 7: \(ok ? "PASS" : "FAIL")")
    return ok
}

// MARK: - Test 8: coachRevertFlag

/// rate > 0.30 → flag with exact spec copy (em-dash, period).
/// rate == 0.30 → nil (strict >; the threshold is a hard gate).
/// rate 0.29 → nil.
func runCoachRevertFlag() -> Bool {
    print("\n=== TEST 8: coachRevertFlag ===")
    let expected = "Ariana's extensions are usually wrong — check the standard."
    var ok = true
    ok = rsEq("rate 0.4 + Ariana → exact copy", RecoveryAggregator.coachRevertFlag(0.4, firstName: "Ariana"), expected) && ok
    ok = rsNilEq("rate 0.29 → nil", RecoveryAggregator.coachRevertFlag(0.29, firstName: "Ariana"), nil) && ok
    ok = rsNilEq("rate exactly 0.30 → nil (strict)", RecoveryAggregator.coachRevertFlag(0.30, firstName: "Ariana"), nil) && ok
    ok = rsNilEq("rate 0.0 → nil", RecoveryAggregator.coachRevertFlag(0.0, firstName: "Ariana"), nil) && ok
    let jackExpected = "Jack's extensions are usually wrong — check the standard."
    ok = rsEq("rate 0.5 + Jack → firstName substitution", RecoveryAggregator.coachRevertFlag(0.5, firstName: "Jack"), jackExpected) && ok
    print("  -> TEST 8: \(ok ? "PASS" : "FAIL")")
    return ok
}

// MARK: - Test 9: rep-count approximation

/// One set with strikes at rep_index {3, 6} → reps = 6 (max rep).
/// Two such sets in the same week → weekly reps = 6 + 6 = 12.
/// 3 strikes total in that week → strikesPer100Reps = 3 * 100 / 12
/// = 25.0.
func runRepCountApproximation() -> Bool {
    print("\n=== TEST 9: rep-count approximation (max rep_index per set) ===")
    let events = [
        mkStrike(setIdx: 1, repIndex: 3, workoutSetId: "ws-A", createdAt: "2025-08-11T12:00:00Z"),
        mkStrike(setIdx: 1, repIndex: 6, workoutSetId: "ws-A", createdAt: "2025-08-12T12:00:00Z"),
        mkStrike(setIdx: 2, repIndex: 4, workoutSetId: "ws-B", createdAt: "2025-08-13T12:00:00Z"),
        mkStrike(setIdx: 2, repIndex: 6, workoutSetId: "ws-B", createdAt: "2025-08-14T12:00:00Z"),
        mkStrike(setIdx: 3, repIndex: 6, workoutSetId: "ws-C", createdAt: "2025-08-15T12:00:00Z"),
    ]
    let trend = RecoveryAggregator.weeklyTrend(events: events, weeks: 8)
    var ok = rsEq("trend count == 1", trend.count, 1)
    if let week = trend.first {
        ok = rsEq("week strikes == 5", week.strikes, 5) && ok
        ok = rsEq("week reps == 6 + 6 + 6 = 18 (max per set)", week.reps, 18) && ok
        ok = rsClose("week strikesPer100Reps == 5*100/18 ≈ 27.7778", week.strikesPer100Reps, 5.0 * 100.0 / 18.0, 1e-6) && ok
    }
    print("  -> TEST 9: \(ok ? "PASS" : "FAIL")")
    return ok
}

// MARK: - Main

@main
struct RecoverySignatureCLITest {
    static func main() {
        print("=== RecoverySignatureCLI Test — V0.42 Slice 1 ===")
        print("=== Pure-logic gate for the recovery-signature aggregator. ===")
        print("=== Exercises real RecoveryAggregator + RestEventRecord. ===")
        print("")

        let t1 = runEmptySignature()
        let t2a = runMedianKnownFixture()
        let t2b = runMedianAllSame()
        let t3 = runOnlyFirstStrikeCounts()
        let t4 = runAverages()
        let t5 = runRevertRateFixtures()
        let t6 = runWeeklyTrendBucketsByIsoWeek()
        let t7 = runCoachSignatureLine()
        let t8 = runCoachRevertFlag()
        let t9 = runRepCountApproximation()

        let results: [(String, Bool)] = [
            ("TEST 1 empty → zeroed signature",           t1),
            ("TEST 2a median {3,4,5} == 4",                t2a),
            ("TEST 2b median {3,3,3} == 3",                t2b),
            ("TEST 3 only first strike per set counts",    t3),
            ("TEST 4 avgDelta + avgExtendedRest",          t4),
            ("TEST 5 revertRate fixtures",                 t5),
            ("TEST 6 weeklyTrend ISO-week bucketing",      t6),
            ("TEST 7 coachSignatureLine copy",             t7),
            ("TEST 8 coachRevertFlag copy + threshold",    t8),
            ("TEST 9 rep-count approximation",             t9),
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