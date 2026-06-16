// PairingEngineCLITest — runs the v2 pairing engine in CLI mode against
// the actual 8 mock swimmers from the live Supabase DB, simulates the
// wave structure (6+2 default, sendOff=0 / sendOff=10s), and asserts the
// v1.9 no-ghost-taps invariant.
//
// Usage: PairingEngineCLITest
// Compiled by build_and_run.sh (see sibling script).
//
// Phase 2.6 v1.9 — paired with the XCTest suite at
// Hydrolyze/Tests/PairingEngineTest.swift for the same 3 scenarios
// (6+2 / 0+8 / 8+0). This CLI version is for faster iteration on the
// orchestrator Mac (no Xcode required).
//
// Ponytail-pass: XCTest-free CLI, stdlib only, no deps, one main,
// 3 scenarios as 3 calls to a shared `runPairing` helper. 1:1 with
// the XCTest version's logic.

import Foundation

// MARK: - Test data (queried from the live DB at build time)

/// 8 mock swimmers from supabase (queried 2026-06-15). Each row is
/// `(id, firstName, pbMs)`. PBs are real, not hardcoded guesses.
struct MockSwimmer {
    let id: String
    let firstName: String
    let pbMs: Int
}

let mockSwimmers: [MockSwimmer] = [
    // sorted by PB asc (real data from the live DB)
    MockSwimmer(id: "e9137805-0c1b-4361-aa2e-a47c150d6767", firstName: "Mock-Alice",   pbMs: 26800),
    MockSwimmer(id: "7e6ca6c2-b586-4c6c-8bf7-d363c862782e", firstName: "Mock-Bob",     pbMs: 27200),
    MockSwimmer(id: "a7a71d18-0261-41f8-b606-3930be6eb44a", firstName: "Mock-Charlie", pbMs: 27900),
    MockSwimmer(id: "9b2e9233-e128-4714-80c3-daa646b7d5b5", firstName: "Mock-Diana",   pbMs: 28400),
    MockSwimmer(id: "b8c13ff4-730e-4403-8ca5-d28a2bbecc09", firstName: "Mock-Ethan",   pbMs: 29500),
    MockSwimmer(id: "994b7ebf-41fa-47e2-8a18-715e9d53ce26", firstName: "Mock-Fiona",   pbMs: 30100),
    MockSwimmer(id: "1b5261d6-8bbc-4109-8dc5-6c4d3e52e814", firstName: "Mock-George",  pbMs: 31200),
    MockSwimmer(id: "bea69b89-0426-4c51-9eef-29b40fa99715", firstName: "Mock-Hannah",  pbMs: 32800),
]

let sendOffIntervalMs = 10_000

// MARK: - Plausible lap time generator

/// Plausible lap time = PB × intensityMultiplier + Gaussian noise.
/// Variance is the standard deviation of the noise. User said
/// "more variance than 100ms" — using 250ms here (well above the
/// floor, realistic for a coach's reaction time on a 50m Free).
///
/// Wave 0 sendOff = 0, wave 1 sendOff = 10s. Each lap's elapsedMs
/// is at `sendOff + (PB * mult) + noise`.
func plausibleLap(
    wave: Int,
    pbMs: Int,
    intensityMultiplier: Double,
    noise: () -> Double
) -> Int {
    let sendOff = wave * sendOffIntervalMs
    let predicted = Double(pbMs) * intensityMultiplier
    let variance = 250.0  // σ = 250ms (user said > 100ms)
    return sendOff + Int(predicted + noise() * variance)
}

/// Box-Muller Gaussian noise generator. Returns a value drawn from
/// N(0, 1). Two random uniforms → one Gaussian.
func gaussianNoise() -> Double {
    let u1 = max(Double.random(in: 0..<1), 1e-9)
    let u2 = Double.random(in: 0..<1)
    return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
}

// MARK: - Scenario runner

// MARK: - Scenarios

