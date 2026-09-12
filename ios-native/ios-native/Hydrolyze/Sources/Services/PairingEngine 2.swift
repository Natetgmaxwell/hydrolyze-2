import Foundation

/// PairingEngine — per-wave constrained Hungarian pairing, replaces
/// `PairingService` and `PairingServiceML`.
///
/// Algorithm (per Nathan's 2026-06-14 design):
///   for each wave:
///     1. Group laps by wave time window [sendOff_N, sendOff_(N+1))
///        using the wave_assignments' sendOffOffsetMs and the
///        WaveAllocator's sendOffIntervalMs.
///     2. For the laps in this window + the swimmers in this wave,
///        build a cost matrix in velocity space (V10 pattern):
///          cost = (vel - meanVel)^2 / (2 * varVel)
///          where meanVel = 1 / (sendOff + prediction.timeMs)
///                varVel  = (sigmaMs / timeMs^2)^2
///     3. Solve constrained Hungarian (one per wave) — optimal within
///        each wave, no cross-wave confusion. The wave 0 always
///        finishes first assumption becomes a structural property of
///        the pairing engine, not something the allocator has to
///        enforce perfectly.
///     4. Add dummy-swimmer rows for ghost taps (more laps than
///        swimmers). Add dummy-lap columns for missed taps (fewer
///        laps than swimmers), imputed with the predicted time and
///        confidence 0.
///
/// Replaces the deleted `PairingService.swift` and `PairingServiceML.swift`.
/// Reuses the `HungarianMatching.solve` algorithm from the old
/// `PairingService` (the O(n³) Kuhn-Munkres).
final class PairingEngine {

    /// Result of a pairing run for a single session.
    struct PairingResult {
        let assignments: [LapAssignment]
        let unassignedLaps: [Lap]            // ghost taps
        let unassignedSwimmers: [Swimmer]   // missed taps
        let usedWaveBySwimmer: [String: Int] // for review display
    }

    /// Ghost-tap threshold. Above this cost, a lap is treated as a
    /// ghost tap (impossible to pair) and assigned to a dummy swimmer.
    /// Tuned value: 5.0 (V10 pattern).
    private let ghostTapThresholdCost: Double = 5.0

    /// PHASE 2.6 v1.16.1: false-start guard. If a lap's wave-relative
    /// time is more than 1 second BEFORE the wave's send-off, the
    /// swimmer tapped before they were sent off — false start. The
    /// engine still assigns the lap (to preserve the v1.9 no-ghost-
    /// taps invariant in the realistic n=m case), but the confidence
    /// is 0 so the coach can see it in the review UI and take an
    /// invalidate action in v1.17 (Slice 3). The 1-second slack
    /// accounts for clock skew and reaction time.
    private let minWaveRelativeMs: Int = -1000

