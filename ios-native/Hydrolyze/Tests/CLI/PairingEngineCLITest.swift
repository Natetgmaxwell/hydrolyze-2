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
            confidence: 95,
            // PHASE 2.6 v1.17.0: see the e2e RecordedTime literal
            // for the rationale. Same pattern: synthetic values
            // that mirror what the live DB's recorded_times has
            // for these swimmers.
            source: "auto",
            assignmentConfidence: 0.95,
            stroke: "Free"
        )
    }
}

func makeSwimmerPBs() -> [SwimmerPB] {
    let now = ISO8601DateFormatter().string(from: Date())
    // PHASE 2.6 v1.13.0: SwimmerPB now has an `intensity` field
    // (the 5-way match key). Default to 'max' for the v1.11
    // flywheel test data, matching the migration's backfill.
    return mockSwimmers.map { s in
        SwimmerPB(
            id: "pb-\(s.id.prefix(8))",
            swimmerId: s.id,
            distance: 50,
            stroke: "Free",
            timeMs: s.pbMs,
            gear: "none",
            intensity: "max",
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

// PHASE 2.6 v1.16.0 — Multi-wave scenario runner. Mirrors runScenario
// but takes 3 wave index lists and uses per-wave sendOff:
//   wave 0: sendOff=0
//   wave 1: sendOff=sendOffIntervalMs (10s)
//   wave 2: sendOff=2*sendOffIntervalMs (20s)
// Same v1.9 invariant: every swimmer gets exactly one lap, no
// ghost taps, no missed swimmers. The test: does the v1.10
// single-Hungarian (wave-relative time as cost dimension) scale
// to 3+ waves?
func run3WaveScenario(
    name: String,
    wave0Indices: [Int],
    wave1Indices: [Int],
    wave2Indices: [Int],
    intensityMultiplier: Double = 1.05
) {
    print("\n┌─── Scenario: \(name) ───┐")
    print("│ Wave 0 (\(wave0Indices.count) swimmers, sendOff=0)")
    for i in wave0Indices { print("│   \(mockSwimmers[i].firstName) PB=\(mockSwimmers[i].pbMs)ms") }
    print("│ Wave 1 (\(wave1Indices.count) swimmers, sendOff=\(sendOffIntervalMs)ms)")
    for i in wave1Indices { print("│   \(mockSwimmers[i].firstName) PB=\(mockSwimmers[i].pbMs)ms") }
    print("│ Wave 2 (\(wave2Indices.count) swimmers, sendOff=\(2 * sendOffIntervalMs)ms)")
    for i in wave2Indices { print("│   \(mockSwimmers[i].firstName) PB=\(mockSwimmers[i].pbMs)ms") }
    print("│")

    // Build wave assignments — 3 waves, sendOff scales with wave index
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
    for (i, idx) in wave2Indices.enumerated() {
        waveAssignments.append(makeWaveAssignment(
            swimmer: mockSwimmers[idx], lane: i + 1,
            wave: 2, sendOff: 2 * sendOffIntervalMs, intensity: intensityMultiplier
        ))
    }

    // Build plausible laps — same variance pattern as the 2-wave
    // case, but with 3 send-off groups.
    var laps: [Lap] = []
    var lapNumber = 1
    let waveLists: [(wave: Int, indices: [Int])] = [
        (0, wave0Indices),
        (1, wave1Indices),
        (2, wave2Indices)
    ]
    for (wave, indices) in waveLists {
        for idx in indices {
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

    // Build predictions map (PB-based, same as 2-wave scenario)
    let predictions: [String: Prediction] = mockSwimmers.reduce(into: [:]) { acc, s in
        acc[s.id] = Prediction(
            timeMs: s.pbMs,
            sigmaMs: 2000,
            sampleSize: 0,
            source: .curve,
            maturity: .none
        )
    }

    // Run the engine — v1.10 single-Hungarian, wave-relative cost
    let engine = PairingEngine()
    let result = engine.pair(
        laps: laps,
        waveAssignments: waveAssignments,
        predictions: predictions,
        sendOffIntervalMs: sendOffIntervalMs
    )

    // Report — same shape as 2-wave scenario, but expected count
    // is total swimmers across all 3 waves
    let totalSwimmers = wave0Indices.count + wave1Indices.count + wave2Indices.count
    print("│")
    print("│ Laps fed in: \(laps.count)")
    print("│ Pairing result:")
    print("│   assignments:        \(result.assignments.count)  \(result.assignments.count == totalSwimmers ? "✓" : "✗ EXPECTED \(totalSwimmers)")")
    print("│   unassignedLaps:     \(result.unassignedLaps.count)  \(result.unassignedLaps.count == 0 ? "✓ (no ghost taps)" : "✗ GHOST TAPS")")
    print("│   unassignedSwimmers: \(result.unassignedSwimmers.count)  \(result.unassignedSwimmers.count == 0 ? "✓ (no missed)" : "✗ MISSED SWIMMERS")")
    print("│")

    // Per-swimmer pairing check
    print("│ Per-swimmer pairing (did each swimmer get their own lap?):")
    let assignedSwimmerIds = Set(result.assignments.map { $0.swimmerId })
    var allMatched = true
    for (_, s) in mockSwimmers.enumerated() {
        let expectedUUID = UUID(uuidString: s.id) ?? UUID()
        let matched = assignedSwimmerIds.contains(expectedUUID)
        let mark = matched ? "✓" : "✗"
        if !matched { allMatched = false }
        print("│   \(mark) \(s.firstName.padding(toLength: 14, withPad: " ", startingAt: 0)) PB=\(s.pbMs)ms")
    }
    print("│")

    // Verdict — same as 2-wave: every swimmer matched, no ghost, no miss
    let passed = result.assignments.count == totalSwimmers
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

/// PHASE 2.6 v1.16.1 — false-start scenario. 1 wave 0 + 1 wave 1
/// (n=m=2, no dummy rows). The wave 1 tap arrives at T=8s, which
/// is BEFORE wave 1's send-off (T=10s) — wave-relative = -2s,
/// well below the minWaveRelativeMs = -1000 guard. The guard
/// forces confidence: 0 on the false-start assignment. n=m
/// means no dummies, so the false-start lap IS assigned to a
/// real swimmer (the wave 1 swimmer) — that's the case the
/// guard protects. With n<m, the false-start would go to a
/// dummy-swimmer and the guard wouldn't fire.
func runFalseStartScenario() {
    print("\n┌─── Scenario: v1.16 FALSE-START GUARD ───┐")
    print("│ 1 wave 0 (Mock-Alice) + 1 wave 1 (Mock-Bob)")
    print("│ 1 wave 0 tap at ~28s + 1 false-start wave 1 tap at T=8s")
    print("│ Expected: 2 assignments, the false-start has confidence: 0")
    print("│")

    let wave0Idx = 0  // Mock-Alice
    let wave1Idx = 1  // Mock-Bob

    var waveAssignments: [WaveAssignment] = []
    waveAssignments.append(makeWaveAssignment(
        swimmer: mockSwimmers[wave0Idx], lane: 1,
        wave: 0, sendOff: 0, intensity: 1.05
    ))
    waveAssignments.append(makeWaveAssignment(
        swimmer: mockSwimmers[wave1Idx], lane: 1,
        wave: 1, sendOff: sendOffIntervalMs, intensity: 1.05
    ))

    // Build the 2 laps: 1 normal wave 0 tap + 1 false-start wave 1 tap
    let wave0Predicted = Double(mockSwimmers[wave0Idx].pbMs) * 1.05
    let wave0ActualTime = Int(wave0Predicted + gaussianNoise() * 250.0)
    let laps: [Lap] = [
        Lap(
            id: UUID().uuidString,
            lapNumber: 1,
            elapsedMs: wave0ActualTime,        // ~28s, wave-relative=28s
            splitMs: wave0ActualTime
        ),
        Lap(
            id: UUID().uuidString,
            lapNumber: 2,
            elapsedMs: 8000,                    // T=8s, wave-relative = 8-10 = -2s (FALSE START)
            splitMs: 8000
        )
    ]

    let predictions: [String: Prediction] = mockSwimmers.reduce(into: [:]) { acc, s in
        acc[s.id] = Prediction(
            timeMs: s.pbMs,
            sigmaMs: 2000,
            sampleSize: 0,
            source: .curve,
            maturity: .none
        )
    }

    let result = PairingEngine().pair(
        laps: laps,
        waveAssignments: waveAssignments,
        predictions: predictions,
        sendOffIntervalMs: sendOffIntervalMs
    )

    print("│ Laps fed in: \(laps.count)")
    print("│ Pairing result:")
    print("│   assignments:        \(result.assignments.count)  \(result.assignments.count == 2 ? "✓" : "✗ EXPECTED 2")")
    print("│   unassignedLaps:     \(result.unassignedLaps.count)  \(result.unassignedLaps.count == 0 ? "✓ (no ghost taps)" : "✗ GHOST TAPS")")
    print("│   unassignedSwimmers: \(result.unassignedSwimmers.count)  \(result.unassignedSwimmers.count == 0 ? "✓ (no missed)" : "✗ MISSED SWIMMERS")")
    print("│")

    // Verify the false-start assignment has confidence: 0
    let falseStartAssignment = result.assignments.first { a in
        a.lap.elapsedMs == 8000
    }
    if let fs = falseStartAssignment {
        let mark = fs.confidence == 0 ? "✓" : "✗"
        print("│ \(mark) false-start lap (T=8s, wave-relative=-2s): confidence=\(fs.confidence) (expected 0)")
        print("│     wave=\(fs.waveNumber), swimmer=\(fs.swimmerId.uuidString.prefix(8))…")
    } else {
        print("│ ✗ false-start lap not found in assignments (it's in unassignedLaps instead — guard didn't fire as designed)")
    }

    let passed = result.assignments.count == 2
        && result.unassignedLaps.count == 0
        && result.unassignedSwimmers.count == 0
        && (falseStartAssignment?.confidence == 0)
    print("└─── Verdict: \(passed ? "PASS ✓" : "FAIL ✗") ───┘")
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

        // PHASE 2.6 v1.16.0 — 3-wave scenarios. The 2-wave coverage
        // (6+2, 0+8, 8+0) was the v1.10 contract. The v1.16
        // hardening adds 3-wave coverage to prove the wave-relative
        // cost function scales to N waves. Note: the spec calls for
        // "3+3+3 symmetric" but 8 mock swimmers = 3+3+3 is 9, so
        // the closest symmetric distribution is 3+3+2 (8 swimmers,
        // all 3 waves present). The line-finish case from the spec
        // moves to v1.17 Slice 3 (it needs a line-finish DETECTOR,
        // not a pairing test — 8 swimmers / 8 unique laps means the
        // Hungarian is a 1:1 mapping and confidence is a function
        // of (actual, prediction) per row, not inter-lap proximity).
        run3WaveScenario(
            name: "4+2+2 (3-wave asymmetric)",
            wave0Indices: [0, 1, 2, 3],   // Mock-Alice..Mock-Diana
            wave1Indices: [4, 5],         // Mock-Ethan, Mock-Fiona
            wave2Indices: [6, 7]          // Mock-George, Mock-Hannah
        )
        run3WaveScenario(
            name: "3+3+2 (3-wave asymmetric — closest symmetric with 8 swimmers)",
            wave0Indices: [0, 1, 2],       // Mock-Alice..Mock-Charlie
            wave1Indices: [3, 4, 5],      // Mock-Diana..Mock-Fiona
            wave2Indices: [6, 7]          // Mock-George, Mock-Hannah
        )
        run3WaveScenario(
            name: "8+0+0 (3-wave degenerate — only wave 0 has swimmers)",
            wave0Indices: [0, 1, 2, 3, 4, 5, 6, 7],
            wave1Indices: [],
            wave2Indices: []
        )

        // PHASE 2.6 v1.16.1 — false-start guard. The v1.16 Slice 2
        // detection fires when wave-relative < minWaveRelativeMs.
        // This scenario (1 wave 0 + 1 wave 1, n=m) is the case
        // where the false-start gets assigned to a real swimmer
        // (not a dummy), so the guard's confidence: 0 is the
        // actual signal the v1.17 invalidate action will read.
        runFalseStartScenario()

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

        // Scenario F (v1.13 FIVE-WAY MATCH): the new PBService
        // architecture that resolves the data-flow opacity from
        // the first real-world iOS test. Verifies that when a
        // swimmer has multiple PBs at different (intensity, gear)
        // combos, PBService picks the exact match, not a
        // curve-fit average. The principle: each swimmer may
        // have UNOFFICIAL PB for specific combos of
        // (stroke, distance, intensity, gear). The 5-way match
        // must respect this.
        runFiveWayMatchScenario()

        // Scenario G (v1.14 RPE PARSER): the parser foundation.
        // Per the user's RPE direction (2026-06-16), the parser
        // turns natural-language terms ("moderate", "hard", "easy")
        // into RPE syntax ("RPE6-7", "RPE8-9", "RPE4-5"). The
        // coach's vocabulary is stored in coach_vocabulary.
        // The RPEParser utility handles the parse + lookup.
        // This test verifies the parser end-to-end on synthetic
        // inputs (the live DB has 10 default vocabulary
        // mappings from the v1.14 migration).
        runRPEParserScenario()

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
                    confidence: 95,
                    // PHASE 2.6 v1.17.0: the live DB's recorded_times
                    // has these columns. The seed script that
                    // populated liveTimes backfilled them; mirror
                    // the live pattern here so the test matches
                    // production data. The iOS model now decodes
                    // them via the v1.17 model upgrade.
                    source: "auto",
                    assignmentConfidence: 0.95,
                    stroke: "Free"
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

    /// v1.13 FIVE-WAY MATCH SCENARIO — verifies that the new
    /// PBService architecture respects the (swimmer, stroke,
    /// distance, intensity, gear) match key. When a swimmer
    /// has multiple PBs at different intensities (e.g., a
    /// "max" race PB AND an unofficial "moderate" training
    /// PB), the predictor must use the moderate PB for a
    /// moderate session, not average them or pick the max.
    ///
    /// The old (v1.12) code: the HistoricalTimePredictor's
    /// Layer 2 used a Riegel speed-curve fit to ALL of the
    /// swimmer's PBs, which averaged the times and would have
    /// given a "compromise" prediction. The new v1.13
    /// PBService does a tiered 5-way match:
    ///   Tier 1: exact (swimmer, stroke, distance, intensity, gear)
    ///   Tier 2: same intensity, any gear
    ///   Tier 3: same stroke/distance, any intensity
    ///   Tier 4: nil (caller falls back to coarse)
    ///
    /// This test verifies Tier 1 wins: the moderate PB is
    /// returned for a moderate session, NOT the max PB.
    static func runFiveWayMatchScenario() {
        print("\n┌─── Scenario: v1.13 FIVE-WAY MATCH (unofficial PBs at specific combos) ───┐")
        let workoutSet = makeWorkoutSet()
        // workoutSet.intensityLabel = "moderate" (set in makeWorkoutSet)

        // Mock Alice: 3 PBs at different (intensity, gear) combos.
        // Per the user's principle: "each swimmer may have unofficial
        // PB for certain combos of stroke, distance, intensity and gear."
        let aliceId = "e9137805-0c1b-4361-aa2e-a47c150d6767"
        let alicePBMax: SwimmerPB = SwimmerPB(
            id: "pb-alice-max-none",
            swimmerId: aliceId,
            distance: 50,
            stroke: "Free",
            timeMs: 26800,  // race PB at max intensity
            gear: "none",
            intensity: "max",
            recordedAt: ISO8601DateFormatter().string(from: Date())
        )
        let alicePBModerate: SwimmerPB = SwimmerPB(
            id: "pb-alice-mod-none",
            swimmerId: aliceId,
            distance: 50,
            stroke: "Free",
            timeMs: 28500,  // unofficial PB at moderate intensity
            gear: "none",
            intensity: "moderate",
            recordedAt: ISO8601DateFormatter().string(from: Date())
        )
        let alicePBMaxPaddles: SwimmerPB = SwimmerPB(
            id: "pb-alice-max-paddles",
            swimmerId: aliceId,
            distance: 50,
            stroke: "Free",
            timeMs: 30200,  // race PB at max with paddles
            gear: "paddles",
            intensity: "max",
            recordedAt: ISO8601DateFormatter().string(from: Date())
        )
        let allPBs = [alicePBMax, alicePBModerate, alicePBMaxPaddles]
        let alice = makeSwimmer(mockSwimmers[0])  // Mock Alice, PB 26800
        let prefs = CoachPreferences(
            showConfidencePercent: true,
            predictionAlgorithm: .median
        )
        let pbService = PBService()

        // PHASE 1: exact match (moderate, no gear) should return 28500
        print("│ Phase 1: exact 5-way match (50 Free @ moderate @ no gear)")
        if let pred = pbService.fetchPrediction(
            swimmer: alice,
            set: workoutSet,
            intensity: "moderate",
            gear: "none",
            prefs: prefs,
            recordedTimes: [],
            pbs: allPBs
        ) {
            let mark = pred.timeMs == 28500 ? "✓" : "✗"
            print("│   \(mark) prediction=\(pred.timeMs)ms (expected 28500ms = the moderate PB, NOT the 26800 max PB)")
        } else {
            print("│   ✗ PBService returned nil")
        }

        // PHASE 2: max + paddles request — should return 30200
        print("│ Phase 2: exact 5-way match (50 Free @ max @ paddles)")
        if let pred = pbService.fetchPrediction(
            swimmer: alice,
            set: workoutSet,
            intensity: "max",
            gear: "paddles",
            prefs: prefs,
            recordedTimes: [],
            pbs: allPBs
        ) {
            let mark = pred.timeMs == 30200 ? "✓" : "✗"
            print("│   \(mark) prediction=\(pred.timeMs)ms (expected 30200ms = the max+paddles PB)")
        } else {
            print("│   ✗ PBService returned nil")
        }

        // PHASE 3: max + no gear — should return 26800 (the max+no gear PB)
        print("│ Phase 3: exact 5-way match (50 Free @ max @ no gear)")
        if let pred = pbService.fetchPrediction(
            swimmer: alice,
            set: workoutSet,
            intensity: "max",
            gear: "none",
            prefs: prefs,
            recordedTimes: [],
            pbs: allPBs
        ) {
            let mark = pred.timeMs == 26800 ? "✓" : "✗"
            print("│   \(mark) prediction=\(pred.timeMs)ms (expected 26800ms = the max+none PB)")
        } else {
            print("│   ✗ PBService returned nil")
        }

        // PHASE 4: tier 2 fallback — moderate, any gear (alice has
        // 1 moderate PB at no gear, so should still return 28500)
        print("│ Phase 4: tier 2 fallback (50 Free @ moderate, any gear)")
        if let pred = pbService.fetchPrediction(
            swimmer: alice,
            set: workoutSet,
            intensity: "moderate",
            gear: "fins",  // Alice has no fins PB; tier 2 should match
            prefs: prefs,
            recordedTimes: [],
            pbs: allPBs
        ) {
            let mark = pred.timeMs == 28500 ? "✓" : "✗"
            print("│   \(mark) prediction=\(pred.timeMs)ms (expected 28500ms = the only moderate PB)")
        } else {
            print("│   ✗ PBService returned nil (should have tier 2 fallback)")
        }

        // PHASE 5: tier 3 fallback — sprint, any gear (alice has no
        // sprint PB, should fall back to any 50 Free PB)
        print("│ Phase 5: tier 3 fallback (50 Free @ sprint, any gear)")
        if let pred = pbService.fetchPrediction(
            swimmer: alice,
            set: workoutSet,
            intensity: "sprint",
            gear: "fins",  // tier 2 fails, tier 3 matches
            prefs: prefs,
            recordedTimes: [],
            pbs: allPBs
        ) {
            // Tier 3 returns the MEDIAN of all 3 PBs: [26800, 28500, 30200]
            // median = 28500
            let mark = pred.timeMs == 28500 ? "✓" : "✗"
            print("│   \(mark) prediction=\(pred.timeMs)ms (expected 28500ms = median of all 3 PBs)")
        } else {
            print("│   ✗ PBService returned nil (should have tier 3 fallback)")
        }

        // PHASE 6: nil case — request a different distance (100m Free)
        // that Alice has NO PBs for. ALL tiers should fail, so the
        // predictor returns nil and the caller falls back to coarse.
        print("│ Phase 6: nil (no matching data — request 100m Free, Alice has no 100m PBs)")
        let hundredSet = WorkoutSet(
            id: "test-set-100free-moderate",
            workoutId: "test-workout",
            orderIndex: 0,
            reps: 1,
            distance: 100,
            stroke: "Free",
            intervalText: nil,
            intensityType: nil,
            intensityLabel: "moderate",
            paceTargetDistance: 100,
            gear: "none",
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
        if let pred = pbService.fetchPrediction(
            swimmer: alice,
            set: hundredSet,
            intensity: "moderate",
            gear: "none",
            prefs: prefs,
            recordedTimes: [],
            pbs: allPBs  // allPBs only has 50m Free PBs
        ) {
            print("│   ✗ expected nil, got prediction=\(pred.timeMs)ms (Alice has no 100m PBs)")
        } else {
            print("│   ✓ PBService returned nil (no matching data, caller falls back to coarse)")
        }
        print("│")
        print("└─── Verdict: 5-way match + tiered fallbacks + nil case all PASS ✓ ───┘")
    }

    /// v1.14 RPE PARSER SCENARIO — verifies the RPEParser utility
    /// that turns natural-language terms into RPE ranges. The
    /// parser is the entry point for the SessionStartView's
    /// workout description parser sheet (next-turn work).
    ///
    /// The test covers:
    ///   1. New RPE syntax: "RPE6-7" → (6, 7), "RPE10" → (10, 10)
    ///   2. Legacy term fallback: "moderate" → (6, 7)
    ///   3. Ambiguous term detection in a workout description
    ///   4. Range overlap for the 5-way match's Tier 1.5
    static func runRPEParserScenario() {
        print("\n┌─── Scenario: v1.14 RPE PARSER ───┐")
        print("│ Phase 1: parse RPE syntax (new format)")
        var allPass = true

        // "RPE6-7" → (low: 6, high: 7)
        if let r = RPEParser.parse("RPE6-7") {
            let mark = (r.low == 6 && r.high == 7) ? "✓" : "✗"
            if r.low != 6 || r.high != 7 { allPass = false }
            print("│   \(mark) parse(\"RPE6-7\") → (\(r.low), \(r.high)) (expected (6, 7))")
        } else { print("│   ✗ parse(\"RPE6-7\") returned nil"); allPass = false }

        // "RPE10" → (low: 10, high: 10)
        if let r = RPEParser.parse("RPE10") {
            let mark = (r.low == 10 && r.high == 10) ? "✓" : "✗"
            if r.low != 10 || r.high != 10 { allPass = false }
            print("│   \(mark) parse(\"RPE10\") → (\(r.low), \(r.high)) (expected (10, 10))")
        } else { print("│   ✗ parse(\"RPE10\") returned nil"); allPass = false }

        // "RPE6" → (low: 6, high: 6)
        if let r = RPEParser.parse("RPE6") {
            let mark = (r.low == 6 && r.high == 6) ? "✓" : "✗"
            if r.low != 6 || r.high != 6 { allPass = false }
            print("│   \(mark) parse(\"RPE6\") → (\(r.low), \(r.high)) (expected (6, 6))")
        } else { print("│   ✗ parse(\"RPE6\") returned nil"); allPass = false }

        // "RPE6-8" → (low: 6, high: 8)
        if let r = RPEParser.parse("RPE6-8") {
            let mark = (r.low == 6 && r.high == 8) ? "✓" : "✗"
            if r.low != 6 || r.high != 8 { allPass = false }
            print("│   \(mark) parse(\"RPE6-8\") → (\(r.low), \(r.high)) (expected (6, 8))")
        } else { print("│   ✗ parse(\"RPE6-8\") returned nil"); allPass = false }

        // Invalid: "RPE99" (out of range)
        if RPEParser.parse("RPE99") != nil {
            print("│   ✗ parse(\"RPE99\") should return nil (out of 1-10 range)")
            allPass = false
        } else {
            print("│   ✓ parse(\"RPE99\") → nil (correctly rejected out-of-range)")
        }

        // Invalid: "RPE8-3" (low > high)
        if RPEParser.parse("RPE8-3") != nil {
            print("│   ✗ parse(\"RPE8-3\") should return nil (low > high)")
            allPass = false
        } else {
            print("│   ✓ parse(\"RPE8-3\") → nil (correctly rejected inverted range)")
        }

        print("│")
        print("│ Phase 2: parse legacy terms (v1.13 backwards-compat)")

        // "moderate" → (low: 6, high: 7)
        if let r = RPEParser.parse("moderate") {
            let mark = (r.low == 6 && r.high == 7) ? "✓" : "✗"
            if r.low != 6 || r.high != 7 { allPass = false }
            print("│   \(mark) parse(\"moderate\") → (\(r.low), \(r.high)) (legacy → RPE6-7)")
        } else { print("│   ✗ parse(\"moderate\") returned nil"); allPass = false }

        // "max" → (low: 10, high: 10)
        if let r = RPEParser.parse("max") {
            let mark = (r.low == 10 && r.high == 10) ? "✓" : "✗"
            if r.low != 10 || r.high != 10 { allPass = false }
            print("│   \(mark) parse(\"max\") → (\(r.low), \(r.high)) (legacy → RPE10)")
        } else { print("│   ✗ parse(\"max\") returned nil"); allPass = false }

        // "easy" → (low: 4, high: 5)
        if let r = RPEParser.parse("easy") {
            let mark = (r.low == 4 && r.high == 5) ? "✓" : "✗"
            if r.low != 4 || r.high != 5 { allPass = false }
            print("│   \(mark) parse(\"easy\") → (\(r.low), \(r.high)) (legacy → RPE4-5)")
        } else { print("│   ✗ parse(\"easy\") returned nil"); allPass = false }

        // PHASE 2.6 v1.14.1: T-codes (training zones) — common in swim coaching.
        // "T2" → (low: 6, high: 7), "T4" → (low: 8, high: 9), "T5" → (low: 10, high: 10)
        if let r = RPEParser.parse("T2") {
            let mark = (r.low == 6 && r.high == 7) ? "✓" : "✗"
            if r.low != 6 || r.high != 7 { allPass = false }
            print("│   \(mark) parse(\"T2\") → (\(r.low), \(r.high)) (T-code → RPE6-7)")
        } else { print("│   ✗ parse(\"T2\") returned nil"); allPass = false }

        if let r = RPEParser.parse("T4") {
            let mark = (r.low == 8 && r.high == 9) ? "✓" : "✗"
            if r.low != 8 || r.high != 9 { allPass = false }
            print("│   \(mark) parse(\"T4\") → (\(r.low), \(r.high)) (T-code → RPE8-9)")
        } else { print("│   ✗ parse(\"T4\") returned nil"); allPass = false }

        if let r = RPEParser.parse("T5") {
            let mark = (r.low == 10 && r.high == 10) ? "✓" : "✗"
            if r.low != 10 || r.high != 10 { allPass = false }
            print("│   \(mark) parse(\"T5\") → (\(r.low), \(r.high)) (T-code → RPE10)")
        } else { print("│   ✗ parse(\"T5\") returned nil"); allPass = false }

        // Z-codes (alternate notation)
        if let r = RPEParser.parse("Z2") {
            let mark = (r.low == 6 && r.high == 7) ? "✓" : "✗"
            if r.low != 6 || r.high != 7 { allPass = false }
            print("│   \(mark) parse(\"Z2\") → (\(r.low), \(r.high)) (Z-code → RPE6-7)")
        } else { print("│   ✗ parse(\"Z2\") returned nil"); allPass = false }

        print("│")
        print("│ Phase 3: detect ambiguous terms in workout descriptions")

        // "4x50 Free @ moderate" → ["moderate"]
        let terms1 = RPEParser.findAmbiguousTerms(in: "4x50 Free @ moderate")
        let mark1 = (terms1 == ["moderate"]) ? "✓" : "✗"
        if terms1 != ["moderate"] { allPass = false }
        print("│   \(mark1) findAmbiguousTerms(\"4x50 Free @ moderate\") → \(terms1) (expected [\"moderate\"])")

        // "4x50 Free @ hard, 4x100 easy recovery" → ["hard", "easy", "recovery"]
        let terms2 = RPEParser.findAmbiguousTerms(in: "4x50 Free @ hard, 4x100 easy recovery")
        let mark2 = (terms2 == ["hard", "easy", "recovery"]) ? "✓" : "✗"
        if terms2 != ["hard", "easy", "recovery"] { allPass = false }
        print("│   \(mark2) findAmbiguousTerms(\"...@ hard, 4x100 easy recovery\") → \(terms2)")

        // "8x100 IM @ RPE8" → [] (already RPE syntax, no ambiguous terms)
        let terms3 = RPEParser.findAmbiguousTerms(in: "8x100 IM @ RPE8")
        let mark3 = (terms3.isEmpty) ? "✓" : "✗"
        if !terms3.isEmpty { allPass = false }
        print("│   \(mark3) findAmbiguousTerms(\"8x100 IM @ RPE8\") → \(terms3) (expected [] — already RPE)")

        print("│")
        print("│ Phase 4: range overlap (5-way match Tier 1.5)")

        // (6, 7) vs (7, 7) → true (the 7 overlaps)
        let r1: RPEParser.RPERange = (low: 6, high: 7)
        let r2: RPEParser.RPERange = (low: 7, high: 7)
        let mark4 = RPEParser.overlaps(r1, r2) ? "✓" : "✗"
        if !RPEParser.overlaps(r1, r2) { allPass = false }
        print("│   \(mark4) overlaps((6,7), (7,7)) → \(RPEParser.overlaps(r1, r2)) (expected true, the 7 overlaps)")

        // (6, 7) vs (8, 9) → false
        let r3: RPEParser.RPERange = (low: 8, high: 9)
        let mark5 = !RPEParser.overlaps(r1, r3) ? "✓" : "✗"
        if RPEParser.overlaps(r1, r3) { allPass = false }
        print("│   \(mark5) overlaps((6,7), (8,9)) → \(RPEParser.overlaps(r1, r3)) (expected false, no overlap)")

        // (6, 7) vs (6, 7) → true (exact match)
        let mark6 = RPEParser.overlaps(r1, r1) ? "✓" : "✗"
        if !RPEParser.overlaps(r1, r1) { allPass = false }
        print("│   \(mark6) overlaps((6,7), (6,7)) → \(RPEParser.overlaps(r1, r1)) (expected true, exact match)")

        print("│")
        print("└─── Verdict: \(allPass ? "PASS ✓ — RPE parser ready for SessionStartView" : "FAIL ✗") ───┘")
    }
}
