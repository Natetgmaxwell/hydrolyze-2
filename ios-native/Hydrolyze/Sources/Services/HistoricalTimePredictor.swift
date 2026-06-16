import Foundation

/// HistoricalTimePredictor — 3-layer prediction pipeline, ported from
/// the pairing-engine-v2 TypeScript design (`src/predict.ts`).
///
/// For a swimmer + set context, find the best available prediction of
/// their expected time and standard deviation. Priority (best first):
///
///   **Layer 1**: recorded stats (real training data — best quality)
///   **Layer 2**: speed curve from PBs (estimated — medium quality)
///   **Layer 3**: population average (cold start — low quality)
///
/// Algorithm choice (median-of-last-5 vs. EMA) is read from the
/// `CoachPreferences.predictionAlgorithm` and used in Layer 1.
///
/// Sigma (for the pairing cost function):
///   - Layer 1: `max(sampleStdDev(last5), 1500)` — floor prevents
///     overconfident costs from a 1-sample variance.
///   - Layer 2: `timeMs * stddevFraction[distance]` (5% for 50m, 6% for
///     100m, 8% for 200m, etc.) — training variance is tighter at
///     sprint distances, looser at distance events.
///   - Layer 3: `timeMs * 0.10` — conservative 10% for population seed.
///
/// Used by `WaveAllocator` (predicted times for sorting swimmers into
/// waves) and `PairingEngine` (sigma for the velocity-space cost).
final class HistoricalTimePredictor {
    /// Default alpha for the EMA. With α=0.3, the half-life is ~2
    /// recent swims — enough to track form without being dominated by
    /// one-off bad days. Coach-tunable later (v2 design).
    static let defaultEMAAlpha: Double = 0.3

    /// Minimum number of recorded_times needed to use Layer 1
    /// (the "PBs useful until 5 swims" threshold from Nathan's
    /// 2026-06-14 design call). Below this, fall through to Layer 2.
    static let minSamplesForHistorical: Int = 5

    /// Sigma floor for Layer 1. Below this the cost function would
    /// over-trust a 1-sample variance estimate.
    static let sigmaFloorMs: Int = 1500