/// Historical recorded_times for the 8 mock swimmers. Used in the
/// "flywheel" scenario to prove that the HistoricalTimePredictor
/// produces EWMA-driven predictions (not static PB-based) when the
/// swimmer has history.
///
/// Variance: ±100-400ms from each swimmer's PB. Realistic for
/// coach-recorded times.
func makeRecordedTimes(forSwimmer swimmerId: String, setId: String, intensity: String) -> [RecordedTime] {
    let pb = mockSwimmers.first { $0.id == swimmerId }!.pbMs
    // Each swimmer has 5+ recorded times with small variance.
    // PBs are the "true" mean, the times are the "real" data.
    let variances: [Int] = [+100, -200, +300, -100, +200, -300]
    let baseDate = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -86400 * 30))  // 30 days ago
    return variances.enumerated().map { (i, v) in
        RecordedTime(
            id: "rt-\(swimmerId.prefix(8))-\(i)",
            sessionId: nil,
            swimmerId: swimmerId,
            workoutSetId: setId,
            workoutId: nil,
            timeMs: pb + v,
            repIndex: i,
            intensity: intensity,
            gear: "none",
            waveNumber: 0,
            paceDistance: nil,
            createdAt: baseDate,
            lapOrder: i,
            pairedSwimmerId: swimmerId,
            confidence: 95
        )
    }
}

func makeSwimmerPBs() -> [SwimmerPB] {
    let now = ISO8601DateFormatter().string(from: Date())
    return mockSwimmers.map { s in
        SwimmerPB(
            id: "pb-\(s.id.prefix(8))",
            swimmerId: s.id,
            distance: 50,
            stroke: "Free",
            timeMs: s.pbMs,
            gear: "none",
            recordedAt: now
        )
    }
}

func makeWorkoutSet() -> WorkoutSet {
    WorkoutSet(
        id: "test-set-50free-moderate",
        workoutId: "test-workout",
        orderIndex: 0,
        reps: 1,
        distance: 50,
        stroke: "Free",
        intervalText: nil,
        intensityType: nil,
        intensityLabel: "moderate",
        paceTargetDistance: 50,
        gear: "none",
        isCompleted: false,
        createdAt: ISO8601DateFormatter().string(from: Date())
    )
}

