// RestCountdownCLITest — V0.39 Slice 2 — pure-logic CLI test for the
// drop-rule state machine. Exercises the production
// `RestCountdownModel` against synthetic rep completions so the strike
// math, maturity gate, intensity gate, threshold scaling, escalation
// caps, strike reset, revert, tick, and multi-swimmer common-clock
// behavior can all be regression-gated on the orchestrator Mac
// without a booted simulator or UIKit.
//
// What it covers (spec §Slice 2 Acceptance — see V0.39_SPEC.md):
//   1. strike on 50m rep > standard + 0.5s (→ +30s, strikeCount=1)
//   2. no strike within threshold (struck=false, delta=0)
//   3. second strike escalates +60s (capped at 2)
//   4. strike reset on good rep (subsequent strike is +30 again)
//   5. immature prediction → rep1 fallback; reliable+predicted → predicted
//   6. aerobic set → no evaluation (returns nil)
//   7. revert restores base rest + clears strikes + clears extension
//   8. tick decrements remainingSec by 1 with floor at 0
//   9. 25m threshold is 0.25s (linear scaling)
//  10. linear scaling for odd distance (100m → 1.0s threshold)
//  11. multi-swimmer common clock + per-swimmer flags
//
// Usage: RestCountdownCLITest
// Compiled by build_and_run_restcountdown.sh.

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

// MARK: - Test 1: strike on 50m rep > standard + 0.5s

