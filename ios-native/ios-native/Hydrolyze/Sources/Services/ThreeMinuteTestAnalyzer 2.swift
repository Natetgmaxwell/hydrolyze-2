import Foundation

/// ThreeMinuteTestAnalyzer — pure math service for the 3-minute all-out test (3MT).
///
/// The 3MT is a single-bout maximal effort: the swimmer goes all-out from the first
/// push-off and holds maximal effort for 3 minutes (Piatrikova et al. 2019, IJSPP).
/// The resulting speed-vs-time curve has a characteristic shape — **peak → decay →
/// plateau** — and three physiological parameters live in that shape:
///
/// | Number | What it is | Coach vocabulary |
/// |---|---|---|
/// | Peak speed | Fastest 25m split | "Top speed" |
/// | Critical speed (CS) | Mean speed over the final 30s — the plateau | "Threshold pace" |
/// | D′ (battery) | Area above CS under the curve, in meters | "Battery" |
///
/// Math (research doc §1.4, exactly):
///  1. vᵢ = poolLength / tᵢ for each split (m/s)
///  2. peak = max(vᵢ)
///  3. CS = mean speed of splits whose cumulative elapsed time lands in [150s, 180s];
///     if fewer than 2 such splits exist, take the last 2 splits (smoothing)
///  4. battery = Σ (vᵢ − CS) × tᵢ over splits where vᵢ > CS (discrete integral, meters)
///  5. quality flags detect the "didn't go all-out" cases (research doc §1.5)
///
/// Pure function, no DB, no async, no SwiftUI. Same pattern as `WaveAllocator`.
/// Caller (the future 3MT timing flow, Slice 4) supplies the inputs and persists
/// the result via the existing `recorded_times` + new `swimmer_test_profiles` path.
struct ThreeMinuteTestAnalyzer {

    /// Quality flag identifying a problematic trial. String raw values match the
    /// `swimmer_test_profiles.quality_flags jsonb` column (research doc §1.5).
    enum QualityFlag: String, Equatable, Sendable {
        /// Split 1 speed < split 2 or split 3 — didn't go all-out from push-off.
        case pacedStart = "paced_start"
        /// Peak below 95% of `expectedPeakSpeedMps` (supplied by caller from the
        /// swimmer's 25m PB or Layer-2 prediction). Bad start or pacing.
        case peakBelowExpected = "peak_below_expected"
        /// CS ≥ 90% of peak — plateau not plausible; sprinter signature absent.
        /// Typical CS/peak is ~80–90%; flat curve from the start = paced.
        case flatCurve = "flat_curve"
        /// Trials 1 or 2 — familiarisation is mandatory (Piatrikova 2019). Show
        /// the numbers but flag "repeat before using for zones".
        case learningTrial = "learning_trial"
    }

    /// Result struct for the 3MT analysis. Caller persists this to
    /// `swimmer_test_profiles` and renders it in the review surface.
    struct Result: Equatable, Sendable {
        /// Fastest split, converted to m/s.
        let peakSpeedMps: Double
        /// Mean speed over the final 30s plateau window, m/s.
        let criticalSpeedMps: Double
        /// Area under the speed curve above CS, in meters.
        let batteryMeters: Double
        /// Per-split speeds (m/s) in order — for the review-surface plot.
        let curveShape: [Double]
        /// Quality flags from the data-quality checks.
        let qualityFlags: [QualityFlag]
        /// Trial number (1-indexed). Caller supplies — analyzer only flags.
        let trialNumber: Int
    }