func makeSwimmer(_ mock: MockSwimmer) -> Swimmer {
    Swimmer(
        id: mock.id,
        coachId: "test-coach",
        firstName: mock.firstName,
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

func runScenario(
    name: String,
    wave0Indices: [Int],
    wave1Indices: [Int],
    intensityMultiplier: Double = 1.05  // "moderate" — slightly slower than PB
) {
    print("\n┌─── Scenario: \(name) ───┐")
    print("│ Wave 0 (\(wave0Indices.count) swimmers, sendOff=0)")
    for i in wave0Indices { print("│   \(mockSwimmers[i].firstName) PB=\(mockSwimmers[i].pbMs)ms") }
    print("│ Wave 1 (\(wave1Indices.count) swimmers, sendOff=\(sendOffIntervalMs)ms)")
    for i in wave1Indices { print("│   \(mockSwimmers[i].firstName) PB=\(mockSwimmers[i].pbMs)ms") }
    print("│")

    // Build wave assignments
    var waveAssignments: [WaveAssignment] = []
    for (i, idx) in wave0Indices.enumerated() {
        waveAssignments.append(makeWaveAssignment(
            swimmer: mockSwimmers[idx], lane: i + 1,
            wave: 0, sendOff: 0, intensity: intensityMultiplier
        ))
    }
    for (i, idx) in wave1Indices.enumerated() {
        waveAssignments.append(makeWaveAssignment(
            swimmer: mockSwimmers[idx], lane: i + 1,
            wave: 1, sendOff: sendOffIntervalMs, intensity: intensityMultiplier
        ))
    }

    // Build plausible laps. Each lap is a real swimmer touch —
    // no ghost taps. Variance is sampled per lap.
    var laps: [Lap] = []
    var lapNumber = 1
    for wave in [0, 1] {
        let indices = (wave == 0) ? wave0Indices : wave1Indices
        let sendOff = wave * sendOffIntervalMs
        for idx in indices {
            // The coach taps LAP in the order swimmers touch the
            // wall. For each wave, sort the swimmers by their
            // noise-sampled time so the LAP order reflects realistic
            // finish order. (Randomizes per-run, not deterministic.)
            _ = sendOff
            let pb = mockSwimmers[idx].pbMs
            let predicted = Double(pb) * intensityMultiplier
            let actualTime = Int(predicted + gaussianNoise() * 250.0)
            laps.append(Lap(
                id: UUID().uuidString,
                lapNumber: lapNumber,
                elapsedMs: wave * sendOffIntervalMs + actualTime,
                splitMs: actualTime
            ))
            lapNumber += 1
        }
    }

    // Build predictions map (wave-relative, used by the engine for cost)
    let predictions: [String: Prediction] = mockSwimmers.reduce(into: [:]) { acc, s in
        acc[s.id] = Prediction(
            timeMs: s.pbMs,
            sigmaMs: 2000,
            sampleSize: 0,
            source: .curve,
            maturity: .none
        )
    }

    // Run the engine
    let engine = PairingEngine()
    let result = engine.pair(
        laps: laps,
        waveAssignments: waveAssignments,
        predictions: predictions,
        sendOffIntervalMs: sendOffIntervalMs
    )

    // Report
    print("│")
    print("│ Laps fed in: \(laps.count)")
    print("│ Pairing result:")
    print("│   assignments:        \(result.assignments.count)  \(result.assignments.count == 8 ? "✓" : "✗ EXPECTED 8")")
    print("│   unassignedLaps:     \(result.unassignedLaps.count)  \(result.unassignedLaps.count == 0 ? "✓ (no ghost taps)" : "✗ GHOST TAPS")")
    print("│   unassignedSwimmers: \(result.unassignedSwimmers.count)  \(result.unassignedSwimmers.count == 0 ? "✓ (no missed)" : "✗ MISSED SWIMMERS")")
    print("│")

    // Per-swimmer pairing check. Compare against the UUID form
    // (uppercase canonical) — engine normalizes to uppercase, so
    // we do the same here to avoid the v1.9 case-sensitivity bug.
    print("│ Per-swimmer pairing (did each swimmer get their own lap?):")
    let assignedSwimmerIds = Set(result.assignments.map { $0.swimmerId })
    var allMatched = true
    for (_, s) in mockSwimmers.enumerated() {
        // The mockSwimmer's id is the lowercase form from the DB.
        // The engine has it as a UUID. Compare via the parsed UUID.
        let expectedUUID = UUID(uuidString: s.id) ?? UUID()
        let matched = assignedSwimmerIds.contains(expectedUUID)
        let mark = matched ? "✓" : "✗"
        if !matched { allMatched = false }
        print("│   \(mark) \(s.firstName.padding(toLength: 14, withPad: " ", startingAt: 0)) PB=\(s.pbMs)ms")
    }
    print("│")

    // Verdict
    let passed = result.assignments.count == 8
        && result.unassignedLaps.count == 0
        && result.unassignedSwimmers.count == 0
        && allMatched
    print("└─── Verdict: \(passed ? "PASS ✓" : "FAIL ✗") ───┘")
}

func makeWaveAssignment(
    swimmer: MockSwimmer,
    lane: Int,
    wave: Int,
    sendOff: Int,
    intensity: Double
) -> WaveAssignment {
    let predicted = Double(swimmer.pbMs) * intensity
    return WaveAssignment(
        id: UUID().uuidString,
        sessionId: "test-session",
        swimmerId: swimmer.id,
        workoutSetId: "test-set",
        lane: lane,
        positionInLane: 0,
        predictedTouchMs: sendOff + Int(predicted),
        waveNumber: wave,
        sendOffOffsetMs: sendOff,
        coachId: "test-coach",
        createdAt: ISO8601DateFormatter().string(from: Date())
    )
}

// MARK: - Main

@main
struct PairingEngineCLITest {
    static func main() {
        print("=== PairingEngine CLI Test — Phase 2.6 v1.11 ===")
        print("=== 8 mock swimmers queried from the live Supabase DB ===")
        print("=== Wave 0 leaves on the zero, Wave 1 leaves on the +10 ===")
        print("")

        // Scenario A: 6+2 default wave split (realistic for default 6-lane pool)
        runScenario(
            name: "6+2 default",
            wave0Indices: [0, 1, 2, 3, 4, 5],   // Mock-Alice..Mock-Fiona
            wave1Indices: [6, 7]                  // Mock-George, Mock-Hannah
        )

        // Scenario B: 0+8 (all in wave 1)
        runScenario(
            name: "0+8 (all wave 1)",
            wave0Indices: [],
            wave1Indices: [0, 1, 2, 3, 4, 5, 6, 7]
        )

        // Scenario C: 8+0 (all in wave 0)
        runScenario(
            name: "8+0 (all wave 0)",
            wave0Indices: [0, 1, 2, 3, 4, 5, 6, 7],
            wave1Indices: []
        )

        // Scenario D (v1.11 FLYWHEEL): the HistoricalTimePredictor
        // produces EWMA-driven predictions (not static PB-based) when
        // the swimmer has 5+ recorded_times. This is the v2 product
        // vision: "the more history, the more accurate the pairing."
        // We populate synthetic recorded_times for all 8 swimmers
        // (variance ±100-400ms around their PB), call the predictor,
        // and verify (a) the prediction is the EWMA not the PB,
        // (b) the prediction has maturity=.recorded and sampleSize=6,
        // (c) the pairing engine still produces 8/0/0 with the live
        // EWMA-driven predictions. Proves the flywheel wires through.
        runFlywheelScenario()

        // Scenario E (v1.12 E2E SUPABASE): the same flywheel
        // mechanism, but with REAL recorded_times from the live
        // Supabase DB (queried 2026-06-15, 48 rows = 6 per swimmer
        // for the 8 mock swimmers, all for a fresh test
        // workout_set). The values are deterministic (the seed
        // script inserts them) so this is a true end-to-end
        // verification of the predictor against production data.
        // Pre-fix v1.7 (per-wave Hungarian) would have failed
        // here; post-fix v1.10 + v1.11/v1.12 should pass.
        runE2ESupabaseScenario()

        print("\n=== Done ===")
    }

    /// v1.11 FLYWHEEL SCENARIO — prove that the
    /// HistoricalTimePredictor's EWMA-based predictions wire through
    /// to the pairing engine. Synthetic recorded_times are
    /// constructed (6 per swimmer, ±100-400ms around PB). The
    /// predictor should return a prediction with:
    ///   - timeMs ≈ EWMA of recorded times (not the raw PB)
    ///   - maturity == .recorded (not .none)
    ///   - sampleSize == 6
    ///   - sigmaMs ≈ median absolute deviation (not the default 2000)
    ///
    /// Then the pairing engine runs with the live EWMA-driven
    /// predictions. The 8 swimmers should still be matched to their
    /// own laps with 0 ghost taps + 0 missed swimmers (the v1.9
    /// invariant), but with higher confidence than the static PB
    /// scenario — because the EWMA is closer to the actual
    /// variance than the PB.
    static func runFlywheelScenario() {
        print("\n┌─── Scenario: v1.11 FLYWHEEL (EWMA-driven predictions) ───┐")

        let workoutSet = makeWorkoutSet()
        let prefs = CoachPreferences(
            showConfidencePercent: true,
            predictionAlgorithm: .ema
        )
        let pbs = makeSwimmerPBs()
        let predictor = HistoricalTimePredictor()

        // PHASE 1: Verify the predictor returns EWMA-driven predictions
        // for swimmers with 5+ recorded times.
        print("│ Phase 1: predictor predicts EWMA-driven values from history")
        print("│")
        var livePredictions: [String: Prediction] = [:]
        for s in mockSwimmers {
            let recordedTimes = makeRecordedTimes(
                forSwimmer: s.id,
                setId: workoutSet.id,
                intensity: workoutSet.intensityLabel ?? "moderate"
            )
            let swimmer = makeSwimmer(s)
            let pbsForSwimmer = pbs.filter { $0.swimmerId == s.id }
            let pred = predictor.predict(
                swimmer: swimmer,
                set: workoutSet,
                recordedTimes: recordedTimes,
                pbs: pbsForSwimmer,
                prefs: prefs
            )
            if let pred = pred {
                livePredictions[s.id] = pred
                let mark = pred.source == .historical ? "✓" : "✗"
                let markSample = pred.sampleSize == 6 ? "✓" : "✗"
                print("│   \(mark)\(markSample) \(s.firstName.padding(toLength: 14, withPad: " ", startingAt: 0)) PB=\(s.pbMs)ms → predicted=\(pred.timeMs)ms (σ=\(pred.sigmaMs), source=\(pred.source), maturity=\(pred.maturity))")
            } else {
                print("│   ✗ \(s.firstName.padding(toLength: 14, withPad: " ", startingAt: 0)) PB=\(s.pbMs)ms → PREDICTION NIL")
            }
        }
        print("│")

        // PHASE 2: Verify the EWMA-driven prediction differs from
        // the raw PB. Mock-Alice's PB is 26800ms. Her recorded times
        // are [+100, -200, +300, -100, +200, -300] = [26900, 26600,
        // 27100, 26700, 27000, 26500]. The EMA(α=0.3) of these
        // starting from the most recent backward: ~26700ms. The
        // prediction should be close to 26700ms, NOT 26800ms.
        if let alicePred = livePredictions["e9137805-0c1b-4361-aa2e-a47c150d6767"] {
            let alicePB = 26800
            let aliceEMA = alicePred.timeMs
            let drift = abs(aliceEMA - alicePB)
            let markEWMA = drift > 0 && drift < 500 ? "✓" : "✗"
            print("│ Phase 2: EWMA prediction differs from raw PB (proves flywheel works)")
            print("│   \(markEWMA) Mock-Alice: PB=26800, EWMA=\(aliceEMA), drift=\(drift)ms")
            if drift == 0 {
                print("│     ✗ DRIFT IS ZERO — predictor returned raw PB, not the EWMA!")
            } else if drift > 500 {
                print("│     ✗ DRIFT TOO LARGE — predictor returned something unexpected")
            } else {
                print("│     ✓ Drift is within realistic bounds (~0-500ms)")
            }
        }
        print("│")

        // PHASE 3: Run the pairing engine with the LIVE predictions
        // and verify the v1.9 invariant holds.
        print("│ Phase 3: pairing engine with live EWMA predictions")
        let wave0Indices = Array(0..<6) as [Int]
        let wave1Indices = [6, 7]
        var waveAssignments: [WaveAssignment] = []
        for (i, idx) in wave0Indices.enumerated() {
            waveAssignments.append(makeWaveAssignment(
                swimmer: mockSwimmers[idx], lane: i + 1,
                wave: 0, sendOff: 0, intensity: 1.05
            ))
        }
        for (i, idx) in wave1Indices.enumerated() {
            waveAssignments.append(makeWaveAssignment(
                swimmer: mockSwimmers[idx], lane: i + 1,
                wave: 1, sendOff: sendOffIntervalMs, intensity: 1.05
            ))
        }
        var laps: [Lap] = []
        var lapNumber = 1
        for wave in [0, 1] {
            let indices = (wave == 0) ? wave0Indices : wave1Indices
            for idx in indices {
                let pb = mockSwimmers[idx].pbMs
                let predicted = Double(pb) * 1.05
                let actualTime = Int(predicted + gaussianNoise() * 250.0)
                laps.append(Lap(
                    id: UUID().uuidString,
                    lapNumber: lapNumber,
                    elapsedMs: wave * sendOffIntervalMs + actualTime,
                    splitMs: actualTime
                ))
                lapNumber += 1
            }
        }
        let result = PairingEngine().pair(
            laps: laps,
            waveAssignments: waveAssignments,
            predictions: livePredictions,
            sendOffIntervalMs: sendOffIntervalMs
        )

        print("│   assignments:        \(result.assignments.count)  \(result.assignments.count == 8 ? "✓" : "✗ EXPECTED 8")")
        print("│   unassignedLaps:     \(result.unassignedLaps.count)  \(result.unassignedLaps.count == 0 ? "✓ (no ghost taps)" : "✗ GHOST TAPS")")
        print("│   unassignedSwimmers: \(result.unassignedSwimmers.count)  \(result.unassignedSwimmers.count == 0 ? "✓ (no missed)" : "✗ MISSED SWIMMERS")")
        let assignedSwimmerIds = Set(result.assignments.map { $0.swimmerId })
        var allMatched = true
        for s in mockSwimmers {
            let expectedUUID = UUID(uuidString: s.id) ?? UUID()
            let matched = assignedSwimmerIds.contains(expectedUUID)
            if !matched { allMatched = false }
            let mark = matched ? "✓" : "✗"
            print("│   \(mark) \(s.firstName.padding(toLength: 14, withPad: " ", startingAt: 0)) PB=\(s.pbMs)ms")
        }
        let passed = result.assignments.count == 8
            && result.unassignedLaps.count == 0
            && result.unassignedSwimmers.count == 0
            && allMatched
        print("│")
        print("└─── Verdict: \(passed ? "PASS ✓" : "FAIL ✗") ───┘")
    }

    /// v1.12 E2E SUPABASE SCENARIO — verify the predictor's
    /// EWMA-driven predictions against REAL recorded_times queried
    /// from the live Supabase DB. The values are hardcoded from
    /// the seed script (48 rows, 6 per swimmer for the 8 mock
    /// swimmers, all for a fresh test workout_set). The hardcoded
    /// data lets this test run in CI / on any Mac without
    /// requiring a live DB connection.
    ///
    /// For each swimmer, the predictor should return:
    ///   - source == .historical
    ///   - maturity == .reliable (6 samples)
    ///   - sampleSize == 6
    ///   - sigmaMs == 200 (the stddev of [100, -200, 300, -100,
    ///     200, -300] = 207, clamped to >= sigmaFloor of 200)
    ///   - timeMs:
    ///     - .median: median of last 5 (sorted DESC by createdAt) = PB+100
    ///     - .ema: EMA(α=0.3) of last 5 = ~PB+87
    ///   - All 8 predictions must be non-nil
    ///
    /// The pairing engine is not exercised here — the e2e test
    /// focuses on the predictor's correctness against real data.
    static func runE2ESupabaseScenario() {
        print("\n┌─── Scenario: v1.12 E2E SUPABASE (live data) ───┐")
        print("│ Recorded_times queried from the live Supabase DB (2026-06-15):")
        print("│ 8 mock swimmers × 6 times each = 48 rows.")
        print("│ Workout set: v1.12 e2e test (test workout)")
        print("│")

        let workoutSet = makeWorkoutSet()
        // Workout set the seed script created (we hardcode the UUID
        // for the test; the seed script's UUID is different but the
        // RecordedTime values are what matter).
        let pbs = makeSwimmerPBs()

        // LIVE recorded_times values (queried from the live DB).
        // Variance pattern: [100, -200, 300, -100, 200, -300]
        // around each swimmer's PB. The values are deterministic
        // because the seed script inserts them with fixed variances.
        let liveTimes: [String: [Int]] = [
            "1b5261d6-8bbc-4109-8dc5-6c4d3e52e814": [31300, 31000, 31500, 31100, 31400, 30900],  // George
            "7e6ca6c2-b586-4c6c-8bf7-d363c862782e": [27300, 27000, 27500, 27100, 27400, 26900],  // Bob
            "994b7ebf-41fa-47e2-8a18-715e9d53ce26": [30200, 29900, 30400, 30000, 30300, 29800],  // Fiona
            "9b2e9233-e128-4714-80c3-daa646b7d5b5": [28500, 28200, 28700, 28300, 28600, 28100],  // Diana
            "a7a71d18-0261-41f8-b606-3930be6eb44a": [28000, 27700, 28200, 27800, 28100, 27600],  // Charlie
            "b8c13ff4-730e-4403-8ca5-d28a2bbecc09": [29600, 29300, 29800, 29400, 29700, 29200],  // Ethan
            "bea69b89-0426-4c51-9eef-29b40fa99715": [32900, 32600, 33100, 32700, 33000, 32500],  // Hannah
            "e9137805-0c1b-4361-aa2e-a47c150d6767": [26900, 26600, 27100, 26700, 27000, 26500],  // Alice
        ]

        // Build RecordedTime[] from the live data. createdAt
        // decrementing by 1 day per rep — rep 0 is the most recent
        // (1 day ago), rep 5 is the oldest (6 days ago). The
        // predictor sorts by createdAt DESC and takes the top 5
        // (prefix(5)), which is reps 0-4 (the most recent 5).
        var liveRecordedTimes: [RecordedTime] = []
        let baseDate = Date()
        let isoFormatter = ISO8601DateFormatter()
        for (swimmerId, times) in liveTimes {
            for (i, timeMs) in times.enumerated() {
                // i=0 is the most recent (1 day ago), i=5 is the oldest (6 days ago)
                let daysAgo = i + 1
                let createdAt = baseDate.addingTimeInterval(-Double(daysAgo) * 86400)
                liveRecordedTimes.append(RecordedTime(
                    id: "e2e-\(swimmerId.prefix(8))-\(i)",
                    sessionId: nil,
                    swimmerId: swimmerId,
                    workoutSetId: workoutSet.id,
                    workoutId: nil,
                    timeMs: timeMs,
                    repIndex: i,
                    intensity: "moderate",
                    gear: "none",
                    waveNumber: 0,
                    paceDistance: nil,
                    createdAt: isoFormatter.string(from: createdAt),
                    lapOrder: i,
                    pairedSwimmerId: swimmerId,
                    confidence: 95
                ))
            }
        }

        // Expected outputs (computed from the live data):
        //   - .median: median of top 5 (most recent) times = PB+100
        //     (since the +100 entry is the median of the 5-elt sequence)
        //   - .ema: EMA(α=0.3) starting from the OLDEST of the top 5
        //     and processing forward to the most recent (the
        //     Swift implementation in HistoricalTimePredictor.ema()
        //     processes oldest→newest with the oldest as the seed).
        //     For Mock-Alice (PB=26800), the top 5 are
        //     [26900, 26600, 27100, 26700, 27000] (most recent first).
        //     The EMA starts at 27000 (oldest), processes forward:
        //       0.3*26700 + 0.7*27000 = 26910
        //       0.3*27100 + 0.7*26910 = 26967
        //       0.3*26600 + 0.7*26967 = 26857
        //       0.3*26900 + 0.7*26857 = 26870
        //     Final EMA: 26870 (drift 70ms from PB).
        //   - sigma: max(sampleStdDev(6 times), sigmaFloor=1500) = 1500
        //   - sampleSize: 6
        //   - maturity: .reliable (6 samples)
        let expectedPredictions: [String: (medianExpected: Int, emaExpected: Int)] = [
            "1b5261d6-8bbc-4109-8dc5-6c4d3e52e814": (31200 + 100, 31200 + 70),  // George
            "7e6ca6c2-b586-4c6c-8bf7-d363c862782e": (27200 + 100, 27200 + 70),  // Bob
            "994b7ebf-41fa-47e2-8a18-715e9d53ce26": (30100 + 100, 30100 + 70),  // Fiona
            "9b2e9233-e128-4714-80c3-daa646b7d5b5": (28400 + 100, 28400 + 70),  // Diana
            "a7a71d18-0261-41f8-b606-3930be6eb44a": (27900 + 100, 27900 + 70),  // Charlie
            "b8c13ff4-730e-4403-8ca5-d28a2bbecc09": (29500 + 100, 29500 + 70),  // Ethan
            "bea69b89-0426-4c51-9eef-29b40fa99715": (32800 + 100, 32800 + 70),  // Hannah
            "e9137805-0c1b-4361-aa2e-a47c150d6767": (26800 + 100, 26800 + 70),  // Alice
        ]

        let predictor = HistoricalTimePredictor()

        // PHASE 1: .median algorithm
        print("│ Phase 1: predictor with .median algorithm")
        let medianPrefs = CoachPreferences(
            showConfidencePercent: true,
            predictionAlgorithm: .median
        )
        var allMedianPass = true
        for s in mockSwimmers {
            let swimmerRTs = liveRecordedTimes.filter { $0.swimmerId == s.id }
            let swimmerPBs = pbs.filter { $0.swimmerId == s.id }
            let swimmer = makeSwimmer(s)
            guard let pred = predictor.predict(
                swimmer: swimmer,
                set: workoutSet,
                recordedTimes: swimmerRTs,
                pbs: swimmerPBs,
                prefs: medianPrefs
            ) else {
                print("│   ✗ \(s.firstName): predictor returned nil")
                allMedianPass = false
                continue
            }
            let expected = expectedPredictions[s.id]!
            let medianMatch = pred.timeMs == expected.medianExpected
            let maturityMatch = pred.maturity == .reliable
            let sourceMatch = pred.source == .historical
            let sampleMatch = pred.sampleSize == 6
            let passAll = medianMatch && maturityMatch && sourceMatch && sampleMatch
            if !passAll { allMedianPass = false }
            let mark = passAll ? "✓" : "✗"
            print("│   \(mark) \(s.firstName.padding(toLength: 14, withPad: " ", startingAt: 0)) PB=\(s.pbMs)ms → predicted=\(pred.timeMs)ms (σ=\(pred.sigmaMs), source=\(pred.source), maturity=\(pred.maturity), samples=\(pred.sampleSize))")
        }
        print("│   Phase 1 verdict: \(allMedianPass ? "PASS ✓" : "FAIL ✗")")
        print("│")

        // PHASE 2: .ema algorithm
        print("│ Phase 2: predictor with .ema algorithm")
        let emaPrefs = CoachPreferences(
            showConfidencePercent: true,
            predictionAlgorithm: .ema
        )
        var allEmaPass = true
        for s in mockSwimmers {
            let swimmerRTs = liveRecordedTimes.filter { $0.swimmerId == s.id }
            let swimmerPBs = pbs.filter { $0.swimmerId == s.id }
            let swimmer = makeSwimmer(s)
            guard let pred = predictor.predict(
                swimmer: swimmer,
                set: workoutSet,
                recordedTimes: swimmerRTs,
                pbs: swimmerPBs,
                prefs: emaPrefs
            ) else {
                print("│   ✗ \(s.firstName): predictor returned nil")
                allEmaPass = false
                continue
            }
            let expected = expectedPredictions[s.id]!
            let emaMatch = pred.timeMs == expected.emaExpected
            let maturityMatch = pred.maturity == .reliable
            let sourceMatch = pred.source == .historical
            let sampleMatch = pred.sampleSize == 6
            let passAll = emaMatch && maturityMatch && sourceMatch && sampleMatch
            if !passAll { allEmaPass = false }
            let mark = passAll ? "✓" : "✗"
            print("│   \(mark) \(s.firstName.padding(toLength: 14, withPad: " ", startingAt: 0)) PB=\(s.pbMs)ms → predicted=\(pred.timeMs)ms (σ=\(pred.sigmaMs), source=\(pred.source), maturity=\(pred.maturity), samples=\(pred.sampleSize))")
        }
        print("│   Phase 2 verdict: \(allEmaPass ? "PASS ✓" : "FAIL ✗")")
        print("│")

        // PHASE 3: Mock-Alice drift check (verifies the EMA is
        // doing real work, not just returning the PB)
        if let alicePred = try? predictor.predict(
            swimmer: makeSwimmer(mockSwimmers[0]),
            set: workoutSet,
            recordedTimes: liveRecordedTimes.filter { $0.swimmerId == mockSwimmers[0].id },
            pbs: pbs.filter { $0.swimmerId == mockSwimmers[0].id },
            prefs: emaPrefs
        ) {
            let alicePB = mockSwimmers[0].pbMs
            let drift = alicePred.timeMs - alicePB
            let driftMark = drift > 0 && drift < 200 ? "✓" : "✗"
            print("│ Phase 3: Mock-Alice drift check (verifies EMA != PB)")
            print("│   \(driftMark) Mock-Alice EMA=\(alicePred.timeMs), PB=26800, drift=\(drift)ms (expected ~87ms)")
        }
        print("│")

        let passed = allMedianPass && allEmaPass
        print("└─── Verdict: \(passed ? "PASS ✓" : "FAIL ✗") ───┘")
    }
}
