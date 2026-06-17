import Foundation

/// Swimmer — mirrors swimmers table in Postgres.
/// Groups are fetched separately via swimmer_groups join table.
/// Extended at fetch time with `.groups: [CoachGroup]` via fetchSwimmersWithGroups.
struct Swimmer: Codable, Identifiable, Sendable {
    let id: String
    let coachId: String
    var firstName: String
    var lastName: String?
    var birthdate: String?
    var gender: String?
    var notes: String?
    var preferredGear: String?
    var formStroke: String?
    var mainStroke: String?
    var archivedAt: String?
    var createdAt: String?
    /// Groups this swimmer belongs to — populated at fetch time, not a DB column.
    var groups: [CoachGroup] = []

    enum CodingKeys: String, CodingKey {
        case id
        case coachId = "coach_id"
        case firstName = "first_name"
        case lastName = "last_name"
        case birthdate
        case gender
        case notes
        case preferredGear = "preferred_gear"
        case formStroke = "form_stroke"
        case mainStroke = "main_stroke"
        case archivedAt = "archived_at"
        case createdAt = "created_at"
    }

    var fullName: String {
        if let lastName = lastName, !lastName.isEmpty {
            return "\(firstName) \(lastName)"
        }
        return firstName
    }
}

extension Swimmer {
    /// Main stroke options — the swimmer's primary competitive event.
    /// Free is the most common event, so it's allowed. Excludes "Form" because that's not a competitive event.
    static let mainStrokeOptions = ["Free", "Back", "Breast", "Fly", "IM"]

    /// Form stroke options — the stroke the coach uses to develop technique.
    /// Per the VISION: NEVER includes Free (form work in Free doesn't develop weaknesses;
    /// every swimmer already has Free technique). "Form" is the generic form-focus option.
    static let formStrokeOptions = ["Back", "Breast", "Fly", "IM", "Form"]
}

/// SwimmerGroup — join table for swimmer-to-group relationship.
struct SwimmerGroup: Codable, Identifiable, Sendable {
    let id: String
    let name: String
}

/// CoachGroup — coach-defined swimmer groups.
struct CoachGroup: Codable, Identifiable, Sendable {
    let id: String
    let coachId: String
    var name: String

    enum CodingKeys: String, CodingKey {
        case id
        case coachId = "coach_id"
        case name
    }
}

/// Personal best for a specific (swimmer, distance, stroke, gear) combination.
struct SwimmerPB: Codable, Identifiable, Sendable {
    let id: String
    let swimmerId: String
    let distance: Int
    let stroke: String
    let timeMs: Int
    let gear: String?
    /// PHASE 2.6 v1.13.0: Added via the swimmer_pbs schema migration.
    /// Stores the intensity the PB was set at ('max' for race PBs,
    /// 'moderate' for training PBs, etc.). The 5-way match
    /// (swimmer, stroke, distance, intensity, gear) is the
    /// canonical lookup key for the predictor. PBs default to 'max'
    /// for legacy rows that pre-date the migration.
    let intensity: String?
    let recordedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case swimmerId = "swimmer_id"
        case distance
        case stroke
        case timeMs = "time_ms"
        case gear
        case intensity
        case recordedAt = "recorded_at"
    }

    init(id: String, swimmerId: String, distance: Int, stroke: String,
         timeMs: Int, gear: String?, intensity: String?, recordedAt: String) {
        self.id = id
        self.swimmerId = swimmerId
        self.distance = distance
        self.stroke = stroke
        self.timeMs = timeMs
        self.gear = gear
        self.intensity = intensity
        self.recordedAt = recordedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        swimmerId = try c.decode(String.self, forKey: .swimmerId)
        distance = try c.decode(Int.self, forKey: .distance)
        stroke = try c.decode(String.self, forKey: .stroke)
        timeMs = try c.decode(Int.self, forKey: .timeMs)
        gear = try c.decodeIfPresent(String.self, forKey: .gear)
        // PHASE 2.6 v1.13.0: tolerate missing intensity column on
        // older row snapshots (defensive — migration backfills it
        // server-side, but the Swift decoder should still handle
        // the rare case where the column hasn't been read yet).
        intensity = try c.decodeIfPresent(String.self, forKey: .intensity)
        recordedAt = try c.decode(String.self, forKey: .recordedAt)
    }
}