/// Standard is rep1 = 60.0s = 60000ms; a rep of 60.7s (60700ms)
/// exceeds 60000 + 500 (threshold for 50m) → strike. Strike 1 gives
/// +30s; the common extended rest becomes base + 30.
func runStrikeOn50mOver0_5s() -> Bool {
    print("\n=== TEST 1: strike on 50m rep > standard + 0.5s ===")
    let baseRest = 180  // 3:00 base rest
    let m = RestCountdownModel(baseRestSec: baseRest, setIsAnaerobic: true)
    let swimmerId = "sw-A"

    let eval = m.evaluate(
        swimmerId: swimmerId,
        repIndex: 2,
        repTimeMs: 60700,    // 60.7s
        distanceMeters: 50,
        predictedStandardMs: nil,            // forces rep1 fallback path
        predictionMaturity: nil,
        rep1TimeMs: 60000                    // 60.0s
    )

    var allPass = true
    allPass = assertTrue("evaluate returned non-nil", eval != nil) && allPass
    guard let e = eval else { return false }
    allPass = assertEq("struck == true", e.struck, true) && allPass
    allPass = assertEq("deltaSec == 30 (first strike)", e.deltaSec, 30) && allPass
    allPass = assertEq("strikeCount == 1", e.strikeCount, 1) && allPass
    allPass = assertEq("extendedRestSec == base + 30", e.extendedRestSec, baseRest + 30) && allPass
    allPass = assertEq("standardMs == 60000 (rep1 fallback)", e.standardMs, 60000) && allPass
    allPass = assertEq("standardSource == .rep1", e.standardSource, .rep1) && allPass
    allPass = assertEq("baseRestSec round-trip", e.baseRestSec, baseRest) && allPass
    allPass = assertEq("repIndex round-trip", e.repIndex, 2) && allPass
    allPass = assertEq("repTimeMs round-trip", e.repTimeMs, 60700) && allPass
    allPass = assertEq("swimmerId round-trip", e.swimmerId, swimmerId) && allPass
    allPass = assertEq("currentExtensionSec[A] == 30", m.currentExtensionSec[swimmerId] ?? -1, 30) && allPass
    allPass = assertEq("strikes[A] == 1", m.strikes[swimmerId] ?? -1, 1) && allPass
    allPass = assertEq("extendedRestSec after eval == base + 30", m.extendedRestSec, baseRest + 30) && allPass

    print("  -> TEST 1: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - Test 2: no strike within threshold

/// rep of 60.4s (60400ms) does NOT strike (60.4 ≤ 60.0+0.5).
/// Delta should be 0, struck=false, extendedRestSec stays at base.
func runNoStrikeWithinThreshold() -> Bool {
    print("\n=== TEST 2: no strike within threshold ===")
    let baseRest = 180
    let m = RestCountdownModel(baseRestSec: baseRest, setIsAnaerobic: true)
    let swimmerId = "sw-A"

    let eval = m.evaluate(
        swimmerId: swimmerId,
        repIndex: 1,
        repTimeMs: 60400,    // 60.4s
        distanceMeters: 50,
        predictedStandardMs: nil,
        predictionMaturity: nil,
        rep1TimeMs: 60000
    )

    var allPass = true
    allPass = assertTrue("evaluate returned non-nil", eval != nil) && allPass
    guard let e = eval else { return false }
    allPass = assertEq("struck == false", e.struck, false) && allPass
    allPass = assertEq("deltaSec == 0", e.deltaSec, 0) && allPass
    allPass = assertEq("strikeCount == 0", e.strikeCount, 0) && allPass
    allPass = assertEq("extendedRestSec == base", e.extendedRestSec, baseRest) && allPass
    allPass = assertEq("currentExtensionSec[A] == 0 (no extension)", m.currentExtensionSec[swimmerId] ?? -1, 0) && allPass
    allPass = assertEq("extendedRestSec after eval == base", m.extendedRestSec, baseRest) && allPass

    print("  -> TEST 2: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - Test 3: second strike escalates +60s

/// Two consecutive strikes → second has strikeCount=2, delta=60,
/// extendedRestSec = base + 60 (NOT base + 30 + 60; the per-swimmer
/// extension replaces, not stacks — Eva's "if he hits two strikes,
/// then we extend by a minute").
func runSecondStrikeEscalates() -> Bool {
    print("\n=== TEST 3: second strike escalates +60s ===")
    let baseRest = 180
    let m = RestCountdownModel(baseRestSec: baseRest, setIsAnaerobic: true)
    let swimmerId = "sw-A"

    let e1 = m.evaluate(
        swimmerId: swimmerId, repIndex: 1, repTimeMs: 60700,
        distanceMeters: 50,
        predictedStandardMs: nil, predictionMaturity: nil, rep1TimeMs: 60000
    )
    let e2 = m.evaluate(
        swimmerId: swimmerId, repIndex: 2, repTimeMs: 61500,
        distanceMeters: 50,
        predictedStandardMs: nil, predictionMaturity: nil, rep1TimeMs: 60000
    )

    var allPass = true
    allPass = assertTrue("first evaluate non-nil", e1 != nil) && allPass
    allPass = assertTrue("second evaluate non-nil", e2 != nil) && allPass
    guard let e2 = e2 else { return false }
    allPass = assertEq("second strike: struck=true", e2.struck, true) && allPass
    allPass = assertEq("second strike: strikeCount == 2", e2.strikeCount, 2) && allPass
    allPass = assertEq("second strike: deltaSec == 60", e2.deltaSec, 60) && allPass
    allPass = assertEq("second strike: extendedRestSec == base + 60 (replaces, not stacks)",
                       e2.extendedRestSec, baseRest + 60) && allPass
    allPass = assertEq("currentExtensionSec[A] == 60 after second strike",
                       m.currentExtensionSec[swimmerId] ?? -1, 60) && allPass
    allPass = assertEq("strikes[A] == 2", m.strikes[swimmerId] ?? -1, 2) && allPass

    print("  -> TEST 3: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - Test 4: strike reset on good rep

/// After a strike (+30), a good rep (≤ standard+threshold) clears
/// strikes AND extension; the next strike is again strikeCount=1,
/// deltaSec=30. Eva: "he's allowed two strikes again".
func runStrikeResetOnGoodRep() -> Bool {
    print("\n=== TEST 4: strike reset on good rep ===")
    let baseRest = 180
    let m = RestCountdownModel(baseRestSec: baseRest, setIsAnaerobic: true)
    let swimmerId = "sw-A"

    let _ = m.evaluate(
        swimmerId: swimmerId, repIndex: 1, repTimeMs: 60700,
        distanceMeters: 50,
        predictedStandardMs: nil, predictionMaturity: nil, rep1TimeMs: 60000
    )
    // After strike 1: extension=30, strikes=1, extendedRestSec=base+30
    let mid = m.evaluate(
        swimmerId: swimmerId, repIndex: 2, repTimeMs: 60050,  // 60.05s, within threshold
        distanceMeters: 50,
        predictedStandardMs: nil, predictionMaturity: nil, rep1TimeMs: 60000
    )
    // After reset: strikes=0, extension=0, extendedRestSec=base

    var allPass = true
    allPass = assertTrue("good-rep evaluate non-nil", mid != nil) && allPass
    guard let mid = mid else { return false }
    allPass = assertEq("good rep: struck=false", mid.struck, false) && allPass
    allPass = assertEq("good rep: deltaSec == 0", mid.deltaSec, 0) && allPass
    allPass = assertEq("good rep: strikeCount == 0 (reset)", mid.strikeCount, 0) && allPass
    allPass = assertEq("good rep: extendedRestSec back to base",
                       mid.extendedRestSec, baseRest) && allPass
    allPass = assertEq("currentExtensionSec[A] back to 0 after good rep",
                       m.currentExtensionSec[swimmerId] ?? -1, 0) && allPass
    allPass = assertEq("strikes[A] back to 0 after good rep",
                       m.strikes[swimmerId] ?? -1, 0) && allPass

    // Third rep: another strike. Should be strikeCount=1 (because
    // strikes was reset to 0), deltaSec=30.
    let e3 = m.evaluate(
        swimmerId: swimmerId, repIndex: 3, repTimeMs: 60800,
        distanceMeters: 50,
        predictedStandardMs: nil, predictionMaturity: nil, rep1TimeMs: 60000
    )
    allPass = assertTrue("third strike evaluate non-nil", e3 != nil) && allPass
    guard let e3 = e3 else { return false }
    allPass = assertEq("third strike: struck=true", e3.struck, true) && allPass
    allPass = assertEq("third strike: strikeCount == 1 (reset worked)",
                       e3.strikeCount, 1) && allPass
    allPass = assertEq("third strike: deltaSec == 30", e3.deltaSec, 30) && allPass
    allPass = assertEq("third strike: extendedRestSec == base + 30",
                       e3.extendedRestSec, baseRest + 30) && allPass

    print("  -> TEST 4: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - Test 5: immature prediction falls back to rep 1; reliable + predicted → predicted

/// Two cases:
///   a) predictionMaturity = .learning (5 samples) → standard = rep1,
///      standardSource = .rep1 (even though predictedStandardMs is
///      passed in, it's rejected because maturity < .reliable)
///   b) predictionMaturity = .reliable (10 samples) + a predicted
///      standard → standard = predictedStandardMs, standardSource =
///      .predicted
func runMaturityGate() -> Bool {
    print("\n=== TEST 5: maturity gate (predicted vs rep1) ===")
    let baseRest = 180
    let m = RestCountdownModel(baseRestSec: baseRest, setIsAnaerobic: true)
    let swimmerId = "sw-A"
    let predictedMs = 58500  // 58.5s predicted (faster than rep1)
    let rep1Ms = 60000       // 60.0s

    // (a) .learning — predicted should be rejected
    let a = m.evaluate(
        swimmerId: swimmerId, repIndex: 1, repTimeMs: 60000,
        distanceMeters: 50,
        predictedStandardMs: predictedMs,
        predictionMaturity: .learning,
        rep1TimeMs: rep1Ms
    )

    // (b) .reliable — predicted should win
    let b = m.evaluate(
        swimmerId: swimmerId, repIndex: 2, repTimeMs: 60000,
        distanceMeters: 50,
        predictedStandardMs: predictedMs,
        predictionMaturity: .reliable,
        rep1TimeMs: rep1Ms
    )

    var allPass = true
    allPass = assertTrue("learning case non-nil", a != nil) && allPass
    guard let a = a else { return false }
    allPass = assertEq("learning → standard = rep1", a.standardMs, rep1Ms) && allPass
    allPass = assertEq("learning → standardSource = .rep1", a.standardSource, .rep1) && allPass

    allPass = assertTrue("reliable case non-nil", b != nil) && allPass
    guard let b = b else { return false }
    allPass = assertEq("reliable → standard = predicted", b.standardMs, predictedMs) && allPass
    allPass = assertEq("reliable → standardSource = .predicted", b.standardSource, .predicted) && allPass

    // (c) .reliable but predictedStandardMs is nil → fall back to rep1
    let m2 = RestCountdownModel(baseRestSec: baseRest, setIsAnaerobic: true)
    let c = m2.evaluate(
        swimmerId: swimmerId, repIndex: 1, repTimeMs: 60000,
        distanceMeters: 50,
        predictedStandardMs: nil,
        predictionMaturity: .reliable,
        rep1TimeMs: rep1Ms
    )
    allPass = assertTrue("reliable+nil-predicted non-nil", c != nil) && allPass
    guard let c = c else { return false }
    allPass = assertEq("reliable+nil-predicted → standard = rep1", c.standardMs, rep1Ms) && allPass
    allPass = assertEq("reliable+nil-predicted → standardSource = .rep1", c.standardSource, .rep1) && allPass

    // (d) .excellent — also wins (≥ reliable)
    let m3 = RestCountdownModel(baseRestSec: baseRest, setIsAnaerobic: true)
    let d = m3.evaluate(
        swimmerId: swimmerId, repIndex: 1, repTimeMs: 60000,
        distanceMeters: 50,
        predictedStandardMs: predictedMs,
        predictionMaturity: .excellent,
        rep1TimeMs: rep1Ms
    )
    allPass = assertTrue("excellent case non-nil", d != nil) && allPass
    guard let d = d else { return false }
    allPass = assertEq("excellent → standard = predicted", d.standardMs, predictedMs) && allPass
    allPass = assertEq("excellent → standardSource = .predicted", d.standardSource, .predicted) && allPass

    // (e) .none — fall back to rep1
    let m4 = RestCountdownModel(baseRestSec: baseRest, setIsAnaerobic: true)
    let e = m4.evaluate(
        swimmerId: swimmerId, repIndex: 1, repTimeMs: 60000,
        distanceMeters: 50,
        predictedStandardMs: predictedMs,
        predictionMaturity: Prediction.Maturity.none,
        rep1TimeMs: rep1Ms
    )
    allPass = assertTrue("none case non-nil", e != nil) && allPass
    guard let e = e else { return false }
    allPass = assertEq("none → standard = rep1", e.standardMs, rep1Ms) && allPass
    allPass = assertEq("none → standardSource = .rep1", e.standardSource, .rep1) && allPass

    print("  -> TEST 5: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - Test 6: aerobic set → no evaluation

/// setIsAnaerobic: false → evaluate returns nil. No state mutation.
func runAerobicGate() -> Bool {
    print("\n=== TEST 6: aerobic set → no evaluation ===")
    let m = RestCountdownModel(baseRestSec: 180, setIsAnaerobic: false)
    let swimmerId = "sw-A"

    let eval = m.evaluate(
        swimmerId: swimmerId, repIndex: 1, repTimeMs: 100000,  // huge, doesn't matter
        distanceMeters: 50,
        predictedStandardMs: nil, predictionMaturity: nil, rep1TimeMs: 60000
    )

    var allPass = true
    allPass = assertEq("aerobic set → evaluate returns nil", eval, nil) && allPass
    allPass = assertEq("aerobic set: strikes untouched", m.strikes[swimmerId] ?? 0, 0) && allPass
    allPass = assertEq("aerobic set: extension untouched", m.currentExtensionSec[swimmerId] ?? -1, -1) && allPass
    allPass = assertEq("aerobic set: extendedRestSec == base (unchanged)", m.extendedRestSec, 180) && allPass

    print("  -> TEST 6: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - Test 7: revert restores base rest

/// After a strike (extension=30), revert(A) → extension back to 0,
/// strikes back to 0, extendedRestSec recomputed (base + max of
/// remaining extensions = base since no other swimmers struck).
func runRevertRestoresBase() -> Bool {
    print("\n=== TEST 7: revert restores base rest ===")
    let baseRest = 180
    let m = RestCountdownModel(baseRestSec: baseRest, setIsAnaerobic: true)
    let swimmerId = "sw-A"

    let _ = m.evaluate(
        swimmerId: swimmerId, repIndex: 1, repTimeMs: 60700,
        distanceMeters: 50,
        predictedStandardMs: nil, predictionMaturity: nil, rep1TimeMs: 60000
    )
    // Sanity: extension = 30, extendedRestSec = base + 30
    let result = m.revert(swimmerId: swimmerId)

    var allPass = true
    allPass = assertEq("revert.swimmerId round-trip", result.swimmerId, swimmerId) && allPass
    allPass = assertEq("revert.reverted == true", result.reverted, true) && allPass
    allPass = assertEq("revert.newExtendedRestSec == base", result.newExtendedRestSec, baseRest) && allPass
    allPass = assertEq("currentExtensionSec[A] == 0 after revert", m.currentExtensionSec[swimmerId] ?? -1, 0) && allPass
    allPass = assertEq("strikes[A] == 0 after revert", m.strikes[swimmerId] ?? -1, 0) && allPass
    allPass = assertEq("extendedRestSec == base after revert", m.extendedRestSec, baseRest) && allPass

    print("  -> TEST 7: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - Test 8: tick decrements + floor 0

/// Three ticks from baseRestSec=2 → remainingSec goes 1, 0, 0 (floor).
func runTickFloor() -> Bool {
    print("\n=== TEST 8: tick decrements + floor 0 ===")
    let m = RestCountdownModel(baseRestSec: 2, setIsAnaerobic: true)

    var allPass = true
    allPass = assertEq("initial remainingSec == 2", m.remainingSec, 2) && allPass
    m.tick()
    allPass = assertEq("after tick 1: remainingSec == 1", m.remainingSec, 1) && allPass
    m.tick()
    allPass = assertEq("after tick 2: remainingSec == 0", m.remainingSec, 0) && allPass
    m.tick()
    allPass = assertEq("after tick 3: remainingSec == 0 (floor)", m.remainingSec, 0) && allPass

    // Also: tick should not mutate extendedRestSec or per-swimmer state.
    allPass = assertEq("tick leaves extendedRestSec alone", m.extendedRestSec, 2) && allPass

    print("  -> TEST 8: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - Test 9: 25m threshold is 0.25s

/// 25m threshold is 250ms. A rep 0.3s over standard strikes; 0.2s
/// over does not.
func run25mThreshold() -> Bool {
    print("\n=== TEST 9: 25m threshold is 0.25s ===")
    let m = RestCountdownModel(baseRestSec: 60, setIsAnaerobic: true)
    let swimmerId = "sw-A"
    let standard = 28000  // 28.0s

    // 28.3s = 28300ms → +300ms > 250ms threshold → strike
    let e1 = m.evaluate(
        swimmerId: swimmerId, repIndex: 1, repTimeMs: 28300,
        distanceMeters: 25,
        predictedStandardMs: nil, predictionMaturity: nil, rep1TimeMs: standard
    )
    // 28.2s = 28200ms → +200ms ≤ 250ms threshold → no strike
    let e2 = m.evaluate(
        swimmerId: swimmerId, repIndex: 2, repTimeMs: 28200,
        distanceMeters: 25,
        predictedStandardMs: nil, predictionMaturity: nil, rep1TimeMs: standard
    )

    var allPass = true
    allPass = assertTrue("strike case non-nil", e1 != nil) && allPass
    guard let e1 = e1 else { return false }
    allPass = assertEq("0.3s over 25m → struck", e1.struck, true) && allPass
    allPass = assertEq("0.3s over 25m → standard = 28000", e1.standardMs, standard) && allPass

    allPass = assertTrue("no-strike case non-nil", e2 != nil) && allPass
    guard let e2 = e2 else { return false }
    allPass = assertEq("0.2s over 25m → not struck", e2.struck, false) && allPass

    print("  -> TEST 9: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - Test 10: linear scaling for odd distance (100m)

/// 100m threshold = 1000ms (10ms/m × 100m). A rep 1.01s over
/// standard strikes (61010 > 60000 + 1000); a rep 0.9s over
/// does not (60900 ≤ 60000 + 1000). At exactly 1.0s over
/// (61000ms), the spec's strict `>` means no strike (the boundary
/// is inclusive of "within threshold").
func runLinearScaling100m() -> Bool {
    print("\n=== TEST 10: linear scaling for odd distance (100m) ===")
    let m = RestCountdownModel(baseRestSec: 120, setIsAnaerobic: true)
    let swimmerId = "sw-A"
    let standard = 60000  // 60.0s

    // 61.01s = 61010ms → +1010ms > 1000ms threshold → strike
    let e1 = m.evaluate(
        swimmerId: swimmerId, repIndex: 1, repTimeMs: 61010,
        distanceMeters: 100,
        predictedStandardMs: nil, predictionMaturity: nil, rep1TimeMs: standard
    )
    // 60.9s = 60900ms → +900ms < 1000ms threshold → no strike
    let e2 = m.evaluate(
        swimmerId: swimmerId, repIndex: 2, repTimeMs: 60900,
        distanceMeters: 100,
        predictedStandardMs: nil, predictionMaturity: nil, rep1TimeMs: standard
    )
    // Exactly at threshold: 61000ms → +1000ms == threshold →
    // spec's strict > means no strike
    let e3 = m.evaluate(
        swimmerId: swimmerId, repIndex: 3, repTimeMs: 61000,
        distanceMeters: 100,
        predictedStandardMs: nil, predictionMaturity: nil, rep1TimeMs: standard
    )

    var allPass = true
    allPass = assertTrue("100m strike case non-nil", e1 != nil) && allPass
    guard let e1 = e1 else { return false }
    allPass = assertEq("1.01s over 100m → struck", e1.struck, true) && allPass

    allPass = assertTrue("100m no-strike case non-nil", e2 != nil) && allPass
    guard let e2 = e2 else { return false }
    allPass = assertEq("0.9s over 100m → not struck", e2.struck, false) && allPass

    allPass = assertTrue("100m boundary case non-nil", e3 != nil) && allPass
    guard let e3 = e3 else { return false }
    allPass = assertEq("exactly 1.0s over 100m → not struck (boundary inclusive)",
                       e3.struck, false) && allPass

    print("  -> TEST 10: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - Test 11: multi-swimmer common clock + per-swimmer flags

/// Two swimmers in the same set. A strikes (+30), B holds (no
/// extension). Common clock = base + max(30, 0) = base + 30. Then A
/// strikes again (+60). Common clock = base + 60 (max of 60, 0).
func runMultiSwimmer() -> Bool {
    print("\n=== TEST 11: multi-swimmer common clock + per-swimmer flags ===")
    let baseRest = 180
    let m = RestCountdownModel(baseRestSec: baseRest, setIsAnaerobic: true)
    let ariana = "ariana"
    let jack = "jack"

    // Ariana: rep1 = 60.0s, rep2 = 60.7s (strike)
    let _ = m.evaluate(
        swimmerId: ariana, repIndex: 1, repTimeMs: 60000,
        distanceMeters: 50,
        predictedStandardMs: nil, predictionMaturity: nil, rep1TimeMs: 60000
    )
    let aStrike = m.evaluate(
        swimmerId: ariana, repIndex: 2, repTimeMs: 60700,
        distanceMeters: 50,
        predictedStandardMs: nil, predictionMaturity: nil, rep1TimeMs: 60000
    )
    // Jack: rep1 = 32.0s, rep2 = 32.1s (within his standard — he's holding)
    let _ = m.evaluate(
        swimmerId: jack, repIndex: 1, repTimeMs: 32000,
        distanceMeters: 50,
        predictedStandardMs: nil, predictionMaturity: nil, rep1TimeMs: 32000
    )
    let jackHold = m.evaluate(
        swimmerId: jack, repIndex: 2, repTimeMs: 32100,
        distanceMeters: 50,
        predictedStandardMs: nil, predictionMaturity: nil, rep1TimeMs: 32000
    )

    var allPass = true
    allPass = assertEq("currentExtensionSec[ariana] == 30", m.currentExtensionSec[ariana] ?? -1, 30) && allPass
    allPass = assertEq("currentExtensionSec[jack] == 0 (holding)", m.currentExtensionSec[jack] ?? -1, 0) && allPass
    allPass = assertEq("extendedRestSec == base + 30 (max of [30, 0])", m.extendedRestSec, baseRest + 30) && allPass

    // Then Ariana strikes again — escalation
    let aStrike2 = m.evaluate(
        swimmerId: ariana, repIndex: 3, repTimeMs: 61500,
        distanceMeters: 50,
        predictedStandardMs: nil, predictionMaturity: nil, rep1TimeMs: 60000
    )

    allPass = assertEq("Ariana strike 2: delta == 60", aStrike2?.deltaSec ?? -1, 60) && allPass
    allPass = assertEq("currentExtensionSec[ariana] == 60 after strike 2", m.currentExtensionSec[ariana] ?? -1, 60) && allPass
    allPass = assertEq("currentExtensionSec[jack] still 0", m.currentExtensionSec[jack] ?? -1, 0) && allPass
    allPass = assertEq("extendedRestSec == base + 60 (max of [60, 0])", m.extendedRestSec, baseRest + 60) && allPass

    // Sanity: aStrike.struck, jackHold.struck
    allPass = assertEq("Ariana strike 1: struck=true", aStrike?.struck ?? false, true) && allPass
    allPass = assertEq("Jack hold: struck=false", jackHold?.struck ?? false, false) && allPass

    // And: revert Ariana → common clock drops to base (Jack's
    // contribution is 0 anyway). After revert, A extension = 0 and
    // common clock = base.
    let revertResult = m.revert(swimmerId: ariana)
    allPass = assertEq("revert Ariana: newExtendedRestSec == base (Jack contributed 0)",
                       revertResult.newExtendedRestSec, baseRest) && allPass
    allPass = assertEq("after revert: extendedRestSec == base", m.extendedRestSec, baseRest) && allPass
    allPass = assertEq("after revert: Ariana extension == 0", m.currentExtensionSec[ariana] ?? -1, 0) && allPass
    allPass = assertEq("after revert: Jack extension still 0", m.currentExtensionSec[jack] ?? -1, 0) && allPass

    print("  -> TEST 11: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - Test 12: reset clears per-swimmer state and resets clock

/// reset() clears strikes/extensions and resets remainingSec to
/// baseRestSec. extendedRestSec also goes back to base.
func runResetClearsState() -> Bool {
    print("\n=== TEST 12: reset clears per-swimmer state ===")
    let m = RestCountdownModel(baseRestSec: 180, setIsAnaerobic: true)
    let _ = m.evaluate(
        swimmerId: "sw-A", repIndex: 1, repTimeMs: 60700,
        distanceMeters: 50,
        predictedStandardMs: nil, predictionMaturity: nil, rep1TimeMs: 60000
    )
    m.tick()
    m.tick()
    m.reset()

    var allPass = true
    allPass = assertEq("reset: remainingSec back to base", m.remainingSec, 180) && allPass
    allPass = assertEq("reset: extendedRestSec back to base", m.extendedRestSec, 180) && allPass
    allPass = assertEq("reset: strikes cleared (key removed)", m.strikes["sw-A"] ?? -1, -1) && allPass
    allPass = assertEq("reset: currentExtensionSec cleared", m.currentExtensionSec["sw-A"] ?? -1, -1) && allPass

    print("  -> TEST 12: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - V0.39 Slice 4 — event trail tests (2026-08-18)
//
// The model now accumulates a per-set trail of `RestEvent`s so the
// save path can persist one `set_rest_events` row per extension
// decision. The pure accumulation carries the test burden; the
// `TimingService` insert is thin and is verified by compile + the
// live-DB acceptance (spec §Slice 4 TDD).

// MARK: - Test 13: after a strike, restEvents has one .strike with correct fields

/// One strike → exactly one .strike event in the trail, with the
/// DropEvaluation's fields lifted into the event 1:1.
func runTrailAppendsOnStrike() -> Bool {
    print("\n=== TEST 13: trail appends on strike ===")
    let baseRest = 180
    let m = RestCountdownModel(baseRestSec: baseRest, setIsAnaerobic: true)
    let swimmerId = "sw-A"

    let _ = m.evaluate(
        swimmerId: swimmerId, repIndex: 2, repTimeMs: 60700,
        distanceMeters: 50,
        predictedStandardMs: nil, predictionMaturity: nil, rep1TimeMs: 60000
    )

    var allPass = true
    allPass = assertEq("trail length after one strike == 1", m.restEvents.count, 1) && allPass
    guard let event = m.restEvents.first else { return false }
    allPass = assertEq("event.eventType == .strike", event.eventType, RestEventType.strike) && allPass
    allPass = assertEq("event.reverted == false", event.reverted, false) && allPass
    allPass = assertEq("event.swimmerId round-trip", event.swimmerId, swimmerId) && allPass
    allPass = assertEq("event.repIndex round-trip", event.repIndex, 2) && allPass
    allPass = assertEq("event.repTimeMs round-trip", event.repTimeMs, 60700) && allPass
    allPass = assertEq("event.standardMs round-trip", event.standardMs, 60000) && allPass
    allPass = assertEq("event.standardSource == .rep1", event.standardSource, .rep1) && allPass
    allPass = assertEq("event.baseRestSec round-trip", event.baseRestSec, baseRest) && allPass
    allPass = assertEq("event.extendedRestSec == base + 30", event.extendedRestSec, baseRest + 30) && allPass
    allPass = assertEq("event.deltaSec == 30", event.deltaSec, 30) && allPass
    allPass = assertEq("event.strikeCount == 1", event.strikeCount, 1) && allPass

    print("  -> TEST 13: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - Test 14: a good (non-strike) rep does NOT append

/// The spec says "one per extension decision" — a non-strike is
/// NOT a decision. After one good rep, the trail is empty.
func runTrailNoAppendOnNonStrike() -> Bool {
    print("\n=== TEST 14: no append on non-strike rep ===")
    let baseRest = 180
    let m = RestCountdownModel(baseRestSec: baseRest, setIsAnaerobic: true)
    let swimmerId = "sw-A"

    let _ = m.evaluate(
        swimmerId: swimmerId, repIndex: 1, repTimeMs: 60050,  // within threshold
        distanceMeters: 50,
        predictedStandardMs: nil, predictionMaturity: nil, rep1TimeMs: 60000
    )

    var allPass = true
    allPass = assertEq("trail length after non-strike == 0", m.restEvents.count, 0) && allPass

    // And: a second non-strike → still empty.
    let _ = m.evaluate(
        swimmerId: swimmerId, repIndex: 2, repTimeMs: 60200,
        distanceMeters: 50,
        predictedStandardMs: nil, predictionMaturity: nil, rep1TimeMs: 60000
    )
    allPass = assertEq("trail length after two non-strikes == 0", m.restEvents.count, 0) && allPass

    print("  -> TEST 14: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - Test 15: revert appends .revert carrying the strike's fields

/// After one strike → revert → the trail has [strike, revert]; the
/// revert carries the strike's fields (repIndex, repTimeMs,
/// standardMs, etc.), with `reverted = true` and the strike's
/// `extendedRestSec` (pre-revert value).
func runTrailRevertCarriesStrikeFields() -> Bool {
    print("\n=== TEST 15: revert carries strike's fields ===")
    let baseRest = 180
    let m = RestCountdownModel(baseRestSec: baseRest, setIsAnaerobic: true)
    let swimmerId = "sw-A"

    let _ = m.evaluate(
        swimmerId: swimmerId, repIndex: 2, repTimeMs: 60700,
        distanceMeters: 50,
        predictedStandardMs: nil, predictionMaturity: nil, rep1TimeMs: 60000
    )
    let _ = m.revert(swimmerId: swimmerId)

    var allPass = true
    allPass = assertEq("trail length after strike + revert == 2", m.restEvents.count, 2) && allPass
    guard m.restEvents.count == 2 else { return false }
    let strike = m.restEvents[0]
    let revertEvent = m.restEvents[1]

    // Strike: unchanged from before.
    allPass = assertEq("strike.eventType == .strike", strike.eventType, RestEventType.strike) && allPass
    allPass = assertEq("strike.reverted == false", strike.reverted, false) && allPass

    // Revert: carries the strike's fields, but the eventType
    // tag flips and the reverted flag flips.
    allPass = assertEq("revert.eventType == .revert", revertEvent.eventType, RestEventType.revert) && allPass
    allPass = assertEq("revert.reverted == true", revertEvent.reverted, true) && allPass
    allPass = assertEq("revert.swimmerId == swimmer", revertEvent.swimmerId, swimmerId) && allPass
    allPass = assertEq("revert.repIndex == strike.repIndex", revertEvent.repIndex, strike.repIndex) && allPass
    allPass = assertEq("revert.repTimeMs == strike.repTimeMs", revertEvent.repTimeMs, strike.repTimeMs) && allPass
    allPass = assertEq("revert.standardMs == strike.standardMs", revertEvent.standardMs, strike.standardMs) && allPass
    allPass = assertEq("revert.standardSource == strike.standardSource", revertEvent.standardSource, strike.standardSource) && allPass
    allPass = assertEq("revert.baseRestSec == strike.baseRestSec", revertEvent.baseRestSec, strike.baseRestSec) && allPass
    // The key invariant: revert's extendedRestSec is the strike's
    // value (pre-revert = base + 30 = 210), NOT the model's now-base
    // value (180). The flywheel reads this column to learn what the
    // engine proposed, before the coach disagreed.
    allPass = assertEq("revert.extendedRestSec == strike.extendedRestSec (pre-revert)",
                       revertEvent.extendedRestSec, strike.extendedRestSec) && allPass
    allPass = assertEq("revert.extendedRestSec == base + 30 (210)", revertEvent.extendedRestSec, baseRest + 30) && allPass
    allPass = assertEq("revert.deltaSec == strike.deltaSec (30)", revertEvent.deltaSec, strike.deltaSec) && allPass
    allPass = assertEq("revert.strikeCount == strike.strikeCount (1)", revertEvent.strikeCount, strike.strikeCount) && allPass

    print("  -> TEST 15: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - Test 16: reset() clears the trail

/// After a strike (trail has 1 event), reset() drops the trail to
/// empty — so a retry / next set starts fresh and the same strike
/// isn't double-written.
func runTrailResetClears() -> Bool {
    print("\n=== TEST 16: reset clears event trail ===")
    let baseRest = 180
    let m = RestCountdownModel(baseRestSec: baseRest, setIsAnaerobic: true)
    let _ = m.evaluate(
        swimmerId: "sw-A", repIndex: 1, repTimeMs: 60700,
        distanceMeters: 50,
        predictedStandardMs: nil, predictionMaturity: nil, rep1TimeMs: 60000
    )
    let _ = m.revert(swimmerId: "sw-A")
    // Sanity: trail has 2 events
    var allPass = true
    allPass = assertEq("pre-reset trail length == 2", m.restEvents.count, 2) && allPass

    m.reset()
    allPass = assertEq("post-reset trail length == 0", m.restEvents.count, 0) && allPass

    print("  -> TEST 16: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - Test 17: RestEventRow encodes with the correct snake_case keys

/// The save path relies on the supabase-swift SDK writing the row
/// with `snake_case` keys. The struct fields ARE snake_case so
/// `JSONEncoder().encode(...)` produces the wire format directly;
/// the test round-trips through a JSON parse to assert the key set.
///
/// Two sub-cases: (a) all fields populated → the encoded JSON has
/// the full 14-key snake_case set; (b) optional fields nil → the
/// encoding still works and the nil keys are dropped (consistent
/// with `JSONEncoder` default behavior + the `LapRow` pattern in
/// `TimingService.saveSession(...)`).
func runRestEventRowEncodes() -> Bool {
    print("\n=== TEST 17: RestEventRow encodes with snake_case keys ===")
    let event = RestEvent(
        swimmerId: "sw-A",
        repIndex: 2,
        repTimeMs: 60700,
        standardMs: 60000,
        standardSource: .rep1,
        baseRestSec: 180,
        extendedRestSec: 210,
        deltaSec: 30,
        strikeCount: 1,
        reverted: false,
        eventType: .strike
    )

    // (a) all fields populated: every snake_case key must be
    // present. camelCase keys would silently fail the insert —
    // the supabase SDK doesn't auto-translate.
    let rowFull = RestEventRow(
        event: event,
        sessionId: "sess-1",
        workoutSetId: "ws-1",
        createdAt: "2026-08-18T13:00:00Z"
    )
    let dataFull: Data
    do {
        dataFull = try JSONEncoder().encode(rowFull)
    } catch {
        print("  [FAIL] encode threw: \(error)")
        return false
    }
    guard let jsonFull = try? JSONSerialization.jsonObject(with: dataFull) as? [String: Any] else {
        print("  [FAIL] encoded JSON is not a [String: Any]")
        return false
    }

    let expectedKeys: Set<String> = [
        "id", "session_id", "workout_set_id", "swimmer_id",
        "rep_index", "rep_time_ms", "standard_ms",
        "base_rest_sec", "extended_rest_sec", "delta_sec",
        "strike_count", "standard_source", "reverted", "created_at"
    ]
    let actualKeys = Set(jsonFull.keys)
    let missing = expectedKeys.subtracting(actualKeys)
    let extra = actualKeys.subtracting(expectedKeys)

    var allPass = true
    allPass = assertEq("(a) encoded key set == expected snake_case set",
                       actualKeys, expectedKeys) && allPass
    if !missing.isEmpty {
        allPass = assertTrue("(a) no missing keys", missing.isEmpty,
                             extra: "missing=\(missing.sorted())") && allPass
    }
    if !extra.isEmpty {
        allPass = assertTrue("(a) no extra keys", extra.isEmpty,
                             extra: "extra=\(extra.sorted())") && allPass
    }

    // Field-value spot checks — guards against accidental renames
    // in the init's argument order.
    allPass = assertEq("(a) encoded swimmer_id", jsonFull["swimmer_id"] as? String, "sw-A") && allPass
    allPass = assertEq("(a) encoded rep_index", jsonFull["rep_index"] as? Int, 2) && allPass
    allPass = assertEq("(a) encoded rep_time_ms", jsonFull["rep_time_ms"] as? Int, 60700) && allPass
    allPass = assertEq("(a) encoded standard_ms", jsonFull["standard_ms"] as? Int, 60000) && allPass
    allPass = assertEq("(a) encoded standard_source", jsonFull["standard_source"] as? String, "rep1") && allPass
    allPass = assertEq("(a) encoded base_rest_sec", jsonFull["base_rest_sec"] as? Int, 180) && allPass
    allPass = assertEq("(a) encoded extended_rest_sec", jsonFull["extended_rest_sec"] as? Int, 210) && allPass
    allPass = assertEq("(a) encoded delta_sec", jsonFull["delta_sec"] as? Int, 30) && allPass
    allPass = assertEq("(a) encoded strike_count", jsonFull["strike_count"] as? Int, 1) && allPass
    allPass = assertEq("(a) encoded reverted", jsonFull["reverted"] as? Bool, false) && allPass
    allPass = assertEq("(a) encoded session_id", jsonFull["session_id"] as? String, "sess-1") && allPass
    allPass = assertEq("(a) encoded workout_set_id", jsonFull["workout_set_id"] as? String, "ws-1") && allPass
    allPass = assertEq("(a) encoded created_at", jsonFull["created_at"] as? String, "2026-08-18T13:00:00Z") && allPass

    // (b) nil optional fields: encoding still succeeds, the nil
    // keys are dropped (matches `LapRow` behavior in
    // `TimingService.saveSession(...)`). The save path passes
    // sessionId: nil for the single-swimmer flow; the wire
    // payload simply omits the key.
    let rowNil = RestEventRow(
        event: event,
        sessionId: nil,
        workoutSetId: "ws-1",
        createdAt: "2026-08-18T13:00:00Z"
    )
    let dataNil: Data
    do {
        dataNil = try JSONEncoder().encode(rowNil)
    } catch {
        print("  [FAIL] (b) encode threw: \(error)")
        return false
    }
    guard let jsonNil = try? JSONSerialization.jsonObject(with: dataNil) as? [String: Any] else {
        print("  [FAIL] (b) encoded JSON is not a [String: Any]")
        return false
    }
    allPass = assertTrue("(b) nil session_id key is dropped from JSON (JSONEncoder default + LapRow parity)",
                         jsonNil["session_id"] == nil) && allPass
    allPass = assertTrue("(b) non-nil workout_set_id key is still present",
                         jsonNil["workout_set_id"] as? String == "ws-1") && allPass
    allPass = assertTrue("(b) swimmer_id still present",
                         jsonNil["swimmer_id"] as? String == "sw-A") && allPass

    print("  -> TEST 17: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - V0.40 Slice 4 (2026-08-18) — per-swimmer zone gate tests
//
// The V0.39 gate is a single `setIsAnaerobic: Bool` derived from
// the set's intensity label. V0.40 Slice 4 adds a per-swimmer zone
// gate: when a swimmer has a usable 3MT profile, the drop rule
// fires ONLY for Hard/Sprint sets (rep pace ≤ the swimmer's Hard
// zone boundary in s/100m). No profile → fall back to V0.39. The
// pure-logic boundary lives in the model; these tests pin the
// boundary math so the wiring can be regression-gated without a
// booted simulator.
//
// Reference numbers (used to construct ZoneGates in the tests):
//   CS = 1.33 m/s
//     easy   boundary (mps) = 0.89  × 1.33 = 1.1837 → pace ≈ 84.47 s/100m
//     steady boundary (mps) = 1.0   × 1.33 = 1.3300 → pace ≈ 75.19 s/100m
//     hard   boundary (mps) = 1.035 × 1.33 = 1.37655 → pace ≈ 72.64 s/100m  ← THE gate boundary
//     sprint boundary (mps) = 1.6                → pace = 62.50 s/100m
//
// For a 50m rep, per-100m pace s/100m = (repTimeMs / 1000) * (100 / 50)
// = repTimeMs / 500. So:
//   repTimeMs = 38000 → pace = 76.00 s/100m (slower than 72.64 → CLOSED)
//   repTimeMs = 36000 → pace = 72.00 s/100m (≤ 72.64 → OPEN)
//   repTimeMs = 30000 → pace = 60.00 s/100m (≤ 72.64 → OPEN)
// To keep the test math clean and self-documenting, the tests use
// rounded boundary values (84.0 / 75.0 / 72.0 / 62.0 s/100m) — the
// gate only depends on the hard boundary being between the test
// rep's pace and the boundary itself, so rounded values keep the
// gate decision unambiguous.

// MARK: - Test 18: V0.40 Slice 4 — zone gate, Steady pace → CLOSED

/// Swimmer has a usable profile (zone gate with hasProfile=true).
/// Rep pace in Steady zone (slower than hard boundary) → evaluate
/// returns nil (drop rule does NOT fire for Easy/Steady sets).
/// The rep is otherwise within threshold (rep = rep1) so the
/// only reason evaluate returns nil is the per-swimmer zone gate.
func runZoneGateSteadyCloses() -> Bool {
    print("\n=== TEST 18: zone gate, Steady pace → CLOSED ===")
    let baseRest = 180
    let m = RestCountdownModel(baseRestSec: baseRest, setIsAnaerobic: true)
    let swimmerId = "sw-A"

    // hard boundary = 72.0 s/100m → the gate. Reps at 76 s/100m
    // are slower (higher s/100m) → Easy/Steady → CLOSED.
    let gate = ZoneGate(
        hasProfile: true,
        easyBoundarySecPer100: 84.0,
        steadyBoundarySecPer100: 75.0,
        hardBoundarySecPer100: 72.0,
        sprintBoundarySecPer100: 62.0
    )
    m.zoneGateBySwimmer[swimmerId] = gate

    // Rep at 50m, repTimeMs = 38000 → pace = 38000 / 500 = 76.0 s/100m
    // (slower than hard 72.0 → Easy/Steady → gate CLOSED). Rep is
    // at rep1 (rep1TimeMs = 38000) so the rep is otherwise at the
    // standard → the V0.39 path would have evaluated (struck=false).
    // The zone gate is the ONLY reason evaluate returns nil.
    let eval = m.evaluate(
        swimmerId: swimmerId, repIndex: 1, repTimeMs: 38000,
        distanceMeters: 50,
        predictedStandardMs: nil, predictionMaturity: nil,
        rep1TimeMs: 38000
    )

    var allPass = true
    allPass = assertEq("Steady pace → evaluate returns nil (gate CLOSED)",
                       eval, nil) && allPass
    // Also assert: the gate did NOT mutate per-swimmer state. A
    // closed gate is a true no-op — no strikes, no extension, no
    // standard recorded (the VM never saw the rep).
    allPass = assertEq("Steady pace: strikes[A] untouched",
                       m.strikes[swimmerId] ?? -1, -1) && allPass
    allPass = assertEq("Steady pace: extendedRestSec untouched (still base)",
                       m.extendedRestSec, baseRest) && allPass

    print("  -> TEST 18: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - Test 19: V0.40 Slice 4 — zone gate, Hard pace → OPEN

/// Same swimmer as Test 18 (same ZoneGate), rep pace exactly at
/// the hard boundary → evaluate returns non-nil (gate OPEN at
/// the boundary, ≤). The V0.39 evaluation runs as normal.
func runZoneGateHardOpens() -> Bool {
    print("\n=== TEST 19: zone gate, Hard pace (at boundary) → OPEN ===")
    let baseRest = 180
    let m = RestCountdownModel(baseRestSec: baseRest, setIsAnaerobic: true)
    let swimmerId = "sw-A"

    let gate = ZoneGate(
        hasProfile: true,
        easyBoundarySecPer100: 84.0,
        steadyBoundarySecPer100: 75.0,
        hardBoundarySecPer100: 72.0,
        sprintBoundarySecPer100: 62.0
    )
    m.zoneGateBySwimmer[swimmerId] = gate

    // Rep at 50m, repTimeMs = 36000 → pace = 36000 / 500 = 72.0 s/100m
    // (exactly at the hard boundary, ≤ → gate OPEN). Rep at rep1
    // so the V0.39 path returns struck=false.
    let eval = m.evaluate(
        swimmerId: swimmerId, repIndex: 1, repTimeMs: 36000,
        distanceMeters: 50,
        predictedStandardMs: nil, predictionMaturity: nil,
        rep1TimeMs: 36000
    )

    var allPass = true
    allPass = assertTrue("Hard pace (at boundary) → evaluate returns non-nil",
                         eval != nil) && allPass
    guard let e = eval else { return false }
    allPass = assertEq("Hard pace: struck=false (rep at standard)", e.struck, false) && allPass
    allPass = assertEq("Hard pace: deltaSec == 0 (no extension)", e.deltaSec, 0) && allPass
    allPass = assertEq("Hard pace: standard == 36000 (rep1 fallback)",
                       e.standardMs, 36000) && allPass

    print("  -> TEST 19: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - Test 20: V0.40 Slice 4 — zone gate, Sprint pace → OPEN

/// Same swimmer, rep pace in Sprint zone (faster than both Hard
/// and Sprint boundaries) → gate OPEN. The gate only checks the
/// hard boundary, but Sprint is faster than Hard so a Sprint rep
/// is also at-or-under the hard threshold → OPEN. This pins the
/// "Sprint is also Hard-or-faster" invariant so a future slice
/// that distinguishes Hard from Sprint doesn't break the gate.
func runZoneGateSprintOpens() -> Bool {
    print("\n=== TEST 20: zone gate, Sprint pace → OPEN ===")
    let baseRest = 180
    let m = RestCountdownModel(baseRestSec: baseRest, setIsAnaerobic: true)
    let swimmerId = "sw-A"

    let gate = ZoneGate(
        hasProfile: true,
        easyBoundarySecPer100: 84.0,
        steadyBoundarySecPer100: 75.0,
        hardBoundarySecPer100: 72.0,
        sprintBoundarySecPer100: 62.0
    )
    m.zoneGateBySwimmer[swimmerId] = gate

    // Rep at 50m, repTimeMs = 30000 → pace = 30000 / 500 = 60.0 s/100m
    // (faster than hard 72.0 AND sprint 62.0 → in Sprint → gate OPEN).
    let eval = m.evaluate(
        swimmerId: swimmerId, repIndex: 1, repTimeMs: 30000,
        distanceMeters: 50,
        predictedStandardMs: nil, predictionMaturity: nil,
        rep1TimeMs: 30000
    )

    var allPass = true
    allPass = assertTrue("Sprint pace → evaluate returns non-nil",
                         eval != nil) && allPass
    guard let e = eval else { return false }
    allPass = assertEq("Sprint pace: struck=false (rep at standard)",
                       e.struck, false) && allPass

    print("  -> TEST 20: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - Test 21: V0.40 Slice 4 — no profile, anaerobic set → V0.39 behavior

/// Swimmer WITHOUT usable profile, setIsAnaerobic=true → V0.39
/// fallback: evaluate returns non-nil regardless of the rep's
/// zone. Two sub-cases:
///   (a) No zoneGate entry at all (the typical "fetch hasn't
///       returned yet" path) → evaluate non-nil.
///   (b) zoneGate entry with hasProfile=false (the explicit
///       "resolver returned nil" marker) → evaluate non-nil.
/// The model must NOT close the gate on the absence of a gate
/// marker; only on a present marker that says "no profile".
func runZoneGateNoProfileAnaerobic() -> Bool {
    print("\n=== TEST 21: no profile, anaerobic set → V0.39 behavior ===")
    let baseRest = 180
    let swimmerId = "sw-A"
    let standard = 60000   // 60s
    let overThreshold = 60700  // 60.7s, > standard + 500ms → strike

    // (a) No zoneGate entry for this swimmer.
    let m1 = RestCountdownModel(baseRestSec: baseRest, setIsAnaerobic: true)
    let eval1 = m1.evaluate(
        swimmerId: swimmerId, repIndex: 1, repTimeMs: overThreshold,
        distanceMeters: 50,
        predictedStandardMs: nil, predictionMaturity: nil,
        rep1TimeMs: standard
    )

    var allPass = true
    allPass = assertTrue("(a) no zoneGate entry → evaluate non-nil (V0.39)",
                         eval1 != nil) && allPass
    guard let e1 = eval1 else { return false }
    allPass = assertEq("(a) no entry → strike fires (over threshold)",
                       e1.struck, true) && allPass
    allPass = assertEq("(a) no entry → strikeCount == 1", e1.strikeCount, 1) && allPass

    // (b) zoneGate entry with hasProfile=false.
    let m2 = RestCountdownModel(baseRestSec: baseRest, setIsAnaerobic: true)
    m2.zoneGateBySwimmer[swimmerId] = ZoneGate(
        hasProfile: false,
        easyBoundarySecPer100: 84.0,
        steadyBoundarySecPer100: 75.0,
        hardBoundarySecPer100: 72.0,
        sprintBoundarySecPer100: 62.0
    )
    let eval2 = m2.evaluate(
        swimmerId: swimmerId, repIndex: 1, repTimeMs: overThreshold,
        distanceMeters: 50,
        predictedStandardMs: nil, predictionMaturity: nil,
        rep1TimeMs: standard
    )

    allPass = assertTrue("(b) hasProfile=false → evaluate non-nil (V0.39)",
                         eval2 != nil) && allPass
    guard let e2 = eval2 else { return false }
    allPass = assertEq("(b) hasProfile=false → strike fires (over threshold)",
                       e2.struck, true) && allPass
    allPass = assertEq("(b) hasProfile=false → strikeCount == 1",
                       e2.strikeCount, 1) && allPass

    print("  -> TEST 21: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - Test 22: V0.40 Slice 4 — no profile, aerobic set → V0.39 fallback

/// Swimmer WITHOUT usable profile, setIsAnaerobic=false → V0.39
/// aerobic gate is unchanged: evaluate returns nil. The zone gate
/// is a REFINE on top of V0.39; it does NOT relax the aerobic gate.
func runZoneGateNoProfileAerobic() -> Bool {
    print("\n=== TEST 22: no profile, aerobic set → V0.39 fallback ===")
    let baseRest = 180
    let m = RestCountdownModel(baseRestSec: baseRest, setIsAnaerobic: false)
    let swimmerId = "sw-A"

    let eval = m.evaluate(
        swimmerId: swimmerId, repIndex: 1, repTimeMs: 100000,
        distanceMeters: 50,
        predictedStandardMs: nil, predictionMaturity: nil,
        rep1TimeMs: 60000
    )

    var allPass = true
    allPass = assertEq("aerobic set → evaluate returns nil (V0.39)",
                       eval, nil) && allPass
    allPass = assertEq("aerobic set: strikes untouched",
                       m.strikes[swimmerId] ?? 0, 0) && allPass
    allPass = assertEq("aerobic set: extendedRestSec == base (unchanged)",
                       m.extendedRestSec, baseRest) && allPass

    print("  -> TEST 22: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - Test 23: V0.40 Slice 4 — invalid zone boundaries → fallback, no crash

/// ZoneGate with non-finite or non-positive hard boundary →
/// falls back to `setIsAnaerobic` (evaluate non-nil when
/// anaerobic, nil when aerobic). The "never crashes" rule covers
/// partial rows, mid-migration data, corrupted profiles. The model
/// MUST NOT crash on NaN / infinity / negative inputs — it must
/// gracefully fall through to V0.39 behavior.
///
/// Sub-cases:
///   (a) NaN hard boundary, anaerobic set → evaluate non-nil.
///   (b) Negative hard boundary, anaerobic set → evaluate non-nil.
///   (c) Infinity hard boundary, aerobic set → evaluate nil
///       (the V0.39 aerobic gate fires, not the zone gate — the
///       zone gate never gets a chance to apply).
///   (d) Zero hard boundary, anaerobic set → evaluate non-nil.
///   (e) Infinity hard boundary, anaerobic set → evaluate non-nil
///       (the boundary is non-finite → fall through; the gate
///       can never be OPEN with an infinite boundary in any
///       reasonable interpretation, but the spec's "never
///       crashes" rule says fall through rather than guard into
///       the wrong branch).
func runZoneGateInvalidBoundaries() -> Bool {
    print("\n=== TEST 23: invalid zone boundaries → fallback ===")
    let baseRest = 180
    let swimmerId = "sw-A"
    let standard = 60000
    let overThreshold = 60700

    // (a) NaN hard boundary, anaerobic → evaluate non-nil.
    let m1 = RestCountdownModel(baseRestSec: baseRest, setIsAnaerobic: true)
    m1.zoneGateBySwimmer[swimmerId] = ZoneGate(
        hasProfile: true,
        easyBoundarySecPer100: 84.0,
        steadyBoundarySecPer100: 75.0,
        hardBoundarySecPer100: Double.nan,
        sprintBoundarySecPer100: 62.0
    )
    let eval1 = m1.evaluate(
        swimmerId: swimmerId, repIndex: 1, repTimeMs: overThreshold,
        distanceMeters: 50,
        predictedStandardMs: nil, predictionMaturity: nil,
        rep1TimeMs: standard
    )
    var allPass = true
    allPass = assertTrue("(a) NaN hard boundary, anaerobic → non-nil (fallback)",
                         eval1 != nil) && allPass

    // (b) Negative hard boundary, anaerobic → evaluate non-nil.
    let m2 = RestCountdownModel(baseRestSec: baseRest, setIsAnaerobic: true)
    m2.zoneGateBySwimmer[swimmerId] = ZoneGate(
        hasProfile: true,
        easyBoundarySecPer100: 84.0,
        steadyBoundarySecPer100: 75.0,
        hardBoundarySecPer100: -1.0,
        sprintBoundarySecPer100: 62.0
    )
    let eval2 = m2.evaluate(
        swimmerId: swimmerId, repIndex: 1, repTimeMs: overThreshold,
        distanceMeters: 50,
        predictedStandardMs: nil, predictionMaturity: nil,
        rep1TimeMs: standard
    )
    allPass = assertTrue("(b) negative hard boundary, anaerobic → non-nil (fallback)",
                         eval2 != nil) && allPass

    // (c) Infinity hard boundary, aerobic → evaluate nil (V0.39
    // aerobic gate wins; the zone gate never reaches the
    // boundary check).
    let m3 = RestCountdownModel(baseRestSec: baseRest, setIsAnaerobic: false)
    m3.zoneGateBySwimmer[swimmerId] = ZoneGate(
        hasProfile: true,
        easyBoundarySecPer100: 84.0,
        steadyBoundarySecPer100: 75.0,
        hardBoundarySecPer100: Double.infinity,
        sprintBoundarySecPer100: 62.0
    )
    let eval3 = m3.evaluate(
        swimmerId: swimmerId, repIndex: 1, repTimeMs: overThreshold,
        distanceMeters: 50,
        predictedStandardMs: nil, predictionMaturity: nil,
        rep1TimeMs: standard
    )
    allPass = assertEq("(c) infinity hard boundary, aerobic → nil (aerobic gate)",
                       eval3, nil) && allPass

    // (d) Zero hard boundary, anaerobic → evaluate non-nil.
    // The "hard > 0" guard rejects zero (any positive pace is
    // > 0 → OPEN; but zero means "all reps are below
    // boundary" which is meaningless, so fall through is the
    // safe default per the spec's "never crashes" rule).
    let m4 = RestCountdownModel(baseRestSec: baseRest, setIsAnaerobic: true)
    m4.zoneGateBySwimmer[swimmerId] = ZoneGate(
        hasProfile: true,
        easyBoundarySecPer100: 84.0,
        steadyBoundarySecPer100: 75.0,
        hardBoundarySecPer100: 0.0,
        sprintBoundarySecPer100: 62.0
    )
    let eval4 = m4.evaluate(
        swimmerId: swimmerId, repIndex: 1, repTimeMs: overThreshold,
        distanceMeters: 50,
        predictedStandardMs: nil, predictionMaturity: nil,
        rep1TimeMs: standard
    )
    allPass = assertTrue("(d) zero hard boundary, anaerobic → non-nil (fallback)",
                         eval4 != nil) && allPass

    // (e) Infinity hard boundary, anaerobic → evaluate non-nil.
    // Non-finite → fall through (the boundary check is unsafe
    // when the boundary is infinite — any finite pace is "≤ ∞",
    // but the spec's defensive rule is to fall through on any
    // non-finite value rather than risk an inverted gate).
    let m5 = RestCountdownModel(baseRestSec: baseRest, setIsAnaerobic: true)
    m5.zoneGateBySwimmer[swimmerId] = ZoneGate(
        hasProfile: true,
        easyBoundarySecPer100: 84.0,
        steadyBoundarySecPer100: 75.0,
        hardBoundarySecPer100: Double.infinity,
        sprintBoundarySecPer100: 62.0
    )
    let eval5 = m5.evaluate(
        swimmerId: swimmerId, repIndex: 1, repTimeMs: overThreshold,
        distanceMeters: 50,
        predictedStandardMs: nil, predictionMaturity: nil,
        rep1TimeMs: standard
    )
    allPass = assertTrue("(e) infinity hard boundary, anaerobic → non-nil (fallback)",
                         eval5 != nil) && allPass

    print("  -> TEST 23: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - Main

@main
struct RestCountdownCLITest {
    static func main() {
        print("=== RestCountdownCLI Test — V0.39 Slice 2 + Slice 4 + V0.40 Slice 4 ===")
        print("=== Pure-logic gate for the drop-rule state machine ===")
        print("=== Exercises real RestCountdownModel, no Supabase, no XCTest. ===")
        print("")

        let t1 = runStrikeOn50mOver0_5s()
        let t2 = runNoStrikeWithinThreshold()
        let t3 = runSecondStrikeEscalates()
        let t4 = runStrikeResetOnGoodRep()
        let t5 = runMaturityGate()
        let t6 = runAerobicGate()
        let t7 = runRevertRestoresBase()
        let t8 = runTickFloor()
        let t9 = run25mThreshold()
        let t10 = runLinearScaling100m()
        let t11 = runMultiSwimmer()
        let t12 = runResetClearsState()
        let t13 = runTrailAppendsOnStrike()
        let t14 = runTrailNoAppendOnNonStrike()
        let t15 = runTrailRevertCarriesStrikeFields()
        let t16 = runTrailResetClears()
        let t17 = runRestEventRowEncodes()
        let t18 = runZoneGateSteadyCloses()
        let t19 = runZoneGateHardOpens()
        let t20 = runZoneGateSprintOpens()
        let t21 = runZoneGateNoProfileAnaerobic()
        let t22 = runZoneGateNoProfileAerobic()
        let t23 = runZoneGateInvalidBoundaries()

        let results: [(String, Bool)] = [
            ("TEST 1 strike on 50m > 0.5s",     t1),
            ("TEST 2 no strike within threshold", t2),
            ("TEST 3 second strike +60",          t3),
            ("TEST 4 strike reset on good rep",   t4),
            ("TEST 5 maturity gate",              t5),
            ("TEST 6 aerobic gate",               t6),
            ("TEST 7 revert restores base",       t7),
            ("TEST 8 tick floor",                 t8),
            ("TEST 9 25m threshold 0.25s",        t9),
            ("TEST 10 100m linear scaling",       t10),
            ("TEST 11 multi-swimmer common clock", t11),
            ("TEST 12 reset clears state",        t12),
            ("TEST 13 trail appends on strike",    t13),
            ("TEST 14 no append on non-strike",   t14),
            ("TEST 15 revert carries strike fields", t15),
            ("TEST 16 reset clears trail",         t16),
            ("TEST 17 RestEventRow snake_case JSON", t17),
            ("TEST 18 zone gate Steady → CLOSED",   t18),
            ("TEST 19 zone gate Hard → OPEN",       t19),
            ("TEST 20 zone gate Sprint → OPEN",     t20),
            ("TEST 21 zone gate no profile anaerobic → V0.39", t21),
            ("TEST 22 zone gate no profile aerobic → V0.39", t22),
            ("TEST 23 zone gate invalid boundaries → fallback", t23),
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
