import Foundation

/// Prediction — what the pairing engine expects a swimmer to swim for a given set.
///
/// Returned by `HistoricalTimePredictor.predict(...)`. The pairing engine uses
/// `timeMs` to build predicted touches; the pairing cost function uses `sigmaMs`
/// as the standard deviation in the velocity-space Z-score. `sampleSize` and
/// `maturity` are surfaced in the UI as "predicted from N swims" / tier badges
/// so the coach can see at a glance how confident the engine is.
struct Prediction: Equatable, Sendable {
    /// Predicted mean time (ms).
    let timeMs: Int

    /// Standard deviation (ms). Floor of 1500ms in Layer 1 to prevent
    /// overconfident costs from a 1-sample variance estimate.
    let sigmaMs: Int

    /// Number of recorded_times that informed this prediction. 0 for
    /// the .seed (population) layer.
    let sampleSize: Int

    /// Where the expected time came from. Surfaced in the UI as a
    /// "RECORDED" / "PB" / "ESTIMATED" badge.
    let source: Source

    /// Maturity tier derived from sampleSize. Per Nathan's locked design
    /// (2026-06-14): 1-5 = learning, 6-15 = reliable, 16+ = excellent.
    /// 0 = none (PB or seed layer).
    let maturity: Maturity

    /// Where the prediction came from. Drives UI badge text + color.
    enum Source: String, Codable, Sendable, Equatable {
        /// Layer 1: 5+ recorded_times for the exact (swimmer, stroke,
        /// distance, intensity, gear) combo. Mean is computed via
        /// median-of-last-5 OR EMA per CoachPreferences.
        case historical
        /// Layer 2: no recorded data, but the swimmer has PBs for the
        /// stroke. Power-law fit to estimate the set's distance.
        case curve
        /// Layer 3: no recorded data, no PBs. Population average
        /// for the stroke.
        case seed
    }

    /// Maturity tier for UI display. NOT used by the pairing engine
    /// algorithm (which uses sampleSize directly) — just for the
    /// coach-facing badge.
    enum Maturity: String, Codable, Sendable, Equatable {
        /// 0 samples (PB or seed layer — not real training data)
        case none
        /// 1-5 samples (engine is learning the swimmer's variance)
        case learning
        /// 6-15 samples (engine is reliable — stddev is meaningful)
        case reliable
        /// 16+ samples (excellent — mean and stddev are both stable)
        case excellent
    }

    /// Human-readable label for the UI badge. Returns nil for .none
    /// (no badge) and a short label for the others.
    var badgeLabel: String? {
        switch (source, maturity) {
        case (.historical, .learning):  return "learning"
        case (.historical, .reliable):  return "\(sampleSize) swims"
        case (.historical, .excellent): return "\(sampleSize) swims · excellent"
        case (.curve, _):                return "PB estimate"
        case (.seed, _):                 return nil  // no badge for cold-start
        case (.historical, .none):       return nil  // shouldn't happen but safe
        }
    }
}
