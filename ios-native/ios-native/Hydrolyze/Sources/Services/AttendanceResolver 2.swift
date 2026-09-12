import Foundation

/// AttendanceResolver — answers "is this swimmer attending this workout?"
///
/// v1.17 Slice 3. This is the load-bearing piece of the attendance loop.
/// Everything else in the feature is CRUD around this precedence chain:
///
///   1. Coach's in-session picker edit  → wins outright (never persisted here)
///   2. Explicit intent row             → 'in' or 'out'  [source: swimmer|coach]
///   3. Standing schedule matches       → 'in'
///   4. Otherwise                       → 'out'
///
/// Rule 3 is what makes the loop zero-tap in steady state: a swimmer who
/// declared Mon/Wed/Fri AM is attending Wednesday's workout without ever
/// opening the app. Rule 4 is the narrowing rule — an unmarked, unscheduled
/// swimmer is not evidence of presence, and there is no point asking the
/// pairing engine to match a time to someone who isn't in the water.
///
/// Deliberately pure: no Supabase client, no async, no I/O. Callers fetch
/// the rows and hand them in. That keeps this testable in the CLI harness
/// (`Tests/CLI/AttendanceResolverCLITest.swift`) with no network, and means
/// the precedence chain can be reasoned about in isolation from RLS.
///
/// See plans/attendance-intent-loop-design-spec.md §4.1.
enum AttendanceResolver {

    /// Why a swimmer resolved the way they did.
    ///
    /// Provenance is not decoration — the session-start picker shows it on
    /// each chip so the coach can tell "this swimmer told me they're coming"
    /// from "this is just their usual pattern". Those warrant different
    /// levels of trust when the coach is deciding whether to override.
    enum Reason: String, Hashable, Sendable {
        case explicitIn      = "marked in"
        case explicitOut     = "marked out"
        case standingSlot    = "usual session"
        case noSignal        = "not marked"
    }

    struct Resolution: Hashable, Sendable {
        let swimmerId: String
        let isAttending: Bool
        let reason: Reason

        /// True when the swimmer actively told us something, rather than
        /// falling through to their standing pattern or to the default.
        var isExplicit: Bool {
            reason == .explicitIn || reason == .explicitOut
        }
    }

    /// The workout facts the resolver needs. A struct rather than the full
    /// `Workout` model so the CLI harness doesn't have to build one, and so
    /// callers can resolve against a hypothetical date.
    struct WorkoutContext: Hashable, Sendable {
        let workoutId: String
        let weekday: Weekday
        /// nil when the coach didn't specify AM/PM on the workout. A nil
        /// slot matches ANY standing slot that weekday — we don't hold the
        /// swimmer to a session the coach never pinned down.
        let amPm: SessionSlot?

        init(workoutId: String, weekday: Weekday, amPm: SessionSlot?) {
            self.workoutId = workoutId
            self.weekday = weekday
            self.amPm = amPm
        }

        /// Build from the wire shape: `scheduled_at` (DATE) + `am_pm`.
        ///
        /// Returns nil when the date can't be parsed — a workout with a
        /// malformed date can't be matched against a weekday pattern, and
        /// silently defaulting to Sunday would resolve real swimmers to the
        /// wrong answer. The caller decides what to do with nil.
        init?(workoutId: String, scheduledAt: String, amPm: String?, calendar: Calendar = .current) {
            guard let date = Self.parseDate(scheduledAt, calendar: calendar) else { return nil }
            self.workoutId = workoutId
            self.weekday = Weekday(date: date, calendar: calendar)
            // Defensive: the DB stores uppercase "AM" / "PM". Lowercase drift
            // should not silently turn a PM workout into an AM workout and
            // break standing-slot matching.
            self.amPm = amPm.flatMap { SessionSlot(rawValue: $0.uppercased()) }
        }

        /// `scheduled_at` is a Postgres DATE, so it arrives as "2026-07-29"
        /// — no time, no zone. Parsed at noon UTC deliberately: midnight in
        /// a negative-offset timezone rolls back to the previous day, which
        /// would shift the weekday and silently resolve a Wednesday workout
        /// against a Tuesday slot.
        private static func parseDate(_ raw: String, calendar: Calendar) -> Date? {
            let datePart = String(raw.prefix(10))
            var components = DateComponents()
            let parts = datePart.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            components.year = parts[0]
            components.month = parts[1]
            components.day = parts[2]
            components.hour = 12
            var cal = calendar
            cal.timeZone = TimeZone(secondsFromGMT: 0) ?? cal.timeZone
            return cal.date(from: components)
        }
    }

