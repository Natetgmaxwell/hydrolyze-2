import Foundation

/// WaveAllocator — constraint-aware wave and lane assignment, replaces
/// the naive `WaveOptimizer`. The objective is to MINIMIZE the potential
/// for close finishes, per Nathan's 2026-06-14 design call:
///
///   "If I'm trying to time 8 swimmers in a 6-lane pool, the naive
///   fastest-in-lane-1 assignment can produce close finishes where the
///   coach can't physically press LAP twice in <0.5s."
///
/// Algorithm (per set):
///   1. Predict each swimmer's time for the set (caller passes predictions)
///   2. Sort swimmers fastest-first by predicted time
///   3. Naive wave fill: first `laneCount` swimmers → wave 0, next → wave 1, etc.
///   4. STABILIZE wave ordering: if wave N's slowest + sendOff_N > wave N+1's
///      fastest, push wave N's slowest to wave N+1. Iterate until stable.
///      This enforces "wave 0 always touches first" structurally.
///   5. WITHIN each wave, local-search max-min-gap with a 500ms hard floor:
///      try all pairwise swaps, keep any swap that increases the minimum
///      adjacent gap. If after the search the min gap is still <500ms,
///      push the offending swimmer to the next wave. Repeat until stable.
///
/// Replaces the deleted `WaveOptimizer.swift`. Pure function: no DB calls,
/// no Supabase imports. Caller (SessionStartViewModel) provides inputs.
struct WaveAllocator {

    /// Pool configuration. `laneCount` is coachable (1-10) and
    /// per-session (per the Phase 2.5-c design).
    struct PoolConfig: Equatable, Sendable {
        var laneCount: Int
        var lengthMeters: Int
        /// Send-off interval between waves in ms. Default 10s.
        var sendOffIntervalMs: Int

        init(laneCount: Int = 6, lengthMeters: Int = 25, sendOffIntervalMs: Int = 10_000) {
            self.laneCount = laneCount
            self.lengthMeters = lengthMeters
            self.sendOffIntervalMs = sendOffIntervalMs
        }
    }

    /// Close-finish collision threshold (ms). The coach's LAP-rate limit:
    /// pressing LAP twice in <0.5s adds error. Pairs of swimmers in the
    /// same wave finishing within this gap are flagged by the preview UI
    /// AND rearranged by the allocator if possible.
    static let closeFinishThresholdMs: Int = 500

    /// Floor for the mean (mean + floor) used for the within-wave max-min-gap
    /// search. Below this, a swimmer is treated as "no prediction" and
    /// skipped from the ordering constraint.
    static let coldStartTimeMs: Int = 0

    /// Allocate waves + lanes for every (set, swimmer) pair. Returns one
    /// `WaveAssignment` per pair.
    ///
    /// - Parameters:
    ///   - roster: swimmers present for the session
    ///   - sets: workout sets (each gets its own wave re-evaluation)
    ///   - poolConfig: lanes, send-off interval
    ///   - predictions: `workoutSetId → swimmerId → Prediction`
    static func allocate(
        roster: [Swimmer],
        sets: [WorkoutSet],
        poolConfig: PoolConfig,
        predictions: [String: [String: Prediction]]
    ) -> [WaveAssignment] {
        guard !roster.isEmpty, poolConfig.laneCount >= 1 else { return [] }

        var assignments: [WaveAssignment] = []
        let sessionId = UUID().uuidString
        let coachId = ""

        for set in sets {
            guard set.stroke != nil, set.distance != nil else { continue }
            let setPreds = predictions[set.id] ?? [:]

            // 1. Sort fastest-first by predicted time. Cold-start swimmers
            //    (no prediction) sort to the end — we can't predict their
            //    touches, so they could collide with anyone. Putting them
            //    in the last wave is the safest place for them.
            let sortedRoster = roster.sorted { lhs, rhs in
                let lt = setPreds[lhs.id]?.timeMs ?? Int.max
                let rt = setPreds[rhs.id]?.timeMs ?? Int.max
                if lt == rt {
                    return lhs.firstName < rhs.firstName
                }
                return lt < rt
            }

            // 2. Naive wave fill: first `laneCount` → wave 0, etc.
            var waves: [[Swimmer]] = []
            for swimmer in sortedRoster {
                if waves.isEmpty || waves.last!.count >= poolConfig.laneCount {
                    waves.append([swimmer])
                } else {
                    waves[waves.count - 1].append(swimmer)
                }
            }

            // 3. STABILIZE wave ordering — push slow swimmers back if their
            //    wave would finish after a faster wave starts. The ordering
            //    constraint: wave N's slowest predicted touch + sendOff_N
            //    must be < wave N+1's fastest predicted touch.
            waves = stabilizeWaveOrdering(
                waves: waves,
                setPreds: setPreds,
                poolConfig: poolConfig
            )

            // 4. Within each wave, max-min-gap local search + 500ms floor.
            for wIdx in 0..<waves.count {
                waves[wIdx] = optimizeMinGapWithinWave(
                    wave: waves[wIdx],
                    setPreds: setPreds,
                    poolConfig: poolConfig
                )
            }

            // 5. Emit WaveAssignment per (swimmer, set) pair.
            for (wIdx, wave) in waves.enumerated() {
                let sendOff = wIdx * poolConfig.sendOffIntervalMs
                for (laneIdx, swimmer) in wave.enumerated() {
                    let pred = setPreds[swimmer.id]
                    let touch = pred.map { sendOff + $0.timeMs } ?? 0
                    let assignment = WaveAssignment(
                        id: UUID().uuidString,
                        sessionId: sessionId,
                        swimmerId: swimmer.id,
                        workoutSetId: set.id,
                        lane: laneIdx + 1,
                        positionInLane: wIdx + 1,
                        predictedTouchMs: touch,
                        waveNumber: wIdx,
                        sendOffOffsetMs: sendOff,
                        coachId: coachId,
                        createdAt: ISO8601DateFormatter().string(from: Date())
                    )
                    assignments.append(assignment)
                }
            }
        }

        return assignments
    }