    /// Predicted the mean and stddev for a swimmer + set combo.
    /// Returns nil for IM (always manual per v2 design) or if the
    /// swimmer has no data and no fallback could produce a value.
    func predict(
        swimmer: Swimmer,
        set: WorkoutSet,
        recordedTimes: [RecordedTime],   // Layer 1 input (filtered externally)
        pbs: [SwimmerPB],                // Layer 2 input
        prefs: CoachPreferences
    ) -> Prediction? {
        // IM is always manual per v2 DESIGN.md
        if set.stroke == "IM" { return nil }

        guard let stroke = set.stroke, let distance = set.distance else {
            return nil
        }

        // ── Layer 1: recorded stats ─────────────────────────────────
        // Filter further to this (set, intensity, gear, swimmer). The
        // caller (SessionStartViewModel) fetches recorded_times once for
        // ALL selected swimmers (one parallel query, in-memory filter
        // after) and passes the full list here for performance. So we
        // MUST filter by swimmer.id inside the predictor — otherwise
        // every swimmer's prediction would be based on the entire
        // cohort's data, not their own.
        //
        // Bug caught in v1: previously filtered by set + intensity + gear
        // but NOT by swimmer. With 8 swimmers all sharing the same set
        // in a session, fitCurve was being called with 8× the data
        // per call, producing identical "average" predictions for every
        // swimmer. The two-group-of-4 29.5s/39.5s pattern in the wave
        // preview was a 10s send-off offset on top of a single shared
        // Alice-PB * moderate-intensity prediction.
        //
        // We use a manual loop because the iOS 17
        // `Sequence.filter(_:)` overload that takes a `Predicate<Element>`
        // wins overload resolution against the closure version when both
        // are in scope. A for-loop sidesteps the ambiguity.
        //
        // Note: `RecordedTime` does not store stroke/distance directly —
        // those come from the joined `WorkoutSet`. The match here is by
        // `workoutSetId` (which implicitly covers stroke+distance) plus
        // intensity, gear, and swimmer. v2 of RecordedTime could add
        // stroke/distance columns to enable a 5-way match, but the
        // 4-way match is correct given the current schema.
        let setIntensity = set.intensityLabel ?? "race"
        let setGear = set.gear ?? ""
        var exact: [RecordedTime] = []
        for rt in recordedTimes {
            if rt.workoutSetId == set.id
                && rt.swimmerId == swimmer.id
                && rt.intensity == setIntensity
                && (rt.gear ?? "") == setGear {
                exact.append(rt)
            }
        }

        if exact.count >= Self.minSamplesForHistorical {
            // Sort by created_at DESC (most recent first), take last 5
            // The data is assumed pre-sorted by the caller, but be safe
            let sorted = exact.sorted { ($0.createdAt) > ($1.createdAt) }
            let recent = Array(sorted.prefix(Self.minSamplesForHistorical))
            let times = recent.map { $0.timeMs }

            let meanMs: Int
            switch prefs.predictionAlgorithm {
            case .median:
                meanMs = Self.median(times)
            case .ema:
                meanMs = Self.ema(times, alpha: Self.defaultEMAAlpha)
            }

            let sigma = max(Self.sampleStdDev(times), Self.sigmaFloorMs)

            return Prediction(
                timeMs: meanMs,
                sigmaMs: sigma,
                sampleSize: sorted.count,
                source: .historical,
                maturity: Self.tierFor(sampleCount: sorted.count)
            )
        }

        // ── Layer 2: speed curve from PBs ───────────────────────────
        // CRITICAL: filter to THIS swimmer's PBs only. Previously this
        // filter was just `pbs.filter { $0.stroke == stroke }` which
        // pulled in PBs for every swimmer in the cohort. With multiple
        // swimmers sharing the same stroke (the common case), fitCurve
        // would fit a SINGLE curve to the entire cohort's PBs and every
        // swimmer would get the same prediction (modulo wave send-off).
        // See the Layer 1 fix above for the full bug story.
        let strokePBs = pbs.filter { $0.stroke == stroke && $0.swimmerId == swimmer.id }
        if let curve = SpeedCurveFitter.fitCurve(pbs: strokePBs),
           let racePace = SpeedCurveFitter.predictRacePace(curve: curve, distance: distance) {
            let intMult = Self.intensityMultiplier(set.intensityLabel ?? "race")
            let gearMult = Self.gearMultiplier(set.gear)
            let timeMs = Int((Double(racePace) * intMult * gearMult).rounded())
            let sigmaFrac = Self.stddevFraction(for: distance)
            let sigma = max(Int((Double(timeMs) * sigmaFrac).rounded()), 100)
            return Prediction(
                timeMs: timeMs,
                sigmaMs: sigma,
                sampleSize: strokePBs.count,
                source: .curve,
                maturity: .none   // PB-based, not "real" data
            )
        }

        // ── Layer 3: population average (cold start) ──────────────
        let speedMps = Self.populationSpeed(for: stroke)
        let racePaceMs = (Double(distance) / speedMps) * 1000
        let intMult = Self.intensityMultiplier(set.intensityLabel ?? "race")
        let gearMult = Self.gearMultiplier(set.gear)
        let timeMs = Int((racePaceMs * intMult * gearMult).rounded())
        let sigma = max(Int((Double(timeMs) * 0.10).rounded()), 200)
        return Prediction(
            timeMs: timeMs,
            sigmaMs: sigma,
            sampleSize: 0,
            source: .seed,
            maturity: .none
        )
    }

    // MARK: - Algorithm primitives

    /// Median of a non-empty integer array. Even-count: average of the
    /// two middle values. Robust to one-off outliers (the kind where
    /// a swimmer had a bad push-off or got distracted).
    static func median(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let n = sorted.count
        if n % 2 == 1 {
            return sorted[n / 2]
        } else {
            // Average the two middle values, rounded to nearest int
            return Int((Double(sorted[n / 2 - 1] + sorted[n / 2]) / 2.0).rounded())
        }
    }

    /// Exponentially-weighted mean. Most-recent-weighted-highest.
    /// For 5 values with α=0.3, the most recent gets weight 0.3, the
    /// next 0.21, then 0.147, 0.103, 0.072. Half-life ~2 swims.
    static func ema(_ values: [Int], alpha: Double) -> Int {
        guard !values.isEmpty else { return 0 }
        // values is assumed ordered most-recent-first
        // Process oldest to newest
        var result = Double(values.last!)
        for v in values.dropLast().reversed() {
            result = alpha * Double(v) + (1.0 - alpha) * result
        }
        return Int(result.rounded())
    }

