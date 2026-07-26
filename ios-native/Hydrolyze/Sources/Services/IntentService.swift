import Foundation

/// SwimmerAttendanceIntent — the swimmer's self-marked attendance
/// for an upcoming workout. Rows live in the `swimmer_attendance_intent`
/// table; the coach promotes confirmed intents into `session_roster`
/// at session start (separate client-side flow).
///
/// References `workout_id` (not `session_id`) because sessions only
/// exist after the coach taps Start. The swimmer needs to mark
/// intent for an upcoming practice BEFORE any session row exists.
///
/// See originals/hydrolyze-coach-self-mark-attendance-v1 for the
/// design rationale. RLS: swimmers write their own rows, coaches
/// override rows in their own workouts.
struct SwimmerAttendanceIntent: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let workoutId: String
    let swimmerId: String
    let intent: String          // "in" | "out"
    let markedAt: String        // ISO8601
    let source: String          // "swimmer" | "coach"

    enum CodingKeys: String, CodingKey {
        case id
        case workoutId = "workout_id"
        case swimmerId = "swimmer_id"
        case intent
        case markedAt = "marked_at"
        case source
    }
}

/// UpcomingWorkout — the swimmer-side view model for a scheduled workout,
/// bundled with the swimmer's *resolved* attendance so the Upcoming tab can
/// render one row per workout without a join or a second pass.
///
/// v1.17 Slice 3: `myIntent` (the raw row, often nil) is no longer the thing
/// the UI renders. `isAttending` + `reason` come from AttendanceResolver, so
/// a swimmer on a standing Mon/Wed/Fri pattern sees "attending — usual
/// session" without ever having marked anything. `myIntent` is retained
/// because the opt-out button needs to know whether an explicit row exists
/// to delete.
struct UpcomingWorkout: Identifiable, Hashable {
    let id: String              // workout_id
    let title: String           // workout title
    let date: String            // ISO8601 scheduled_at (DATE, rendered as ISO at midnight)
    let slot: String            // "AM" | "PM"
    let myIntent: String?       // nil if no explicit row exists
    let isAttending: Bool       // resolved: explicit > standing > out
    let reason: AttendanceResolver.Reason

    var hasMarked: Bool { myIntent != nil }

    /// True when the swimmer is attending purely because of their standing
    /// pattern. The UI uses this to offer "not this week" rather than a
    /// generic toggle.
    var isFromStandingSchedule: Bool { reason == .standingSlot }
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

    /// Every future scheduled workout visible to this swimmer, with their
    /// resolved attendance.
    ///
    /// v1.17 Slice 3 changed three things:
    ///
    /// 1. **Scoped to the caller.** The intent read now filters on
    ///    `swimmer_id`. Previously it fetched every intent row for the
    ///    workout and collapsed with `uniquingKeysWith: { first, _ in first }`
    ///    — an arbitrary winner. A swimmer could see *another swimmer's*
    ///    intent rendered as their own toggle state. RLS was the only thing
    ///    standing between that and a real leak, and RLS should be the
    ///    backstop, not the mechanism.
    ///
    /// 2. **No 7-day cap.** Q3: the swimmer can look as far ahead as they
    ///    like. With standing schedules supplying the default, a long list is
    ///    cheap — they only touch deviations.
    ///
    /// 3. **Resolved, not raw.** Attendance now comes from
    ///    AttendanceResolver, so a swimmer with a standing pattern shows as
    ///    attending without an intent row.
    ///
    /// Squad scoping is enforced by RLS (`swimmer_read_squad_workouts`), not
    /// re-implemented here — one source of truth for who sees what.
    ///
    /// A workout whose `scheduled_at` won't parse is skipped rather than
    /// defaulted: guessing a weekday would resolve real swimmers against the
    /// wrong standing slot.
    func fetchUpcomingWorkouts(swimmerId: String) async throws -> [UpcomingWorkout] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let today = formatter.string(from: Date())

        let workoutsResponse = try await client
            .from("workouts")
            .select("id, title, scheduled_at, am_pm")
            .gte("scheduled_at", value: today)
            .eq("status", value: "scheduled")
            .order("scheduled_at", ascending: true)
            .execute()
        let workouts = try JSONDecoder().decode(
            [WorkoutRow].self, from: workoutsResponse.data
        )

        guard !workouts.isEmpty else { return [] }

        // Both reads are scoped to this swimmer. RLS enforces the same
        // constraint server-side; the explicit filter means a policy change
        // can't silently widen what the UI renders.
        let ids = workouts.map(\.id)
        async let intentFetch = client
            .from("swimmer_attendance_intent")
            .select("id, workout_id, swimmer_id, intent, marked_at, source")
            .eq("swimmer_id", value: swimmerId)
            .in("workout_id", values: ids)
            .execute()
        async let scheduleFetch = client
            .from("swimmer_training_schedule")
            .select("id, swimmer_id, weekday, am_pm, active")
            .eq("swimmer_id", value: swimmerId)
            .execute()

        let intents = try JSONDecoder().decode(
            [SwimmerAttendanceIntent].self, from: try await intentFetch.data
        )
        let schedule = try JSONDecoder().decode(
            [SwimmerTrainingSchedule].self, from: try await scheduleFetch.data
        )

        // The unique key is (workout_id, swimmer_id) and we filtered to one
        // swimmer, so there is at most one row per workout. No collapse
        // needed — and no arbitrary winner.
        let intentByWorkout = Dictionary(
            uniqueKeysWithValues: intents.map { ($0.workoutId, $0) }
        )

        return workouts.compactMap { workout in
            guard
                let scheduledAt = workout.scheduledAt,
                let context = AttendanceResolver.WorkoutContext(
                    workoutId: workout.id,
                    scheduledAt: scheduledAt,
                    amPm: workout.amPm
                )
            else { return nil }

            let resolution = AttendanceResolver.resolve(
                swimmerId: swimmerId,
                workout: context,
                intents: intents,
                schedule: schedule
            )

            return UpcomingWorkout(
                id: workout.id,
                title: workout.title ?? "Workout",
                date: scheduledAt,
                slot: workout.amPm ?? "AM",
                myIntent: intentByWorkout[workout.id]?.intent,
                isAttending: resolution.isAttending,
                reason: resolution.reason
            )
        }
    }

    /// Mark this swimmer's intent for a workout. Upsert — calling
    /// twice with different intents just updates the row.
    func markIntent(workoutId: String, swimmerId: String, intent: String) async throws {
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
            source: "swimmer"
        )
        _ = try await client
            .from("swimmer_attendance_intent")
            .upsert(payload, onConflict: "workout_id,swimmer_id")
            .execute()
    }

    /// Cancel a prior mark (the swimmer changes their mind back to
    /// unmarked). Distinct from `markIntent(_, _, "out")` because
    /// "out" is a *positive* decision; "unmarked" removes the row.
    func clearIntent(workoutId: String, swimmerId: String) async throws {
        _ = try await client
            .from("swimmer_attendance_intent")
            .delete()
            .eq("workout_id", value: workoutId)
            .eq("swimmer_id", value: swimmerId)
            .execute()
    }

    // MARK: - helpers

    /// Wire shape for the workouts select — narrower than the
    /// full Workout model. Keeps the read lean.
    private struct WorkoutRow: Decodable {
        let id: String
        let title: String?
        let scheduledAt: String?
        let amPm: String?

        enum CodingKeys: String, CodingKey {
            case id
            case title
            case scheduledAt = "scheduled_at"
            case amPm = "am_pm"
        }
    }
}