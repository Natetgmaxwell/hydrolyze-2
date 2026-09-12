import Foundation

/// Stroke types — matches the allowed values in workout_sets.stroke.
/// Using a String type alias for simplicity (Swift enum stored as String in DB).
enum Stroke: String, Codable, Sendable, CaseIterable {
    case free = "Free"
    case back = "Back"
    case breast = "Breast"
    case fly = "Fly"
    case im = "IM"
    case form = "Form"

    /// Display name for UI.
    var displayName: String { rawValue }
}

/// Gear types — matches workout_sets.gear column.
enum Gear: String, Codable, Sendable, CaseIterable {
    case none = "none"
    case paddles = "paddles"
    case pullBuoy = "pull_buoy"
    case fins = "fins"
    case kickboard = "kickboard"
    case dragSuit = "dragSuit"

    var displayName: String {
        switch self {
        case .none: return "No gear"
        case .paddles: return "Paddles"
        case .pullBuoy: return "Pull buoy"
        case .fins: return "Fins"
        case .kickboard: return "Kickboard"
        case .dragSuit: return "Drag suit"
        }
    }
}

/// Intensity levels for training prescription.
/// Used in intensityPattern on WorkoutSet and in the pairing algorithm.
enum IntensityLevel: String, Codable, Sendable, CaseIterable {
    case easy
    case moderate
    case hard
    case race

    /// Multiplier applied to a swimmer's PB to get expected training pace.
    /// Matches the values in the RN app's INTENSITY_MULTIPLIERS.
    var multiplier: Double {
        switch self {
        case .easy: return 1.25
        case .moderate: return 1.10
        case .hard: return 1.03
        case .race: return 1.00
        }
    }

    var displayName: String {
        switch self {
        case .easy: return "Easy"
        case .moderate: return "Moderate"
        case .hard: return "Hard"
        case .race: return "Race pace"
        }
    }
}

/// WorkoutFilter — filter options for the workouts list.
enum WorkoutFilter: String, CaseIterable {
    case all
    case scheduled
    case draft
    case complete
}