import Foundation

/// Coach — mirrors coaches table in Postgres.
/// Auth UID is stored separately (not in the coaches table itself).
/// CodingKeys maps Swift camelCase to Postgres snake_case.
struct Coach: Codable, Identifiable, Sendable {
    let id: String
    var name: String?
    var poolUnits: String?
    var onboardingCompletedAt: String?
    var authId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case poolUnits = "pool_units"
        case onboardingCompletedAt = "onboarding_completed_at"
        case authId = "auth_id"
    }
}

/// Team — coaches can create teams for group management.
struct Team: Codable, Identifiable, Sendable {
    let id: String
    let coachId: String
    var name: String
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case coachId = "coach_id"
        case name
        case createdAt = "created_at"
    }
}