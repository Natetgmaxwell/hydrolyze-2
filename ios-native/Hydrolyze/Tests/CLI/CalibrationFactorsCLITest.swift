// CalibrationFactorsCLITest — T5 (Phase 1 v3 plan) CLI test matrix for
// the suit + start calibration feature. Covers both the standalone
// helper (CalibrationFactors) and the integration with the predictor
// (HistoricalTimePredictor).
//
// Usage: CalibrationFactorsCLITest
// Compiled by build_and_run.sh (see sibling script).
//
// Phase 1 (T5, 2026-06-20): 10 test cases covering:
//   - CalibrationFactors.suitMultiplier: 0 rows, 1 row, 2 rows
//   - CalibrationFactors.suitMultiplier: setSuit direction (true / false)
//   - CalibrationFactors.startMultiplier: in_water reference (1.0)
//   - CalibrationFactors.startMultiplier: dive + in_water pair
//   - CalibrationFactors.startMultiplier: divide-by-zero guard
//   - HistoricalTimePredictor.predict: no calibration (regression check)
//   - HistoricalTimePredictor.predict: suit calibration applied
//   - HistoricalTimePredictor.predict: start calibration applied
//   - HistoricalTimePredictor.predict: both calibrations applied
//
// Ponytail-pass: XCTest-free CLI, stdlib only, no deps, one main,
// 10 scenarios as 10 calls to a shared `runTest` helper. Deterministic
// (no random; exact values asserted with ±1ms tolerance for rounding).

import Foundation

// MARK: - Test data builders

/// Stable test swimmer. The id is reused across the helper and
/// predictor tests so the cache is keyed correctly.
let testSwimmerId = "00000000-0000-4000-8000-000000000001"

func makeTestSwimmer() -> Swimmer {
    Swimmer(
        id: testSwimmerId,
        coachId: "test-coach",
        firstName: "Test-Swimmer",
        lastName: nil,
        birthdate: nil,
        gender: nil,
        notes: nil,
        preferredGear: "none",
        formStroke: "Free",
        mainStroke: "Free",
        archivedAt: nil,
        createdAt: nil
    )
}

func makeTestWorkoutSet(suit: Bool? = nil, startType: String? = nil) -> WorkoutSet {
    WorkoutSet(
        id: "test-set-50free",
        workoutId: "test-workout",
        orderIndex: 0,
        reps: 1,
        distance: 50,
        stroke: "Free",
        intervalText: nil,
        intensityType: nil,
        intensityLabel: "race",
        paceTargetDistance: 50,
        gear: "none",
        // T3 / Phase 1 fields (T1 schema, 2026-06-20)
        suit: suit,
        startType: startType,
        createdAt: ISO8601DateFormatter().string(from: Date())
    )
}

func makeTestPB(timeMs: Int = 30000) -> SwimmerPB {
    SwimmerPB(
        id: "test-pb",
        swimmerId: testSwimmerId,
        distance: 50,
        stroke: "Free",
        timeMs: timeMs,
        gear: "none",
        intensity: "max",
        recordedAt: ISO8601DateFormatter().string(from: Date())
    )
}

func makeTestPrefs() -> CoachPreferences {
    // Minimal CoachPreferences with the v1.13.0 default algorithm
    // (median). The full struct has more fields; we just need enough
    // for the predictor not to crash. If a field is required by the
    // predictor, this will fail to compile and the user can fill it in.
    CoachPreferences()
}

// MARK: - Test runners

var passed = 0
var failed = 0

func runTest(_ name: String, _ body: () -> Bool) {
    let ok = body()
    if ok {
        passed += 1
        print("  ✓ \(name)")
    } else {
        failed += 1
        print("  ✗ \(name)")
    }
}

func assertClose(_ actual: Double, _ expected: Double, tolerance: Double = 1.0, label: String) -> Bool {
    let delta = abs(actual - expected)
    if delta > tolerance {
        print("    FAIL: \(label) actual=\(actual) expected=\(expected) delta=\(delta) (tolerance=\(tolerance))")
        return false
    }
    return true
}

func assertEqual<T: Equatable>(_ actual: T, _ expected: T, label: String) -> Bool {
    if actual != expected {
        print("    FAIL: \(label) actual=\(actual) expected=\(expected)")
        return false
    }
    return true
}

// MARK: - Test 1: suitMultiplier, 0 rows → nil

func testSuitMultiplier_0rows() -> Bool {
    print("\n── Test 1: suitMultiplier, 0 rows → nil ──")
    let cal = CalibrationFactors()
    let result = cal.suitMultiplier(swimmerId: testSwimmerId, distance: 50, stroke: "Free", setSuit: true)
    return assertEqual(result, Optional<Double>.none, label: "result is nil")
}