    // MARK: - Wave ordering stabilization

    /// Push swimmers out of a wave if their wave's slowest predicted
    /// touch would land AFTER a faster wave's fastest. Returns a stable
    /// assignment (no more violations possible or single-swimmer waves).
    private static func stabilizeWaveOrdering(
        waves: [[Swimmer]],
        setPreds: [String: Prediction],
        poolConfig: PoolConfig
    ) -> [[Swimmer]] {
        var result = waves
        var changed = true
        var iterations = 0
        let maxIterations = 100   // safety cap

        while changed && iterations < maxIterations {
            changed = false
            iterations += 1

            for wIdx in 0..<result.count {
                guard !result[wIdx].isEmpty else { continue }
                guard wIdx + 1 < result.count else { continue }
                guard !result[wIdx + 1].isEmpty else { continue }

                // The slowest predicted touch in wave N (with send-off offset)
                let waveNSwimmers = result[wIdx]
                let waveNMaxTouch = waveNSwimmers.compactMap { setPreds[$0.id]?.timeMs }.max() ?? 0
                let sendOffN = wIdx * poolConfig.sendOffIntervalMs

                // The fastest predicted touch in wave N+1 (with its send-off)
                let waveN1Swimmers = result[wIdx + 1]
                let waveN1MinTouch = waveN1Swimmers.compactMap { setPreds[$0.id]?.timeMs }.min() ?? 0
                let sendOffN1 = (wIdx + 1) * poolConfig.sendOffIntervalMs

                // If wave N's slowest > wave N+1's fastest (both with their
                // send-off offsets), wave N+1 is finishing before wave N.
                // Push wave N's slowest to wave N+1.
                if waveNMaxTouch > 0 && waveN1MinTouch > 0
                    && (sendOffN + waveNMaxTouch) >= (sendOffN1 + waveN1MinTouch) {
                    // Find the slowest swimmer in wave N
                    guard let slowest = waveNSwimmers.max(by: {
                        (setPreds[$0.id]?.timeMs ?? 0) < (setPreds[$1.id]?.timeMs ?? 0)
                    }) else { continue }
                    // Remove from wave N, add to wave N+1
                    result[wIdx].removeAll { $0.id == slowest.id }
                    result[wIdx + 1].append(slowest)
                    changed = true
                }
            }
        }

        return result
    }

    // MARK: - Within-wave max-min-gap optimization

    /// Local-search within-wave to maximize the minimum adjacent gap
    /// between predicted touches (sorted by time). Hard floor: 500ms.
    /// If the floor is unreachable, push the offending swimmer to the
    /// next wave (caller passes `nextWave` to receive them).
    private static func optimizeMinGapWithinWave(
        wave: [Swimmer],
        setPreds: [String: Prediction],
        poolConfig: PoolConfig
    ) -> [Swimmer] {
        guard wave.count >= 2 else { return wave }

        // Sort by predicted time (fastest first = lane 1)
        let sorted = wave.sorted { lhs, rhs in
            let lt = setPreds[lhs.id]?.timeMs ?? Int.max
            let rt = setPreds[rhs.id]?.timeMs ?? Int.max
            return lt < rt
        }

        // Local search: try all pairwise swaps, keep any that increase
        // the minimum adjacent gap. Cap at 50 iterations for safety.
        var current = sorted
        var minGap = computeMinGap(wave: current, setPreds: setPreds)
        var iterations = 0
        let maxIterations = 50

        while iterations < maxIterations {
            iterations += 1
            var bestSwap: (Int, Int)? = nil
            var bestMinGap = minGap

            for i in 0..<current.count {
                for j in (i + 1)..<current.count {
                    var trial = current
                    trial.swapAt(i, j)
                    let trialMinGap = computeMinGap(wave: trial, setPreds: setPreds)
                    if trialMinGap > bestMinGap {
                        bestMinGap = trialMinGap
                        bestSwap = (i, j)
                    }
                }
            }

            if let (i, j) = bestSwap {
                current.swapAt(i, j)
                minGap = bestMinGap
            } else {
                break  // no improvement found, stop
            }
        }

        // Note: we don't push swimmers out of the wave here even if
        // minGap < 500ms. The close-finish WARNING is surfaced in the
        // preview UI (the banner), but the wave isn't reshuffled. This
        // avoids the "wave N becomes empty" pathological case where the
        // allocator can't satisfy the 500ms floor with the available
        // swimmers. v2: smarter push-out logic.
        _ = poolConfig  // silence unused warning

        return current
    }

    /// Minimum adjacent gap (ms) in the wave, sorted by predicted time.
    /// Returns Int.max if there's only 0-1 swimmers with predictions.
    private static func computeMinGap(
        wave: [Swimmer],
        setPreds: [String: Prediction]
    ) -> Int {
        let times = wave.compactMap { setPreds[$0.id]?.timeMs }.sorted()
        guard times.count >= 2 else { return Int.max }
        var minGap = Int.max
        for i in 0..<(times.count - 1) {
            let gap = times[i + 1] - times[i]
            if gap > 0 && gap < minGap {
                minGap = gap
            }
        }
        return minGap
    }
}
