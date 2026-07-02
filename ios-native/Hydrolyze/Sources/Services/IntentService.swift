import Foundation

/// SwimmerAttendanceIntent — the swimmer's self-marked attendance
/// for an upcoming session. Rows live in the `swimmer_attendance_intent`
/// table; the coach promotes confirmed intents into `session_roster`
/// at session start (separate client-side flow).
///
/// See originals/hydrolyze-coach-self-mark-attendance-v1 for the
/// design rationale. RLS: swimmers write their own rows, coaches
/// override rows in their own sessions.
struct SwimmerAttendanceIntent: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let sessionId: String
    let swimmerId: String
    let intent: String          // "in" | "out"
    let markedAt: String        // ISO8601
    let source: String          // "swimmer" | "coach"

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case swimmerId = "swimmer_id"
        case intent
        case markedAt = "marked_at"
        case source
    }
}

/// UpcomingSession — the swimmer-side view model for sessions in the
/// next 7 days. Bundles the session with the swimmer's current
/// intent (if any) so the Upcoming tab can render one row per
/// session without a join on the client.
struct UpcomingSession: Identifiable, Hashable {
    let id: String              // session_id
    let date: String            // ISO8601 start_at
    let slot: String            // "AM" | "PM" (derived)
    let swimmerCount: Int
    let myIntent: String?       // nil if not yet marked

    var hasMarked: Bool { myIntent != nil }
}

/// IntentService — wraps the Supabase calls for the
/// `swimmer_attendance_intent` table. Single source of truth for
/// what the iOS app sends. The Upcoming tab calls these directly;
/// no view-model layer needed (the data shape is small enough).
///
/// ponytail: this is the only file the Upcoming tab needs. The
/// `from().upsert(...)` call is the only mutating surface; the
/// `from().select(...)` is the only read surface. Anything more
/// goes in the tab's view-model.
final class IntentService {
    private let client = SupabaseService.shared.client

    /// Fetch all sessions for the next 7 days, joined with the
    /// swimmer's own intent row (if any). Single round-trip via
    /// the `sessions` table; the join is client-side.
    ///
    /// ponytail: returning `[UpcomingSession]` directly keeps the
    /// Upcoming tab's view-model trivial. If we ever need a richer
    /// shape (workout title, set count), promote the helper.
    func fetchUpcomingSessions() async throws -> [UpcomingSession] {
        let now = Date()
        let weekOut = now.addingTimeInterval(7 * 24 * 60 * 60)
        let isoNow = ISO8601DateFormatter().string(from: now)
        let isoOut = ISO8601DateFormatter().string(from: weekOut)

        let sessionsResponse = try await client
            .from("sessions")
            .select("id, scheduled_at, athlete_count")
            .gte("scheduled_at", value: isoNow)
            .lte("scheduled_at", value: isoOut)
            .order("scheduled_at", ascending: true)
            .execute()
        let sessions = try JSONDecoder().decode(
            [SessionRow].self, from: sessionsResponse.data
        )

        guard !sessions.isEmpty else { return [] }

        let ids = sessions.map(\.id)
        let intentResponse = try await client
            .from("swimmer_attendance_intent")
            .select("id, session_id, swimmer_id, intent, marked_at, source")
            .in("session_id", values: ids)
            .execute()
        let intents = try JSONDecoder().decode(
            [SwimmerAttendanceIntent].self, from: intentResponse.data
        )
        let intentBySession = Dictionary(
            intents.map { ($0.sessionId, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return sessions.map { session in
            let myIntent = intentBySession[session.id]
            return UpcomingSession(
                id: session.id,
                date: session.scheduledAt,
                slot: Self.slotLabel(for: session.scheduledAt),
                swimmerCount: session.athleteCount ?? 0,
                myIntent: myIntent?.intent
            )
        }
    }

    /// Mark this swimmer's intent for a session. Upsert — calling
    /// twice with different intents just updates the row.
    func markIntent(sessionId: String, swimmerId: String, intent: String) async throws {
        struct Payload: Encodable {
            let session_id: String
            let swimmer_id: String
            let intent: String
            let source: String
        }
        let payload = Payload(
            session_id: sessionId,
            swimmer_id: swimmerId,
            intent: intent,
            source: "swimmer"
        )
        _ = try await client
            .from("swimmer_attendance_intent")
            .upsert(payload, onConflict: "session_id,swimmer_id")
            .execute()
    }

    /// Cancel a prior mark (the swimmer changes their mind back to
    /// unmarked). Distinct from `markIntent(_, _, "out")` because
    /// "out" is a *positive* decision; "unmarked" removes the row.
    func clearIntent(sessionId: String, swimmerId: String) async throws {
        _ = try await client
            .from("swimmer_attendance_intent")
            .delete()
            .eq("session_id", value: sessionId)
            .eq("swimmer_id", value: swimmerId)
            .execute()
    }

    // MARK: - helpers

    private static func slotLabel(for iso: String) -> String {
        guard let date = ISO8601DateParser.parse(iso) else { return "—" }
        let hour = Calendar.current.component(.hour, from: date)
        return hour < 12 ? "AM" : "PM"
    }

    /// Wire shape for the sessions select — narrower than the
    /// full SessionRoster model. Keeps the read lean.
    private struct SessionRow: Decodable {
        let id: String
        let scheduledAt: String
        let athleteCount: Int?

        enum CodingKeys: String, CodingKey {
            case id
            case scheduledAt = "scheduled_at"
            case athleteCount = "athlete_count"
        }
    }
}