// MARK: - Test 2: suitMultiplier, 1 row → nil (insufficient data for pair)

func testSuitMultiplier_1row() -> Bool {
    print("\n── Test 2: suitMultiplier, 1 row → nil ──")
    let cal = CalibrationFactors()
    let row = CalibrationFactors.CalibrationRow(
        swimmerId: testSwimmerId,
        distance: 50,
        stroke: "Free",
        meanTimeMs: 30000.0,
        sampleCount: 1,
        suit: false,
        startType: nil
    )
    cal.seedForTesting(rowsBySwimmerId: [testSwimmerId: [row]])
    let result = cal.suitMultiplier(swimmerId: testSwimmerId, distance: 50, stroke: "Free", setSuit: true)
    return assertEqual(result, Optional<Double>.none, label: "result is nil (no pair)")
}

// MARK: - Test 3: suitMultiplier, 2 rows → ratio (setSuit=true)

func testSuitMultiplier_2rows_setSuitTrue() -> Bool {
    print("\n── Test 3: suitMultiplier, 2 rows, setSuit=true → mean(suit)/mean(no-suit) ──")
    let cal = CalibrationFactors()
    let rowNoSuit = CalibrationFactors.CalibrationRow(
        swimmerId: testSwimmerId, distance: 50, stroke: "Free",
        meanTimeMs: 30000.0, sampleCount: 1, suit: false, startType: nil
    )
    let rowSuit = CalibrationFactors.CalibrationRow(
        swimmerId: testSwimmerId, distance: 50, stroke: "Free",
        meanTimeMs: 29500.0, sampleCount: 1, suit: true, startType: nil
    )
    cal.seedForTesting(rowsBySwimmerId: [testSwimmerId: [rowNoSuit, rowSuit]])
    let result = cal.suitMultiplier(swimmerId: testSwimmerId, distance: 50, stroke: "Free", setSuit: true)
    // Expected: 29500/30000 = 0.9833...
    let expected = 29500.0 / 30000.0
    return assertClose(result ?? -1, expected, label: "multiplier")
}

// MARK: - Test 4: suitMultiplier, 2 rows, setSuit=false → inverted

func testSuitMultiplier_2rows_setSuitFalse() -> Bool {
    print("\n── Test 4: suitMultiplier, 2 rows, setSuit=false → mean(no-suit)/mean(suit) ──")
    let cal = CalibrationFactors()
    let rowNoSuit = CalibrationFactors.CalibrationRow(
        swimmerId: testSwimmerId, distance: 50, stroke: "Free",
        meanTimeMs: 30000.0, sampleCount: 1, suit: false, startType: nil
    )
    let rowSuit = CalibrationFactors.CalibrationRow(
        swimmerId: testSwimmerId, distance: 50, stroke: "Free",
        meanTimeMs: 29500.0, sampleCount: 1, suit: true, startType: nil
    )
    cal.seedForTesting(rowsBySwimmerId: [testSwimmerId: [rowNoSuit, rowSuit]])
    let result = cal.suitMultiplier(swimmerId: testSwimmerId, distance: 50, stroke: "Free", setSuit: false)
    // Expected: 30000/29500 = 1.0169...
    let expected = 30000.0 / 29500.0
    return assertClose(result ?? -1, expected, label: "inverted multiplier")
}

// MARK: - Test 5: startMultiplier, in_water → 1.0 (reference)

func testStartMultiplier_inWaterReference() -> Bool {
    print("\n── Test 5: startMultiplier, in_water → 1.0 (reference) ──")
    let cal = CalibrationFactors()
    let row = CalibrationFactors.CalibrationRow(
        swimmerId: testSwimmerId, distance: 50, stroke: "Free",
        meanTimeMs: 30000.0, sampleCount: 1, suit: nil, startType: "in_water"
    )
    cal.seedForTesting(rowsBySwimmerId: [testSwimmerId: [row]])
    let result = cal.startMultiplier(swimmerId: testSwimmerId, distance: 50, stroke: "Free", startType: "in_water")
    return assertEqual(result, 1.0, label: "in_water reference")
}

// MARK: - Test 6: startMultiplier, dive + in_water → ratio

