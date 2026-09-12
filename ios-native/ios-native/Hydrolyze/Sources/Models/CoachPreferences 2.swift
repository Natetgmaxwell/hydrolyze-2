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

    init(
        showConfidencePercent: Bool = true,
        predictionAlgorithm: PredictionAlgorithm = .median
    ) {
        self.showConfidencePercent = showConfidencePercent
        self.predictionAlgorithm = predictionAlgorithm
    }

    /// Coding keys for the Supabase JSONB column. Snake-case to match
    /// the rest of the iOS app's Postgres column conventions.
    enum CodingKeys: String, CodingKey {
        case showConfidencePercent = "show_confidence_percent"
        case predictionAlgorithm = "prediction_algorithm"
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
