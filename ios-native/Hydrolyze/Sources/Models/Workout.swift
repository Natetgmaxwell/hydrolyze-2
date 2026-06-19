import Foundation

/// WorkoutStatus — corresponds to the CHECK constraint in Postgres.
enum WorkoutStatus: String, Codable, Sendable {
    case draft
    case scheduled
    case inProgress = "in_progress"
    case complete
}

/// Workout — mirrors workouts table in Postgres.
struct Workout: Codable, Identifiable, Sendable {
    let id: String
    let coachId: String
    var title: String?
    var description: String?
    var scheduledAt: String?
    var amPm: String?
    var completedAt: String?
    var status: WorkoutStatus
    var createdAt: String
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case coachId = "coach_id"
        case title
        case description = "workout_text"
        case scheduledAt = "scheduled_at"
        case amPm = "am_pm"
        case completedAt = "completed_at"
        case status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// WorkoutSet — ordered set components within a workout.
/// Corresponds to workout_sets table.
struct WorkoutSet: Codable, Identifiable, Sendable {
    let id: String
    let workoutId: String
    var orderIndex: Int
    var reps: Int?
    var distance: Int?
    var stroke: String?
    var intervalText: String?
    var intensityType: String?
    var intensityLabel: String?
    var paceTargetDistance: Int?
    var gear: String?
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case workoutId = "workout_id"
        case orderIndex = "order_index"
        case reps
        case distance
        case stroke
        case intervalText = "interval_text"
        case intensityType = "intensity_type"
        case intensityLabel = "intensity_label"
        case paceTargetDistance = "pace_target_distance"
        case gear
        case createdAt = "created_at"
    }

    /// Human-readable label, e.g. "4×100 Free @ threshold"
    var label: String {
        var parts: [String] = []
        if let reps = reps, let distance = distance {
            parts.append("\(reps)×\(distance)m")
        } else if let distance = distance {
            parts.append("\(distance)m")
        }
        if let stroke = stroke { parts.append(stroke) }
        if let intensityLabel = intensityLabel { parts.append("@ \(intensityLabel)") }
        return parts.isEmpty ? "Set" : parts.joined(separator: " ")
    }
}