import Foundation

/// CoachVocabulary — one row of the coach's natural-language → RPE
/// mapping. Per the v1.14 plan (see
/// `originals/rpe-nomenclature-for-hydrolyze-intensity`):
///   - Each coach has their own vocabulary (different coaches mean
///     different things by "moderate")
///   - The parser looks up this table first when it sees an
///     ambiguous term in a workout description
///   - If mapped, use the RPE silently
///   - If not mapped, prompt the coach to pick an RPE
///
/// PHASE 2.6 v1.14.0: introduced per the user's RPE direction
/// (2026-06-16).
struct CoachVocabulary: Codable, Identifiable, Sendable {
    let id: String
    let coachId: String
    let userTerm: String
    /// The RPE the term maps to. Stored as text (e.g., "RPE6-7",
    /// "RPE10") to support ranges without losing the canonical
    /// form. Parsed via `RPEParser.parse` when the predictor
    /// needs a numeric range.
    let rpe: String
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case coachId = "coach_id"
        case userTerm = "user_term"
        case rpe
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(id: String, coachId: String, userTerm: String, rpe: String,
         createdAt: String, updatedAt: String) {
        self.id = id
        self.coachId = coachId
        self.userTerm = userTerm
        self.rpe = rpe
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        coachId = try c.decode(String.self, forKey: .coachId)
        userTerm = try c.decode(String.self, forKey: .userTerm)
        rpe = try c.decode(String.self, forKey: .rpe)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
            ?? ISO8601DateFormatter().string(from: Date())
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
            ?? ISO8601DateFormatter().string(from: Date())
    }
}
