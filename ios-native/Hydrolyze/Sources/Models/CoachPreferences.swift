import Foundation

/// CoachPreferences — per-coach UI and prediction-algorithm settings.
///
/// Persisted to `coaches.preferences` JSONB column in Supabase (one
/// migration covers both the v2 confidence-% display toggle and the
/// v2 prediction-algorithm picker). Read by `AuthManager` on sign-in;
/// falls back to default if the column is missing or the JSON is malformed.
///
/// Settings are mutable from the Profile view. The v2 design has the
/// toggle live in Profile settings, consistent with the
/// user-preference pattern in modern iOS apps.
struct CoachPreferences: Codable, Equatable, Sendable {
    /// Show the per-row confidence percentage in the review screen.
    /// When false, the row's color and the "Needs Review" tab logic
    /// stay the same — only the numeric `XX%` text is hidden.
    /// Default ON (dev preference; can be turned off in v2 production).
    var showConfidencePercent: Bool

    /// Which algorithm the HistoricalTimePredictor uses to compute
    /// the mean from the last 5 recorded_times.
    /// `.median` is the simple, robust default. `.ema` is the
    /// trend-aware variant for coaches who want form weighting.
    var predictionAlgorithm: PredictionAlgorithm

    /// V0.52.6 (2026-09-27): "stats for nerds" toggle. Gates the
    /// per-row σ (z-score) detail lines on the SessionReview screen
    /// — the loud amber variance hint for likelyWrong rows AND the
    /// subtle gray hint for likelyCorrect rows. Default OFF so the
    /// standard coach sees a clean review surface; the analytics-
    /// curious coach flips it on in Profile to inspect σ.
    var showAdvancedStats: Bool

    init(
        showConfidencePercent: Bool = true,
        predictionAlgorithm: PredictionAlgorithm = .median,
        showAdvancedStats: Bool = false
    ) {
        self.showConfidencePercent = showConfidencePercent
        self.predictionAlgorithm = predictionAlgorithm
        self.showAdvancedStats = showAdvancedStats
    }

    /// Coding keys for the Supabase JSONB column. Snake-case to match
    /// the rest of the iOS app's Postgres column conventions.
    enum CodingKeys: String, CodingKey {
        case showConfidencePercent = "show_confidence_percent"
        case predictionAlgorithm = "prediction_algorithm"
        case showAdvancedStats = "show_advanced_stats"
    }

    /// V0.52.6 (2026-09-27): tolerant decoder. Existing coaches on
    /// production already have a `coaches.preferences` JSONB row
    /// that was written before this field existed; using the
    /// synthesized init would throw `keyNotFound` on those rows
    /// and force every existing coach to re-save their prefs. We
    /// `decodeIfPresent` so a missing key coerces to the default
    /// (false), keeping the schema additive without a migration.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.showConfidencePercent = try c.decodeIfPresent(Bool.self, forKey: .showConfidencePercent) ?? true
        self.predictionAlgorithm   = try c.decodeIfPresent(PredictionAlgorithm.self, forKey: .predictionAlgorithm) ?? .median
        self.showAdvancedStats     = try c.decodeIfPresent(Bool.self, forKey: .showAdvancedStats) ?? false
    }

    /// Default preferences (no saved settings yet, or column missing).
    static let `default` = CoachPreferences()
}

/// Algorithm choice for the HistoricalTimePredictor.
///
/// The two algorithms have meaningfully different behavior:
/// - `.median` is robust to one-off bad swims (the kind where the
///   swimmer had a bad push-off, got distracted, etc.). Stable.
/// - `.ema` is trend-aware — recent swims weighted higher. Captures
///   form direction. More sensitive to recent outliers.
///
/// Default is `.median` per Nathan's locked design. Coach can switch
/// in Profile settings.
enum PredictionAlgorithm: String, Codable, CaseIterable, Sendable {
    case median
    case ema

    /// Human-readable label for the Profile picker.
    var displayName: String {
        switch self {
        case .median: return "Median of last 5"
        case .ema:    return "EMA (trend-aware)"
        }
    }
}
