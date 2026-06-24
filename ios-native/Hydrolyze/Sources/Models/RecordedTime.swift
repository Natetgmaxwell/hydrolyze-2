import Foundation

/// RecordedTime — mirrors recorded_times table in Postgres.
/// Each row = one swimmer's time for one rep of one set.
struct RecordedTime: Codable, Identifiable, Sendable, Hashable {
    let id: String
    let sessionId: String?
    let swimmerId: String?
    let workoutSetId: String?
    let workoutId: String?
    let timeMs: Int
    let repIndex: Int
    let intensity: String
    let gear: String?
    let waveNumber: Int
    let paceDistance: Int?
    var createdAt: String
    var lapOrder: Int?
    var pairedSwimmerId: String?
    var confidence: Int?
    /// PHASE 2.6 v1.17.0: DB has this column (text, default 'auto').
    /// 'auto' = engine-paired, 'coachConfirmed' = coach accepted
    /// despite low confidence. The iOS code now decodes it; future
    /// v1.17 work can use it to distinguish engine pairings from
    /// coach overrides (e.g., for analytics, calibration).
    let source: String?
    /// PHASE 2.6 v1.17.0: DB has this column (double precision, the
    /// raw probability 0.0-1.0 that the pairing is correct). The
    /// `confidence` (smallint 0-100) is the integer percentage.
    /// The engine should use assignmentConfidence when present
    /// for finer precision; the v1.16 engine uses confidence
    /// everywhere. Future v1.17 work will switch the cost
    /// function over.
    let assignmentConfidence: Double?
    /// PHASE 2.6 v1.17.0: DB has this column (text, denormalized
    /// from workout_sets.stroke for query convenience). Lets the
    /// review UI show "50m Free" without joining workout_sets on
    /// every render. The v1.14 review UI joins workout_sets for
    /// distance; with stroke on recorded_times, the join
    /// becomes optional.
    let stroke: String?

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case swimmerId = "swimmer_id"
        case workoutSetId = "workout_set_id"
        case workoutId = "workout_id"
        case timeMs = "time_ms"
        case repIndex = "rep_index"
        case intensity
        case gear
        case waveNumber = "wave_number"
        case paceDistance = "pace_distance"
        case createdAt = "created_at"
        case lapOrder = "lap_order"
        case pairedSwimmerId = "paired_swimmer_id"
        case confidence
        case source
        case assignmentConfidence = "assignment_confidence"
        case stroke
    }
}