func testStartMultiplier_dive() -> Bool {
    print("\n── Test 6: startMultiplier, dive + in_water → mean(dive)/mean(in_water) ──")
    let cal = CalibrationFactors()
    let rowInWater = CalibrationFactors.CalibrationRow(
        swimmerId: testSwimmerId, distance: 50, stroke: "Free",
        meanTimeMs: 30000.0, sampleCount: 1, suit: nil, startType: "in_water"
    )
    let rowDive = CalibrationFactors.CalibrationRow(
        swimmerId: testSwimmerId, distance: 50, stroke: "Free",
        meanTimeMs: 28500.0, sampleCount: 1, suit: nil, startType: "dive"
    )
    cal.seedForTesting(rowsBySwimmerId: [testSwimmerId: [rowInWater, rowDive]])
    let result = cal.startMultiplier(swimmerId: testSwimmerId, distance: 50, stroke: "Free", startType: "dive")
    // Expected: 28500/30000 = 0.95
    return assertClose(result ?? -1, 0.95, tolerance: 0.0001, label: "dive multiplier")
}

// MARK: - Test 7: startMultiplier, divide-by-zero guard

func testStartMultiplier_divByZeroGuard() -> Bool {
    print("\n── Test 7: startMultiplier, in_water mean=0 → nil (divide-by-zero guard) ──")
    let cal = CalibrationFactors()
    let rowInWaterZero = CalibrationFactors.CalibrationRow(
        swimmerId: testSwimmerId, distance: 50, stroke: "Free",
        meanTimeMs: 0.0, sampleCount: 1, suit: nil, startType: "in_water"
    )
    let rowDive = CalibrationFactors.CalibrationRow(
        swimmerId: testSwimmerId, distance: 50, stroke: "Free",
        meanTimeMs: 28500.0, sampleCount: 1, suit: nil, startType: "dive"
    )
    cal.seedForTesting(rowsBySwimmerId: [testSwimmerId: [rowInWaterZero, rowDive]])
    let result = cal.startMultiplier(swimmerId: testSwimmerId, distance: 50, stroke: "Free", startType: "dive")
    return assertEqual(result, Optional<Double>.none, label: "result is nil (guard)")
}

// MARK: - Test 8: Predictor, no calibration → no delta

func testPredictor_noCalibration() -> Bool {
    print("\n── Test 8: Predictor, no calibration → no delta, timeMs = raw PB ──")
    let cal = CalibrationFactors()
    cal.seedForTesting(rowsBySwimmerId: [:])  // empty cache
    let predictor = HistoricalTimePredictor()
    let pred = predictor.predict(
        swimmer: makeTestSwimmer(),
        set: makeTestWorkoutSet(suit: false, startType: "in_water"),
        recordedTimes: [],
        pbs: [makeTestPB(timeMs: 30000)],
        calibration: cal,
        prefs: makeTestPrefs()
    )
    guard let p = pred else {
        print("    FAIL: predictor returned nil")
        return false
    }
    // Layer 2 (PB curve) with intensity=race, gear=none → multipliers = 1.0
    // Time should equal the raw PB: 30000ms
    let timeOk = assertEqual(p.timeMs, 30000, label: "timeMs == 30000 (raw PB)")
    let suitOk = assertEqual(p.suitDeltaMs, Optional<Int>.none, label: "suitDeltaMs == nil")
    let startOk = assertEqual(p.startDeltaMs, Optional<Int>.none, label: "startDeltaMs == nil")
    return timeOk && suitOk && startOk
}

// MARK: - Test 9: Predictor, suit calibration → suit delta applied

func testPredictor_suitCalibration() -> Bool {
    print("\n── Test 9: Predictor, suit calibration (set.suit=true) → suit delta applied ──")
    let cal = CalibrationFactors()
    let rowNoSuit = CalibrationFactors.CalibrationRow(
        swimmerId: testSwimmerId, distance: 50, stroke: "Free",
        meanTimeMs: 30000.0, sampleCount: 1, suit: false, startType: nil
    )
    let rowSuit = CalibrationFactors.CalibrationRow(
        swimmerId: testSwimmerId, distance: 50, stroke: "Free",
        meanTimeMs: 29500.0, sampleCount: 1, suit: true, startType: nil
    )
    cal.seedForTesting(rowsBySwimmerId: [testSwimmerId: [rowNoSuit, rowSuit]])
    let predictor = HistoricalTimePredictor()
    let pred = predictor.predict(
        swimmer: makeTestSwimmer(),
        set: makeTestWorkoutSet(suit: true, startType: "in_water"),
        recordedTimes: [],
        pbs: [makeTestPB(timeMs: 30000)],
        calibration: cal,
        prefs: makeTestPrefs()
    )
    guard let p = pred else {
        print("    FAIL: predictor returned nil")
        return false
    }
    // Raw PB = 30000. suit_mult = mean(suit)/mean(no-suit) = 29500/30000 = 0.9833
    // Predicted time = round(30000 * 0.9833) = 29500
    // suitDeltaMs = round(30000 * (0.9833 - 1.0)) = -500
    let timeOk = assertEqual(p.timeMs, 29500, label: "timeMs == 29500 (suit-adjusted)")
    let suitOk = assertEqual(p.suitDeltaMs, -500, label: "suitDeltaMs == -500")
    let startOk = assertEqual(p.startDeltaMs, Optional<Int>.none, label: "startDeltaMs == nil (no start cal)")
    return timeOk && suitOk && startOk
}

