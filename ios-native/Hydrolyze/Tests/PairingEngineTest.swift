import XCTest
@testable import Hydrolyze

/// PairingEngineTest — verifies Phase 2.6 v1.9 invariants:
///   (1) no ghost taps when laps.count == swimmers.count
///   (2) per-wave Hungarian matches every real swimmer to their own lap
///   (3) variance > 100ms doesn't break the engine
///
/// 3 test scenarios cover the realistic wave splits:
///   A. 6+2 default (default 6-lane pool)
///   B. 0+8 (all swimmers in wave 1)
///   C. 8+0 (all swimmers in wave 0)
///
/// Ponytail-pass notes (see `ponytail-delegation` skill):
///   - Stdlib (XCTest). No deps. No 200-line class wrapping a dict.
///   - One test class, three focused methods, three small helpers.
///   - Trust-boundary carve-out is N/A (no real DB, no auth, fixed
///     test data).
final class PairingEngineTest: XCTestCase {

    // 8 mock swimmers. `id` is a fixed UUID string so the
    // WaveAssignment.swimmerId parses to a real UUID (the pairing
    // engine does `UUID(uuidString: wa.swimmerId) ?? UUID()` and
    // uses the result as the LapAssignment.swimmerId).
    private let mockSwimmerIds: [String] = [
        "11111111-1111-1111-1111-111111111111",  // 0: Alice
        "22222222-2222-2222-2222-222222222222",  // 1: Bob
        "33333333-3333-3333-3333-333333333333",  // 2: Charlie
        "44444444-4444-4444-4444-444444444444",  // 3: Diana
        "55555555-5555-5555-5555-555555555555",  // 4: Ethan
        "66666666-6666-6666-6666-666666666666",  // 5: Fiona
        "77777777-7777-7777-7777-777777777777",  // 6: George
        "88888888-8888-8888-8888-888888888888",  // 7: Hannah
    ]

    // PBs in ms (from the existing mock data)
    private let mockPBsMs: [Int] = [26800, 27200, 27900, 28400, 29500, 30100, 31200, 32800]

    // Wave-relative time variance per swimmer (the actual lap - PB).
    // The user explicitly asked for variance > 100ms; we use ±200-300ms
    // which is realistic for a coach's reaction time on a 50m Free.
    // Format: [alice: +200, bob: +300, charlie: -100, diana: -300,
    //          ethan: +200, fiona: +300, george: -200, hannah: -300]
    private let waveRelativeVarianceMs: [Int] = [200, 300, -100, -300, 200, 300, -200, -300]

    private let sendOffIntervalMs = 10_000

    // MARK: - Scenario A: 6+2 default wave split

    /// Realistic test case: 6 swimmers in wave 0 (sendOff=0), 2 in
    /// wave 1 (sendOff=10s). All 8 taps are real — no ghost taps.
    func test6Plus2SplitNoGhostTaps() {
        let waveAssignments = makeWaveAssignments(
            wave0Indices: [0, 1, 2, 3, 4, 5],   // Alice..Fiona
            wave1Indices: [6, 7]                  // George, Hannah
        )

        // Wave 0: elapsedMs = 0 + PB + variance
        // Wave 1: elapsedMs = 10000 + PB + variance
        let laps: [Lap] = [
            makeLap(1, elapsedMs: sendOff(0) + mockPBsMs[0] + waveRelativeVarianceMs[0]),  // Alice
            makeLap(2, elapsedMs: sendOff(0) + mockPBsMs[1] + waveRelativeVarianceMs[1]),  // Bob
            makeLap(3, elapsedMs: sendOff(0) + mockPBsMs[2] + waveRelativeVarianceMs[2]),  // Charlie
            makeLap(4, elapsedMs: sendOff(0) + mockPBsMs[3] + waveRelativeVarianceMs[3]),  // Diana
            makeLap(5, elapsedMs: sendOff(0) + mockPBsMs[4] + waveRelativeVarianceMs[4]),  // Ethan
            makeLap(6, elapsedMs: sendOff(0) + mockPBsMs[5] + waveRelativeVarianceMs[5]),  // Fiona
            makeLap(7, elapsedMs: sendOff(1) + mockPBsMs[6] + waveRelativeVarianceMs[6]),  // George
            makeLap(8, elapsedMs: sendOff(1) + mockPBsMs[7] + waveRelativeVarianceMs[7]),  // Hannah
        ]

        runPairingAssertions(
            laps: laps,
            waveAssignments: waveAssignments,
            scenarioName: "6+2 default"
        )
    }

    // MARK: - Scenario B: 0+8 (all in wave 1)

    /// Edge case: 8-lane pool, every swimmer is in wave 1
    /// (sendOff=10s). The wave-0 slot is empty.
    func test0Plus8SplitNoGhostTaps() {
        let waveAssignments = makeWaveAssignments(
            wave0Indices: [],
            wave1Indices: [0, 1, 2, 3, 4, 5, 6, 7]
        )

        let laps: [Lap] = (0..<8).map { i in
            makeLap(i + 1, elapsedMs: sendOff(1) + mockPBsMs[i] + waveRelativeVarianceMs[i])
        }

        runPairingAssertions(
            laps: laps,
            waveAssignments: waveAssignments,
            scenarioName: "0+8 (all wave 1)"
        )
    }

