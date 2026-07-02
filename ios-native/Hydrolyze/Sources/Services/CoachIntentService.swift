import Foundation

/// CoachAttendanceEntry — the coach-side view of a swimmer's
/// self-marked intent for a workout. Joins the swimmer's row
/// with their intent (if any).
///
/// ponytail: same shape as UpcomingWorkout on the swimmer side.
/// The two views can converge later.
struct CoachAttendanceEntry: Identifiable, Hashable {
    let swimmerId: String
    let swimmerName: String
    let intent: String?        // nil = not marked yet
    let markedAt: String?

    var id: String { swimmerId }
}

/// CoachIntentService — the coach-side counterpart of IntentService.
/// Reads intent rows for a workout, lets the coach override
/// (insert/update intent on behalf of a swimmer), and promotes
/// confirmed intents into session_roster at session start.
///
/// ponytail:
///   - The promotion is a single SQL transaction done client-side.
///     The same outcome (inserts into session_roster) would be a
///     stored procedure if we had more time; ponytail says skip it.
///   - The override write path re-uses the same upsert as the
///     swimmer-side. RLS allows the coach to write any row in
///     their own workouts.
final class CoachIntentService {
    private let client = SupabaseService.shared.client

    /// Read all intent rows for a workout, joined with swimmer names.
    /// Returns one row per swimmer on the squad (intent may be nil
    /// for swimmers who haven't marked yet).
    func fetchAttendance(forWorkoutId workoutId: String) async throws -> [CoachAttendanceEntry] {
        // First, get all swimmers on this coach's squad (not filtered
        // by intent — we want unmarked swimmers too).
        // ponytail: this would be cleaner as a server view, but
        // we're keeping the SQL client-side for now.
        struct SquadSwimmer: Decodable {
            let id: String
            let firstName: String
            let lastName: String?
            enum CodingKeys: String, CodingKey {
                case id
                case firstName = "first_name"
                case lastName = "last_name"
            }
        }
        let squadResponse = try await client
            .from("swimmers")
            .select("id, first_name, last_name")
            .is("archived_at", value: nil)
            .execute()
        let squad = try JSONDecoder().decode([SquadSwimmer].self, from: squadResponse.data)

        // Then fetch intent rows for this workout.
        let intentResponse = try await client
            .from("swimmer_attendance_intent")
            .select("id, workout_id, swimmer_id, intent, marked_at, source")
            .eq("workout_id", value: workoutId)
            .execute()
        let intents = try JSONDecoder().decode(
            [SwimmerAttendanceIntent].self, from: intentResponse.data
        )
        let intentBySwimmer = Dictionary(
            intents.map { ($0.swimmerId, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return squad.map { s in
            let intent = intentBySwimmer[s.id]
            let fullName = [s.firstName, s.lastName ?? ""]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return CoachAttendanceEntry(
                swimmerId: s.id,
                swimmerName: fullName,
                intent: intent?.intent,
                markedAt: intent?.markedAt
            )
        }
        .sorted { $0.swimmerName.localizedCaseInsensitiveCompare($1.swimmerName) == .orderedAscending }
    }

    /// Coach overrides a swimmer's intent. Same upsert as the
    /// swimmer-side call; the coach's auth.uid() satisfies
    /// coach_intent_override_policy.
    func setIntent(
        workoutId: String,
        swimmerId: String,
        intent: String
    ) async throws {
        struct Payload: Encodable {
            let workout_id: String
            let swimmer_id: String
            let intent: String
            let source: String
        }
        let payload = Payload(
            workout_id: workoutId,
            swimmer_id: swimmerId,
            intent: intent,
            source: "coach"
        )
        _ = try await client
            .from("swimmer_attendance_intent")
            .upsert(payload, onConflict: "workout_id,swimmer_id")
            .execute()
    }

    /// Promote all intent='in' rows for this workout into
    /// session_roster for the matching session (one workout → one
    /// session per day). Called when the coach taps Start.
    ///
    /// ponytail: read the intent rows, look up the session_id for
    /// this workout, insert into session_roster with a lane/position
    /// placeholder. The WaveAllocator will fill lane/position later;
    /// we just need the attendance rows locked in.
    func promoteConfirmedToRoster(workoutId: String, sessionId: String) async throws {
        let response = try await client
            .from("swimmer_attendance_intent")
            .select("swimmer_id")
            .eq("workout_id", value: workoutId)
            .eq("intent", value: "in")
            .execute()
        struct Row: Decodable { let swimmerId: String
            enum CodingKeys: String, CodingKey { case swimmerId = "swimmer_id" }
        }
        let rows = try JSONDecoder().decode([Row].self, from: response.data)
        guard !rows.isEmpty else { return }

        // Build a single payload array. session_roster has
        // UNIQUE(session_id, swimmer_id) so any pre-existing rows
        // (from a prior promote attempt) are silently skipped via
        // the upsert-on-conflict.
        struct RosterPayload: Encodable {
            let session_id: String
            let swimmer_id: String
        }
        let payloads = rows.map {
            RosterPayload(session_id: sessionId, swimmer_id: $0.swimmerId)
        }
        _ = try await client
            .from("session_roster")
            .upsert(payloads, onConflict: "session_id,swimmer_id")
            .execute()
    }
}