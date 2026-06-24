import Foundation

/// WaveAssignment — mirrors wave_assignments table in Postgres.
/// WaveAllocator output: one row per (swimmer, workout_set) per session.
/// Updated if coach drags to override in the wave preview screen.
struct WaveAssignment: Codable, Identifiable, Hashable {
    let id: String
    let sessionId: String
    let swimmerId: String
    let workoutSetId: String
    var lane: Int
    var positionInLane: Int
    var predictedTouchMs: Int
    var waveNumber: Int
    var sendOffOffsetMs: Int
    let coachId: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case swimmerId = "swimmer_id"
        case workoutSetId = "workout_set_id"
        case lane
        case positionInLane = "position_in_lane"
        case predictedTouchMs = "predicted_touch_ms"
        case waveNumber = "wave_number"
        case sendOffOffsetMs = "send_off_offset_ms"
        case coachId = "coach_id"
        case createdAt = "created_at"
    }

    var predictedTouchSeconds: Double {
        Double(predictedTouchMs) / 1000.0
    }
}