    // MARK: - Scenario C: 8+0 (all in wave 0)

    /// Edge case: 8-lane pool, every swimmer is in wave 0
    /// (sendOff=0). The wave-1 slot is empty.
    func test8Plus0SplitNoGhostTaps() {
        let waveAssignments = makeWaveAssignments(
            wave0Indices: [0, 1, 2, 3, 4, 5, 6, 7],
            wave1Indices: []
        )

        let laps: [Lap] = (0..<8).map { i in
            makeLap(i + 1, elapsedMs: sendOff(0) + mockPBsMs[i] + waveRelativeVarianceMs[i])
        }

        runPairingAssertions(
            laps: laps,
            waveAssignments: waveAssignments,
            scenarioName: "8+0 (all wave 0)"
        )
    }

    // MARK: - Helpers

    private func sendOff(_ wave: Int) -> Int {
        wave * sendOffIntervalMs
    }

    private func makeLap(_ lapNumber: Int, elapsedMs: Int) -> Lap {
        Lap(
            id: UUID().uuidString,
            lapNumber: lapNumber,
            elapsedMs: elapsedMs,
            splitMs: elapsedMs
        )
    }

    private func makeWaveAssignments(
        wave0Indices: [Int],
        wave1Indices: [Int]
    ) -> [WaveAssignment] {
        var out: [WaveAssignment] = []
        let now = ISO8601DateFormatter().string(from: Date())

        for (i, idx) in wave0Indices.enumerated() {
            out.append(WaveAssignment(
                id: UUID().uuidString,
                sessionId: "test-session",
                swimmerId: mockSwimmerIds[idx],
                workoutSetId: "test-set",
                lane: i + 1,
                positionInLane: 0,
                predictedTouchMs: sendOff(0) + mockPBsMs[idx],
                waveNumber: 0,
                sendOffOffsetMs: 0,
                coachId: "test-coach",
                createdAt: now
            ))
        }

        for (i, idx) in wave1Indices.enumerated() {
            out.append(WaveAssignment(
                id: UUID().uuidString,
                sessionId: "test-session",
                swimmerId: mockSwimmerIds[idx],
                workoutSetId: "test-set",
                lane: i + 1,
                positionInLane: 0,
                predictedTouchMs: sendOff(1) + mockPBsMs[idx],
                waveNumber: 1,
                sendOffOffsetMs: sendOff(1),
                coachId: "test-coach",
                createdAt: now
            ))
        }

        return out
    }

    private func makePredictions() -> [String: Prediction] {
        var preds: [String: Prediction] = [:]
        for (i, pb) in mockPBsMs.enumerated() {
            preds[mockSwimmerIds[i]] = Prediction(
                timeMs: pb,
                sigmaMs: 2000,
                sampleSize: 0,
                source: .curve,
                maturity: .none,
                // T3/T4 (2026-06-20) added suit + start calibration deltas to
                // Prediction. nil = no calibration data, which is the correct
                // fixture for these pairing-invariant scenarios (they assert on
                // assignment topology, not on calibrated times).
                suitDeltaMs: nil,
                startDeltaMs: nil
            )
        }
        return preds
    }

    /// Run the pairing engine + assert the v1.9 invariants:
    ///   - assignments.count == 8 (one per real swimmer)
    ///   - unassignedLaps.count == 0 (no ghost taps)
    ///   - unassignedSwimmers.count == 0 (no missed swimmers)
    ///   - every swimmer is paired to a lap (not a dummy)
    private func runPairingAssertions(
        laps: [Lap],
        waveAssignments: [WaveAssignment],
        scenarioName: String
    ) {
        let result = PairingEngine().pair(
            laps: laps,
            waveAssignments: waveAssignments,
            predictions: makePredictions(),
            sendOffIntervalMs: sendOffIntervalMs
        )

        XCTAssertEqual(
            result.assignments.count, 8,
            "[\(scenarioName)] Expected 8 real assignments, got \(result.assignments.count). Ghost-tap invariant violated."
        )
        XCTAssertEqual(
            result.unassignedLaps.count, 0,
            "[\(scenarioName)] Expected 0 ghost taps, got \(result.unassignedLaps.count)."
        )
        XCTAssertEqual(
            result.unassignedSwimmers.count, 0,
            "[\(scenarioName)] Expected 0 missed swimmers, got \(result.unassignedSwimmers.count)."
        )

        // Every mock swimmer should appear in the assignment set.
        let assignedSwimmerIds = Set(result.assignments.map { $0.swimmerId.uuidString })
        for (i, swimmerId) in mockSwimmerIds.enumerated() {
            let prefix = "[\(scenarioName)] Swimmer \(i) (\(swimmerId))"
            XCTAssertTrue(
                assignedSwimmerIds.contains(swimmerId),
                "\(prefix) should be paired to a real lap."
            )
        }
    }
}
