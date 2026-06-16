import Foundation

/// RecordedTime — mirrors recorded_times table in Postgres.
/// Each row = one swimmer's time for one rep of one set.
struct RecordedTime: Codable, Identifiable, Sendable {
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
    }
}