import Foundation

/// CoachAttendanceEntry — the coach-side view of one swimmer's attendance
/// for a workout.
///
/// v1.17 Slice 4: `intent` (the raw row, often nil) is no longer what the
/// UI counts. `isAttending` + `reason` come from AttendanceResolver, so a
/// swimmer on a standing Mon/Wed/Fri pattern is counted as attending
/// without ever having marked anything. Before this, the Today badge
/// counted `intent == "in"` and reported a squad of standing-schedule
/// swimmers as "0 of 12 attending" — the feature's whole premise inverted.
///
/// `intent` is retained because the coach's override pills need to know
/// whether an explicit row already exists.
struct CoachAttendanceEntry: Identifiable, Hashable {
    let swimmerId: String
    let swimmerName: String
    let intent: String?        // nil = no explicit row
    let markedAt: String?
    let isAttending: Bool      // resolved: explicit > standing > out
    let reason: AttendanceResolver.Reason

    var id: String { swimmerId }

    /// What the coach sees under the swimmer's name in the popover.
    /// Deliberately the coach's own vocabulary — no "intent", no "state".
    var provenanceLabel: String {
        switch reason {
        case .explicitIn:   return "said they're in"
        case .explicitOut:  return "can't make it"
        case .standingSlot: return "usual session"
        case .noSignal:     return "not marked"
        }
    }
}

/// The resolved attendance split for a workout — what the coach's badge
/// counts and what the session-start picker seeds from.
struct ResolvedAttendance {
    let entries: [CoachAttendanceEntry]

    var attending: [CoachAttendanceEntry] { entries.filter(\.isAttending) }
    var attendingIds: [String] { attending.map(\.swimmerId) }
    var attendingCount: Int { attending.count }
    var totalCount: Int { entries.count }

    /// True when nobody has any signal at all — every swimmer fell through
    /// to "not marked". This is the condition the session-start fallback
    /// keys on (Slice 5). Deliberately distinct from "everyone declined",
    /// which is a real answer and must NOT trigger the fallback.
    var hasNoSignal: Bool {
        !entries.isEmpty && entries.allSatisfy { $0.reason == .noSignal }
    }
}

/// Why resolved attendance couldn't be computed.
enum AttendanceError: LocalizedError {
    /// The workout has no usable `scheduled_at`, so it can't be matched
    /// against a weekday pattern. Real shape in this database — an
    /// in_progress workout that never got a date.
    case unschedulable(workoutId: String)

    var errorDescription: String? {
        switch self {
        case .unschedulable:
            return "This workout has no date set, so attendance can't be worked out."
        }
    }
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