    /// Pair raw tap times with swimmers per-wave. Replaces
    /// `PairingService.runPairer(...)`.
    ///
    /// - Parameters:
    ///   - laps: raw tap times (in ms since the stopwatch started)
    ///   - waveAssignments: per-swimmer wave assignment, with send-off
    ///     offsets. Used to group laps into wave windows.
    ///   - predictions: per-swimmer Prediction (from
    ///     HistoricalTimePredictor). Used to build the cost matrix.
    ///   - sendOffIntervalMs: from WaveAllocator.PoolConfig.
    func pair(
            laps: [Lap],
            waveAssignments: [WaveAssignment],
            predictions: [String: Prediction],
            sendOffIntervalMs: Int
        ) -> PairingResult {
            guard !laps.isEmpty, !waveAssignments.isEmpty else {
                return PairingResult(
                    assignments: [], unassignedLaps: laps,
                    unassignedSwimmers: [], usedWaveBySwimmer: [:]
                )
            }

            // PHASE 2.6 v1.10 REFACTOR — single global Hungarian across
            // ALL swimmers × ALL laps, not per-wave.
            //
            // The per-wave design (v1.6-v1.7) had a structural bug: the
            // wave time windows `[sendOffN, sendOffN + maxSwim + 5s)` for
            // adjacent waves OVERLAP (wave 0 [0, 35s) and wave 1
            // [10s, 47.8s) overlap in [10, 35s)). Wave 0's actual laps
            // at 26-30s fall in BOTH windows. The engine processed each
            // wave independently, so wave 0's 6 laps got re-claimed by
            // wave 1's Hungarian as 6 ghost taps. The CLI test (c7ff874)
            // surfaced this as "8 assignments + 6 ghost taps" in the
            // 6+2 default scenario.
            //
            // The user's design intuition is the right model (per their
            // 2026-06-15 message): "all the swimmers in wave 0 are
            // faster than the swimmers in wave 1, so 1-6 lapped times
            // will be paired with swimmers in wave 0, while 7-8 will
            // be paired with the swimmers in wave 1." This is exactly
            // what a SINGLE global Hungarian does — the cost function
            // uses wave-relative time (`lap.elapsedMs - wa.sendOffOffsetMs`),
            // so a wave 0 lap (low elapsedMs) is naturally cheapest to
            // match to a wave 0 swimmer (sendOff=0, low sendOff), and
            // a wave 1 lap (high elapsedMs) to a wave 1 swimmer
            // (sendOff=10s, high sendOff). The wave structure is
            // IMPLICIT in the cost function, not a hard window. The
            // Hungarian finds the optimal assignment across all
            // swimmers × all laps in one pass.
            //
            // Why this is the right architecture for a swim training
            // environment: the "line" of close finishes is handled
            // by the cost function's Z-score robustness — if two
            // swimmers finish within 100ms, both assignments have
            // similar low cost, and the Hungarian picks the optimal
            // one. The per-wave design couldn't handle lines because
            // it segmented by time window. The single Hungarian
            // handles them naturally.
            let m = laps.count
            let n = waveAssignments.count
            let size = max(n, m)

            // Build single cost matrix: (i = swimmer index, j = lap index)
            var cost = Array(repeating: Array(repeating: Double.infinity, count: size), count: size)

            for i in 0..<n {
                let wa = waveAssignments[i]
                let pred = predictions[wa.swimmerId]
                for j in 0..<m {
                    let lap = laps[j]
                    // Wave-relative time: subtract the wave's sendOff so
                    // the cost is computed against the prediction's range.
                    // Wave 0 (sendOff=0): waveRelativeTime = lap.elapsedMs.
                    // Wave 1 (sendOff=10s): waveRelativeTime = lap.elapsedMs - 10000.
                    let waveRelativeTime = lap.elapsedMs - wa.sendOffOffsetMs
                    cost[i][j] = velocitySpaceCost(
                        actualTimeMs: waveRelativeTime,
                        prediction: pred
                    )
                }
            }

            // Fill dummy-swimmer rows (rows n..size) for ghost taps when
            // laps > swimmers. Diagonal: dummy i absorbs lap (i - n) at
            // threshold cost; off-diagonals get infinity. This ensures
            // each dummy can absorb at most one lap.
            for i in n..<size {
                let dummyIndex = i - n
                for j in 0..<m {
                    if dummyIndex == j {
                        cost[i][j] = ghostTapThresholdCost
                    } else {
                        cost[i][j] = Double.infinity
                    }
                }
            }

            // Fill dummy-lap columns (cols m..size) for missed taps when
            // swimmers > laps. The diagonal (i == j - m) gets the missed-
            // tap threshold; off-diagonals get infinity.
            for i in 0..<n {
                for j in m..<size {
                    if (j - m) == i {
                        cost[i][j] = 0  // missed-tap is "cheapest" so the real swimmer gets the dummy lap
                    } else {
                        cost[i][j] = Double.infinity
                    }
                }
            }

            // Solve Hungarian
            let hungarianResult = HungarianMatching.solve(costMatrix: cost)

            var allAssignments: [LapAssignment] = []
            var unassignedLaps: [Lap] = []
            var unassignedSwimmers: [Swimmer] = []
            var usedWaveBySwimmer: [String: Int] = [:]

            for (i, assignedCol) in hungarianResult.enumerated() {
                if i >= size || assignedCol < 0 || assignedCol >= size {
                    continue
                }

                if i < n && assignedCol < m {
                    // Real swimmer assigned to real lap
                    let wa = waveAssignments[i]
                    let lap = laps[assignedCol]
                    let cellCost = cost[i][assignedCol]
                    // PHASE 2.6 v1.16.1: compute wave-relative time at
                    // the top so the false-start guard (below) and
                    // the z-score confidence calc (further below) can
                    // both reuse it.
                    let waveRelativeTime = lap.elapsedMs - wa.sendOffOffsetMs
                    let confidence: Int
                    // PHASE 2.6 v1.17.0 (S4): the Gaussian pairing
                    // probability. Computed alongside the integer
                    // confidence; same z-score, different formula.
                    // exp(-z²/2) is the standard statistical
                    // probability that an observation is drawn from
                    // the predicted distribution. Finer precision
                    // than the bucketed 0-99 integer. The review UI
                    // still uses the integer (and its 80/50
                    // thresholds); this Gaussian is for future
                    // analytics and a possible future fine-grained
                    // band system. Set to 0.0 in the failure cases
                    // (false-start, ghost-tap) where z is undefined.
                    var assignmentConfidence: Double = 0.0
                    // PHASE 2.6 v1.16.1: false-start guard. Detects
                    // wave-relative < minWaveRelativeMs and forces
                    // confidence: 0. The existing cellCost >=
                    // ghostTapThresholdCost check catches this too
                    // (via the velocitySpaceCost `guard actualTimeMs > 0`
                    // path) — this guard is the explicit, named
                    // detection. The v1.17 "invalidate swimmer/rep"
                    // coach action (Slice 3) will read confidence 0
                    // rows and surface them as candidates.
                    if waveRelativeTime < minWaveRelativeMs {
                        confidence = 0
                    } else if cellCost >= ghostTapThresholdCost {
                        confidence = 0
                    } else if let pred = predictions[wa.swimmerId], pred.timeMs > 0 {
                        let sigma = Double(max(pred.sigmaMs, 100))
                        let z = abs(Double(waveRelativeTime) - Double(pred.timeMs)) / sigma
                        confidence = max(0, 99 - Int(z * 15))
                        assignmentConfidence = exp(-z * z / 2)
                    } else {
                        confidence = 50  // no prediction = moderate default
                        // 50/100 on the integer scale ≈ 0.5 on the
                        // Gaussian scale (a coin flip for the
                        // prediction-less case). Matches the spirit
                        // of the existing default.
                        assignmentConfidence = 0.5
                    }
                    let swimmerUUID = UUID(uuidString: wa.swimmerId) ?? UUID()
                    allAssignments.append(LapAssignment(
                        id: lap.id,
                        lap: lap,
                        swimmerId: swimmerUUID,
                        confidence: confidence,
                        assignmentConfidence: assignmentConfidence,
                        workoutSetId: wa.workoutSetId,
                        waveNumber: wa.waveNumber
                    ))
                    usedWaveBySwimmer[wa.swimmerId] = wa.waveNumber
                } else if i < n && assignedCol >= m {
                    // Real swimmer assigned to dummy-lap column = MISSED tap.
                    // Impute with the predicted time at the wave's sendOff.
                    let wa = waveAssignments[i]
                    let missedCol = assignedCol - m
                    let imputedLap = Lap(
                        id: "imputed_\(missedCol)_\(wa.id)",
                        lapNumber: laps.count + missedCol + 1,
                        elapsedMs: wa.sendOffOffsetMs + (predictions[wa.swimmerId]?.timeMs ?? 0),
                        splitMs: 0
                    )
                    let swimmerUUID = UUID(uuidString: wa.swimmerId) ?? UUID()
                    allAssignments.append(LapAssignment(
                        id: "imputed_\(missedCol)_\(wa.id)",
                        lap: imputedLap,
                        swimmerId: swimmerUUID,
                        confidence: 0,
                        // Imputed misses have no real pairing to
                        // measure Gaussian against; 0.0 is the
                        // conservative default. The existing
                        // backward-compat init accepts the
                        // assignmentConfidence: 0.0 default
                        // automatically — using it here keeps the
                        // imputed-miss path unchanged.
                        workoutSetId: wa.workoutSetId,
                        waveNumber: wa.waveNumber
                    ))
                    usedWaveBySwimmer[wa.swimmerId] = wa.waveNumber
                } else if i >= n && assignedCol < m {
                    // Dummy swimmer assigned to real lap = GHOST tap.
                    unassignedLaps.append(laps[assignedCol])
                }
                // else: dummy to dummy, ignore
            }

            // Find unassigned swimmers (any wave_assignment not in the assignment set).
            //
            // PHASE 2.6 v1.10 BUGFIX: compare UUID objects, not case-sensitive
            // strings. The previous code built `Set<String>` from
            // `LapAssignment.swimmerId.uuidString` (which returns the
            // canonical UPPERCASE form) and then checked
            // `!assignedSwimmerIds.contains(wa.swimmerId)` where
            // `wa.swimmerId` is the original (lowercase) input. They
            // never matched → ALL swimmers marked unassigned. CLI test
            // (c7ff874) surfaced this in the 0+8 and 8+0 scenarios
            // (8 unassigned swimmers alongside 8 real assignments).
            let assignedSwimmerUUIDs = Set(allAssignments.map { $0.swimmerId })
            for wa in waveAssignments {
                if let uuid = UUID(uuidString: wa.swimmerId), !assignedSwimmerUUIDs.contains(uuid) {
                    unassignedSwimmers.append(Swimmer(
                        id: wa.swimmerId,
                        coachId: "",
                        firstName: "Unknown",
                        lastName: nil
                    ))
                }
            }

            return PairingResult(
                assignments: allAssignments,
                unassignedLaps: unassignedLaps,
                unassignedSwimmers: unassignedSwimmers,
                usedWaveBySwimmer: usedWaveBySwimmer
            )
        }

    /// Velocity-space cost for a (actual, prediction) pair. V10 pattern:
    ///   cost = (vel - meanVel)^2 / (2 * varVel)
    /// where meanVel = 1 / prediction.timeMs
    ///       varVel  = (sigmaMs / timeMs^2)^2
    ///
    /// Returns the ghost-tap threshold if prediction is missing (cold-start).
    private func velocitySpaceCost(
        actualTimeMs: Int,
        prediction: Prediction?
    ) -> Double {
        guard let pred = prediction, pred.timeMs > 0 else {
            // Cold-start: penalize equally for any swimmer (no info)
            return ghostTapThresholdCost
        }
        guard actualTimeMs > 0 else {
            return ghostTapThresholdCost
        }
        let vel = 1.0 / Double(actualTimeMs)
        let meanVel = 1.0 / Double(pred.timeMs)
        let stdevVel = (1.0 / pow(Double(pred.timeMs), 2)) * Double(pred.sigmaMs)
        let varVel = pow(stdevVel, 2)
        guard varVel > 0 else {
            return ghostTapThresholdCost
        }
        return pow(vel - meanVel, 2) / (2.0 * varVel)
    }
}