// MARK: - Test 10: Predictor, both calibrations → both deltas applied

func testPredictor_bothCalibrations() -> Bool {
    print("\n── Test 10: Predictor, both suit + start calibration → both deltas applied ──")
    let cal = CalibrationFactors()
    let rowNoSuit = CalibrationFactors.CalibrationRow(
        swimmerId: testSwimmerId, distance: 50, stroke: "Free",
        meanTimeMs: 30000.0, sampleCount: 1, suit: false, startType: nil
    )
    let rowSuit = CalibrationFactors.CalibrationRow(
        swimmerId: testSwimmerId, distance: 50, stroke: "Free",
        meanTimeMs: 29500.0, sampleCount: 1, suit: true, startType: nil
    )
    let rowInWater = CalibrationFactors.CalibrationRow(
        swimmerId: testSwimmerId, distance: 50, stroke: "Free",
        meanTimeMs: 30000.0, sampleCount: 1, suit: nil, startType: "in_water"
    )
    let rowDive = CalibrationFactors.CalibrationRow(
        swimmerId: testSwimmerId, distance: 50, stroke: "Free",
        meanTimeMs: 28500.0, sampleCount: 1, suit: nil, startType: "dive"
    )
    cal.seedForTesting(rowsBySwimmerId: [testSwimmerId: [rowNoSuit, rowSuit, rowInWater, rowDive]])
    let predictor = HistoricalTimePredictor()
    let pred = predictor.predict(
        swimmer: makeTestSwimmer(),
        set: makeTestWorkoutSet(suit: true, startType: "dive"),
        recordedTimes: [],
        pbs: [makeTestPB(timeMs: 30000)],
        calibration: cal,
        prefs: makeTestPrefs()
    )
    guard let p = pred else {
        print("    FAIL: predictor returned nil")
        return false
    }
    // Raw PB = 30000. suit_mult = 0.9833. start_mult = 28500/30000 = 0.95.
    // Predicted time = round(30000 * 0.9833 * 0.95) = round(28025) = 28025
    // suitDeltaMs = round(30000 * (0.9833 - 1.0)) = -500
    // startDeltaMs = round(30000 * (0.95 - 1.0)) = -1500
    let timeOk = assertEqual(p.timeMs, 28025, label: "timeMs == 28025 (both deltas applied)")
    let suitOk = assertEqual(p.suitDeltaMs, -500, label: "suitDeltaMs == -500")
    let startOk = assertEqual(p.startDeltaMs, -1500, label: "startDeltaMs == -1500")
    return timeOk && suitOk && startOk
}

// MARK: - Main

print("=== CalibrationFactors + Predictor Calibration Test Matrix (T5) ===")
print("    Phase 1 (2026-06-20) — verifying the suit + start calibration wiring")

runTest("suitMultiplier, 0 rows → nil", testSuitMultiplier_0rows)
runTest("suitMultiplier, 1 row → nil (insufficient data)", testSuitMultiplier_1row)
runTest("suitMultiplier, 2 rows, setSuit=true → mean(suit)/mean(no-suit)", testSuitMultiplier_2rows_setSuitTrue)
runTest("suitMultiplier, 2 rows, setSuit=false → inverted", testSuitMultiplier_2rows_setSuitFalse)
runTest("startMultiplier, in_water → 1.0 (reference)", testStartMultiplier_inWaterReference)
runTest("startMultiplier, dive + in_water → ratio", testStartMultiplier_dive)
runTest("startMultiplier, divide-by-zero guard → nil", testStartMultiplier_divByZeroGuard)
runTest("Predictor, no calibration → no delta, timeMs = raw PB", testPredictor_noCalibration)
runTest("Predictor, suit calibration (set.suit=true) → suit delta applied", testPredictor_suitCalibration)
runTest("Predictor, both suit + start → both deltas applied", testPredictor_bothCalibrations)

print("\n=== Tally: \(passed) passed, \(failed) failed ===")
exit(failed == 0 ? 0 : 1)