    /// Sample standard deviation (n-1 denominator).
    /// Returns 0 if the values are all identical.
    static func sampleStdDev(_ values: [Int]) -> Int {
        guard values.count >= 2 else { return 0 }
        let n = Double(values.count)
        let mean = Double(values.reduce(0, +)) / n
        let sumSq = values.reduce(0.0) { $0 + pow(Double($1) - mean, 2) }
        let variance = sumSq / (n - 1)
        return Int(variance.squareRoot().rounded())
    }

    /// Map a sample count to the maturity tier the coach sees in the UI.
    /// Per Nathan's 2026-06-14 call: 5+ uses historical. Tier display:
    /// 1-5 = learning, 6-15 = reliable, 16+ = excellent, 0 = none.
    /// Note the 5+ vs 1-5 split is intentional — the engine uses the
    /// data at 5+, but the tier display starts at 1 to reflect that
    /// even 1 sample is "the engine has data for this swimmer."
    static func tierFor(sampleCount: Int) -> Prediction.Maturity {
        if sampleCount == 0  { return .none }
        if sampleCount <= 5  { return .learning }
        if sampleCount <= 15 { return .reliable }
        return .excellent
    }

    // MARK: - Constants (port of v2 `constants.ts`)

    /// Gear penalties. > 1.0 = slower, < 1.0 = faster.
    /// These are cold-start universals. Per-swimmer calibration is v2.
    static func gearMultiplier(_ gear: String?) -> Double {
        guard let gear = gear, !gear.isEmpty else { return 1.0 }
        switch gear {
        case "paddles":    return 1.05   // 5% slower
        case "pull_buoy":  return 1.03   // 3% slower
        case "fins":       return 0.88   // 12% faster
        case "kickboard":  return 1.04   // 4% slower
        case "dragSuit":   return 1.10   // 10% slower
        default:           return 1.0
        }
    }

    /// Intensity multiplier vs race-pace (baseline = 1.00).
    /// Applied to the race-pace expected time to get training effort time.
    /// Layer 2/3 only — Layer 1 has intensity baked into the recorded mean.
    static func intensityMultiplier(_ intensity: String) -> Double {
        switch intensity {
        case "easy":     return 1.25
        case "moderate": return 1.10
        case "hard":     return 1.03
        case "race":     return 1.00
        default:         return 1.10   // unknown → moderate default
        }
    }

    /// Training variance as a fraction of mean, by distance.
    /// Sprint distances are tighter (good push-off repeatability),
    /// distance events are looser (more variance per attempt).
    /// For distances between entries, interpolate linearly.
    static func stddevFraction(for distance: Int) -> Double {
        let table: [(Int, Double)] = [
            (25,   0.030),
            (50,   0.050),
            (100,  0.060),
            (200,  0.080),
            (400,  0.100),
            (800,  0.120),
            (1500, 0.150),
        ]
        if let exact = table.first(where: { $0.0 == distance }) {
            return exact.1
        }
        // Below the table: use the lowest
        if distance < table.first!.0 { return table.first!.1 }
        // Above the table: use the highest
        if distance > table.last!.0 { return table.last!.1 }
        // Between entries: linear interpolation
        for i in 0..<(table.count - 1) {
            let (lo, loFrac) = table[i]
            let (hi, hiFrac) = table[i + 1]
            if distance > lo && distance < hi {
                let t = Double(distance - lo) / Double(hi - lo)
                return loFrac * (1.0 - t) + hiFrac * t
            }
        }
        return 0.10  // fallback
    }

    /// Population-average race-pace speed (m/s) for adult competitive
    /// swimmers. Used for Layer 3 cold-start only.
    static func populationSpeed(for stroke: String) -> Double {
        switch stroke {
        case "Free":    return 1.45   // ~69s/100m
        case "Back":    return 1.35   // ~74s/100m
        case "Breast":  return 1.30   // ~77s/100m
        case "Fly":     return 1.38   // ~72s/100m
        case "IM":      return 1.35
        default:        return 1.35
        }
    }
}