    /// Resolved attendance for a workout — one entry per swimmer on the
    /// squad, with standing schedules folded in.
    ///
    /// v1.17 Slice 4. Three reads in parallel (swimmers, intents,
    /// schedules) plus the workout's own date, then one pass through
    /// AttendanceResolver. Previously this returned raw intent rows and the
    /// caller counted `intent == "in"`, which meant a squad running entirely
    /// on standing schedules read as "0 attending".
    ///
    /// Throws `AttendanceError.unschedulable` when the workout has no usable
    /// `scheduled_at`. That is a real shape in this database (an in_progress
    /// workout that never got a date) and it cannot be resolved against a
    /// weekday pattern — guessing would silently match the wrong slot.
    func fetchResolvedAttendance(forWorkoutId workoutId: String) async throws -> ResolvedAttendance {
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
        struct WorkoutDate: Decodable {
            let scheduledAt: String?
            let amPm: String?
            enum CodingKeys: String, CodingKey {
                case scheduledAt = "scheduled_at"
                case amPm = "am_pm"
            }
        }

        async let squadFetch = client
            .from("swimmers")
            .select("id, first_name, last_name")
            .is("archived_at", value: nil)
            .execute()
        async let workoutFetch = client
            .from("workouts")
            .select("scheduled_at, am_pm")
            .eq("id", value: workoutId)
            .single()
            .execute()
        async let intentFetch = client
            .from("swimmer_attendance_intent")
            .select("id, workout_id, swimmer_id, intent, marked_at, source")
            .eq("workout_id", value: workoutId)
            .execute()
        // Not filtered by swimmer: the coach legitimately needs every one of
        // their swimmers' standing patterns to resolve the whole squad. RLS
        // (`coach_manage_swimmer_schedules`) already scopes this to swimmers
        // belonging to the signed-in coach.
        async let scheduleFetch = client
            .from("swimmer_training_schedule")
            .select("id, swimmer_id, weekday, am_pm, active")
            .execute()

        let decoder = JSONDecoder()
        let squad = try decoder.decode([SquadSwimmer].self, from: try await squadFetch.data)
        let workoutDate = try decoder.decode(WorkoutDate.self, from: try await workoutFetch.data)
        let intents = try decoder.decode(
            [SwimmerAttendanceIntent].self, from: try await intentFetch.data)
        let schedules = try decoder.decode(
            [SwimmerTrainingSchedule].self, from: try await scheduleFetch.data)

        guard
            let scheduledAt = workoutDate.scheduledAt,
            let context = AttendanceResolver.WorkoutContext(
                workoutId: workoutId,
                scheduledAt: scheduledAt,
                amPm: workoutDate.amPm
            )
        else {
            throw AttendanceError.unschedulable(workoutId: workoutId)
        }

        // The unique key is (workout_id, swimmer_id) and we filtered to one
        // workout, so at most one row per swimmer. No arbitrary collapse.
        let intentBySwimmer = Dictionary(
            uniqueKeysWithValues: intents.map { ($0.swimmerId, $0) }
        )

        let entries = squad.map { s -> CoachAttendanceEntry in
            let resolution = AttendanceResolver.resolve(
                swimmerId: s.id,
                workout: context,
                intents: intents,
                schedule: schedules
            )
            let fullName = [s.firstName, s.lastName ?? ""]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return CoachAttendanceEntry(
                swimmerId: s.id,
                swimmerName: fullName,
                intent: intentBySwimmer[s.id]?.intent,
                markedAt: intentBySwimmer[s.id]?.markedAt,
                isAttending: resolution.isAttending,
                reason: resolution.reason
            )
        }
        .sorted { $0.swimmerName.localizedCaseInsensitiveCompare($1.swimmerName) == .orderedAscending }

        return ResolvedAttendance(entries: entries)
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

    /// Promote everyone resolved as attending into `session_roster`, and
    /// return the swimmer IDs promoted.
    ///
    /// v1.17 Slice 4, two changes:
    ///
    /// 1. **Resolver-driven, not `intent='in'`.** The old version selected
    ///    rows where `intent = 'in'`, so a squad running entirely on standing
    ///    schedules promoted *nobody* — the roster came out empty and the
    ///    feature silently did nothing.
    ///
    /// 2. **Returns `[String]` instead of Void.** Slice 5 needs the promoted
    ///    set to seed `selectedSwimmerIds`; without a return value the
    ///    promotion writes into a branch nothing downstream reads in time,
    ///    which is exactly why intent never reached the pairing engine.
    ///
    /// `session_roster` has UNIQUE(session_id, swimmer_id), so a repeated
    /// promote is idempotent.
    @discardableResult
    func promoteConfirmedToRoster(workoutId: String, sessionId: String) async throws -> [String] {
        let resolved = try await fetchResolvedAttendance(forWorkoutId: workoutId)
        let attendingIds = resolved.attendingIds
        guard !attendingIds.isEmpty else { return [] }

        struct RosterPayload: Encodable {
            let session_id: String
            let swimmer_id: String
        }
        let payloads = attendingIds.map {
            RosterPayload(session_id: sessionId, swimmer_id: $0)
        }
        _ = try await client
            .from("session_roster")
            .upsert(payloads, onConflict: "session_id,swimmer_id")
            .execute()

        return attendingIds
    }
}