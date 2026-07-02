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

/// UpcomingWorkout — the swimmer-side view model for workouts in
/// the next 7 days. Bundles the workout with the swimmer's current
/// intent (if any) so the Upcoming tab can render one row per
/// workout without a join on the client.
struct UpcomingWorkout: Identifiable, Hashable {
    let id: String              // workout_id
    let title: String           // workout title
    let date: String            // ISO8601 scheduled_at (DATE, rendered as ISO at midnight)
    let slot: String            // "AM" | "PM"
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

    /// Fetch all upcoming workouts (next 7 days) joined with the
    /// swimmer's own intent row (if any). Single round-trip via
    /// the `workouts` table; the join is client-side.
    ///
    /// ponytail: returning `[UpcomingWorkout]` directly keeps the
    /// Upcoming tab's view-model trivial. If we ever need a richer
    /// shape (set count, athlete count), promote the helper.
    func fetchUpcomingWorkouts() async throws -> [UpcomingWorkout] {
        let now = Date()
        let weekOut = now.addingTimeInterval(7 * 24 * 60 * 60)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let dateNow = formatter.string(from: now)
        let dateOut = formatter.string(from: weekOut)

        let workoutsResponse = try await client
            .from("workouts")
            .select("id, title, scheduled_at, am_pm")
            .gte("scheduled_at", value: dateNow)
            .lte("scheduled_at", value: dateOut)
            .eq("status", value: "scheduled")
            .order("scheduled_at", ascending: true)
            .execute()
        let workouts = try JSONDecoder().decode(
            [WorkoutRow].self, from: workoutsResponse.data
        )

        guard !workouts.isEmpty else { return [] }

        let ids = workouts.map(\.id)
        let intentResponse = try await client
            .from("swimmer_attendance_intent")
            .select("id, workout_id, swimmer_id, intent, marked_at, source")
            .in("workout_id", values: ids)
            .execute()
        let intents = try JSONDecoder().decode(
            [SwimmerAttendanceIntent].self, from: intentResponse.data
        )
        let intentByWorkout = Dictionary(
            intents.map { ($0.workoutId, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return workouts.map { workout in
            let myIntent = intentByWorkout[workout.id]
            return UpcomingWorkout(
                id: workout.id,
                title: workout.title ?? "Workout",
                date: workout.scheduledAt ?? "",
                slot: workout.amPm ?? "AM",
                myIntent: myIntent?.intent
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