    // MARK: - Single swimmer

    /// Resolve one swimmer against one workout.
    ///
    /// `intents` and `schedule` may contain rows for other workouts or
    /// swimmers; this filters. Callers usually pass whole fetched sets.
    static func resolve(
        swimmerId: String,
        workout: WorkoutContext,
        intents: [SwimmerAttendanceIntent],
        schedule: [SwimmerTrainingSchedule]
    ) -> Resolution {
        // Rule 2 — an explicit row beats everything below it. Both the
        // swimmer's own mark and a coach override live here; the coach's
        // write overwrites the swimmer's on the same (workout, swimmer)
        // key, so whichever is present is already the authoritative one.
        if let intent = intents.first(where: {
            $0.swimmerId == swimmerId && $0.workoutId == workout.workoutId
        }) {
            let isIn = intent.intent == "in"
            return Resolution(
                swimmerId: swimmerId,
                isAttending: isIn,
                reason: isIn ? .explicitIn : .explicitOut
            )
        }

        // Rule 3 — the standing pattern. This is the branch that carries
        // the feature: most swimmers, most weeks, land here without ever
        // having opened the app.
        let hasStandingSlot = schedule.contains {
            $0.swimmerId == swimmerId
                && $0.matches(weekday: workout.weekday, amPm: workout.amPm)
        }
        if hasStandingSlot {
            return Resolution(swimmerId: swimmerId, isAttending: true, reason: .standingSlot)
        }

        // Rule 4 — no signal means not attending. See spec §4.1 / Q2.
        return Resolution(swimmerId: swimmerId, isAttending: false, reason: .noSignal)
    }

    // MARK: - Whole squad

    /// Resolve every swimmer in a squad against one workout.
    ///
    /// The zero-attendance fallback ("if nobody has any signal at all, treat
    /// everyone as attending") is deliberately NOT applied here. This
    /// function reports what the data says; `SessionStartViewModel` decides
    /// what to do when the answer is "nobody", because that fallback is a
    /// UI-affordance decision, not a fact about attendance. Baking it in
    /// here would make it impossible to distinguish "nobody is coming" from
    /// "nobody has told us anything".
    static func resolveSquad(
        swimmerIds: [String],
        workout: WorkoutContext,
        intents: [SwimmerAttendanceIntent],
        schedules: [SwimmerTrainingSchedule]
    ) -> [Resolution] {
        swimmerIds.map {
            resolve(swimmerId: $0, workout: workout, intents: intents, schedule: schedules)
        }
    }

    /// True when no swimmer has any signal — every resolution fell through
    /// to rule 4. This is the condition the session-start fallback keys on:
    /// a coach whose squad has not onboarded should not be handed an empty
    /// roster, but a coach whose swimmers have all genuinely marked "out"
    /// should be.
    static func hasNoSignal(_ resolutions: [Resolution]) -> Bool {
        !resolutions.isEmpty && resolutions.allSatisfy { $0.reason == .noSignal }
    }

    /// Convenience: just the attending IDs, order preserved.
    static func attendingIds(_ resolutions: [Resolution]) -> [String] {
        resolutions.attendingIds
    }
}

/// Anything carrying a resolved attendance verdict. Lets the collection
/// helpers below serve both the resolver's own `Resolution` and the
/// coach-facing `CoachAttendanceEntry` from one implementation.
protocol AttendanceResolved {
    var swimmerId: String { get }
    var isAttending: Bool { get }
    var reason: AttendanceResolver.Reason { get }
}

extension AttendanceResolver.Resolution: AttendanceResolved {}

extension Collection where Element: AttendanceResolved {
    /// Attending swimmer IDs, order preserved.
    var attendingIds: [String] { filter(\.isAttending).map(\.swimmerId) }

    /// True when nobody has any signal at all — every swimmer fell through
    /// to "not marked". This is what the session-start fallback keys on.
    ///
    /// Deliberately distinct from "everybody declined", which is a real
    /// answer: collapsing the two would hand a coach a full roster on a
    /// morning when the whole squad has said they aren't coming.
    var hasNoSignal: Bool {
        !isEmpty && allSatisfy { $0.reason == .noSignal }
    }
}