    /// Analyze a 3MT trial.
    ///
    /// - Parameters:
    ///   - laps: 25m wall-touch splits with elapsed times. Each `Lap.splitMs` is
    ///     the i-th 25m split (the spec's tᵢ).
    ///   - poolLengthMeters: typically 25 or 50. Used to convert tᵢ → vᵢ.
    ///   - expectedPeakSpeedMps: optional. When supplied, the analyzer flags
    ///     `.peakBelowExpected` if the observed peak is < 95% of this value
    ///     (research doc §1.5.1). Pass nil to skip the check.
    ///   - trialNumber: 1-indexed trial counter (familiarisation). Caller
    ///     increments per swimmer per 3MT session.
    /// - Returns: `nil` if fewer than 3 splits (not enough data). Never crashes.
    static func analyze(
        laps: [Lap],
        poolLengthMeters: Int,
        expectedPeakSpeedMps: Double? = nil,
        trialNumber: Int = 1
    ) -> Result? {
        // Edge case: not enough data.
        guard laps.count >= 3 else { return nil }
        // Edge case: bad pool length — defensive (would divide by zero).
        guard poolLengthMeters > 0 else { return nil }

        let poolLength = Double(poolLengthMeters)

        // 1. Convert each split to speed (m/s). vᵢ = poolLength / (splitMs / 1000)
        var curveShape: [Double] = []
        curveShape.reserveCapacity(laps.count)
        for lap in laps {
            let tSec = Double(lap.splitMs) / 1000.0
            guard tSec > 0 else { return nil }   // defensive — bad split
            let v = poolLength / tSec
            curveShape.append(v)
        }

        // 2. Peak = max(vᵢ)
        guard let peak = curveShape.max() else { return nil }

        // 3. CS = mean speed of splits whose cumulative elapsed time lands in
        //    [150s, 180s]. Cap at the final split. If fewer than 2 such splits,
        //    take the last 2 splits (smoothing per research doc §1.4 note 3).
        let windowStartMs = 150_000
        let inWindowIndices = laps.enumerated().compactMap { idx, lap in
            lap.elapsedMs >= windowStartMs ? idx : nil
        }
        let csIndices: [Int]
        if inWindowIndices.count >= 2 {
            csIndices = inWindowIndices
        } else {
            // Fewer than 2 in window → take the last 2 splits.
            let n = laps.count
            csIndices = [n - 2, n - 1]
        }
        let csSum = csIndices.reduce(0.0) { $0 + curveShape[$1] }
        let cs = csSum / Double(csIndices.count)

        // 4. Battery = Σ (vᵢ − CS) × tᵢ over splits where vᵢ > CS (meters).
        var battery = 0.0
        for (i, lap) in laps.enumerated() {
            let v = curveShape[i]
            if v > cs {
                let tSec = Double(lap.splitMs) / 1000.0
                battery += (v - cs) * tSec
            }
        }
        // Clamp at >= 0 (defensive — the > CS check already ensures non-negative
        // contributions, but rounding noise could produce a tiny negative).
        if battery < 0 { battery = 0 }

        // 5. Quality flags (research doc §1.5).
        var flags: [QualityFlag] = []

        // pacedStart: split 1 speed < split 2 speed OR split 1 speed < split 3 speed.
        // Only meaningful when at least 3 splits exist (which is guaranteed by the
        // guard at the top — count >= 3).
        let v1 = curveShape[0]
        let v2 = curveShape[1]
        let v3 = curveShape[2]
        if v1 < v2 || v1 < v3 {
            flags.append(.pacedStart)
        }

        // peakBelowExpected: only when caller supplied the expected peak AND
        // observed peak < 95% of it.
        if let expected = expectedPeakSpeedMps, expected > 0 {
            if peak < 0.95 * expected {
                flags.append(.peakBelowExpected)
            }
        }

        // flatCurve: CS ≥ 90% of peak (plateau not plausible).
        if peak > 0 && cs / peak >= 0.90 {
            flags.append(.flatCurve)
        }

        // learningTrial: trials 1 or 2 — familiarisation mandatory.
        if trialNumber <= 2 {
            flags.append(.learningTrial)
        }

        return Result(
            peakSpeedMps: peak,
            criticalSpeedMps: cs,
            batteryMeters: battery,
            curveShape: curveShape,
            qualityFlags: flags,
            trialNumber: trialNumber
        )
    }
}
