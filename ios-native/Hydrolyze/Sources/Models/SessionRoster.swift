import Foundation

/// SessionRoster — mirrors session_roster table in Postgres.
/// One row per swimmer per session. Written once at session start when
/// the coach locks attendance. Roster is immutable once locked.
struct SessionRoster: Codable, Identifiable, Hashable {
    let id: String
    let sessionId: String
    let swimmerId: String
    var lane: Int?
    var positionInLane: Int?
    let attendanceMarkedAt: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case swimmerId = "swimmer_id"
        case lane
        case positionInLane = "position_in_lane"
        case attendanceMarkedAt = "attendance_marked_at"
        case createdAt = "created_at"
    }
}