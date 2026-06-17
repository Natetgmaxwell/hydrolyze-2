import Foundation

/// PBService — the SINGLE function for "what's this swimmer's predicted
/// time for this set + intensity + gear?"
///
/// PHASE 2.6 v1.13.0: introduced to fix the data-flow opacity identified
/// after the first real-world iOS test (2026-06-16). The 5-way match
/// (swimmer, stroke, distance, intensity, gear) is the canonical lookup
/// key. Layer 1 uses recorded_times; Layer 2 uses swimmer_pbs with
/// tiered fallbacks; Layer 3 is the population seed.
///
/// Replaces 4 separate code paths:
///   - SwimmerService.fetchPersonalBests (for the profile screen)
///   - SessionStartViewModel.lockRoster (for the wave preview)
///   - TimingViewModel.save (v1.12, for the live predictor)
///   - coarsePredictions derived from wa.predictedTouchMs (fallback)
///
/// All four now call PBService.fetchPrediction(...) and get the same
/// `Prediction` for the same (swimmer, set, intensity, gear) input.
/// The coach can trust that what the profile screen shows is what
/// the engine uses.
struct PBService {
    /// The single function. Returns nil for IM (always manual) or
    /// for a set without stroke/distance.
    ///
    /// `recordedTimes`: ALL recorded_times the caller has fetched
    ///   (filtered internally to this swimmer + set + intensity + gear).
    ///   The caller decides the fetch strategy (e.g., all for the
    ///   wave preview, or only this swimmer for the profile screen).
    /// `pbs`: ALL swimmer_pbs the caller has fetched
    ///   (filtered internally to the 5-way match with fallbacks).
    ///   Same caller-decides-fetch-strategy.
    func fetchPrediction(
        swimmer: Swimmer,
        set: WorkoutSet,
        intensity: String,
        gear: String?,
        prefs: CoachPreferences,
        recordedTimes: [RecordedTime],
        pbs: [SwimmerPB]
    ) -> Prediction? {
        // IM is always manual per v2 design.
        if set.stroke == "IM" { return nil }
        guard let stroke = set.stroke, let distance = set.distance else {
            return nil
        }
        let normalizedGear = gear ?? "none"  // canonical gear is 'none', not NULL

        // ── Layer 1: recorded stats (5-way match) ─────────────────
        // The 5-way match is the canonical key. For each (set, intensity,
        // gear, swimmer), the predictor returns the median-of-last-5 or
        // EMA(α=0.3) of the recorded_times, per prefs.
        let swimmerRTs = recordedTimes.filter { rt in
            rt.swimmerId == swimmer.id
            && rt.workoutSetId == set.id
            && rt.intensity == intensity
            && (rt.gear ?? "none") == normalizedGear
        }
        if swimmerRTs.count >= 5 {
            let sorted = swimmerRTs.sorted { ($0.createdAt) > ($1.createdAt) }
            let recent = Array(sorted.prefix(5))
            let times = recent.map { $0.timeMs }
            let meanMs: Int
            switch prefs.predictionAlgorithm {
            case .median:
                meanMs = Self.median(times)
            case .ema:
                meanMs = Self.ema(times, alpha: 0.3)
            }
            let sigma = max(Self.sampleStdDev(times), 1500)
            return Prediction(
                timeMs: meanMs,
                sigmaMs: sigma,
                sampleSize: sorted.count,
                source: .historical,
                maturity: Self.tierFor(sampleCount: sorted.count)
            )
        }

        // ── Layer 2: PBs (5-way match, with fallbacks) ─────────────
        // Tier 1: EXACT match on (swimmer, stroke, distance, intensity, gear)
        // Tier 2: same intensity, any gear
        // Tier 3: same stroke/distance, any intensity
        // Each tier returns a Prediction from the matching PBs using
        // the algorithm preference (median or EMA).

        // Tier 1: exact match
        let tier1 = pbs.filter { pb in
            pb.swimmerId == swimmer.id
            && pb.stroke == stroke
            && pb.distance == distance
            && pb.intensity == intensity
            && (pb.gear ?? "none") == normalizedGear
        }
        if !tier1.isEmpty {
            return predictionFromPBs(
                tier1, prefs: prefs,
                source: .historical,
                maturity: .reliable
            )
        }

        // Tier 2: same intensity, any gear
        let tier2 = pbs.filter { pb in
            pb.swimmerId == swimmer.id
            && pb.stroke == stroke
            && pb.distance == distance
            && pb.intensity == intensity
        }
        if !tier2.isEmpty {
            return predictionFromPBs(
                tier2, prefs: prefs,
                source: .historical,
                maturity: .learning
            )
        }

        // Tier 3: same stroke/distance, any intensity
        let tier3 = pbs.filter { pb in
            pb.swimmerId == swimmer.id
            && pb.stroke == stroke
            && pb.distance == distance
        }
        if !tier3.isEmpty {
            return predictionFromPBs(
                tier3, prefs: prefs,
                source: .curve,
                maturity: .none
            )
        }

        // ── Layer 3: population seed ──────────────────────────────
        // Cold-start fallback: a population average for the stroke.
        // This is intentionally simple — the predictor's full Layer 3
        // logic is in HistoricalTimePredictor. PBService returns nil
        // if we have no data, and the caller falls back to the coarse.
        return nil
    }

    // MARK: - Helpers

    private func predictionFromPBs(
        _ pbs: [SwimmerPB],
        prefs: CoachPreferences,
        source: Prediction.Source,
        maturity: Prediction.Maturity
    ) -> Prediction {
        let times = pbs.map { $0.timeMs }
        let meanMs: Int
        switch prefs.predictionAlgorithm {
        case .median:
            meanMs = Self.median(times)
        case .ema:
            meanMs = Self.ema(times, alpha: 0.3)
        }
        let sigma = max(Self.sampleStdDev(times), 1500)
        return Prediction(
            timeMs: meanMs,
            sigmaMs: sigma,
            sampleSize: pbs.count,
            source: source,
            maturity: maturity
        )
    }

    static func median(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        let n = s.count
        if n % 2 == 1 { return s[n / 2] }
        return (s[n / 2 - 1] + s[n / 2]) / 2
    }

    static func ema(_ values: [Int], alpha: Double) -> Int {
        guard !values.isEmpty else { return 0 }
        // Process oldest-to-newest with the oldest as the seed.
        // (See the v1.12 e2e test for the algorithm convention.)
        var result = Double(values.last!)
        for v in values.dropLast().reversed() {
            result = alpha * Double(v) + (1.0 - alpha) * result
        }
        return Int(result.rounded())
    }

    static func sampleStdDev(_ values: [Int]) -> Int {
        guard values.count >= 2 else { return 0 }
        let n = Double(values.count)
        let mean = Double(values.reduce(0, +)) / n
        let sumSq = values.reduce(0.0) { $0 + pow(Double($1) - mean, 2) }
        let variance = sumSq / (n - 1)
        return Int(variance.squareRoot().rounded())
    }

    static func tierFor(sampleCount: Int) -> Prediction.Maturity {
        switch sampleCount {
        case 0: return .none
        case 1...5: return .learning
        case 6...15: return .reliable
        default: return .excellent
        }
    }
}
