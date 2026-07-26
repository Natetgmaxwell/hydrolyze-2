import Foundation

// v1.17 Slice 3 — AttendanceResolver truth table.
//
// The resolver is pure, so unlike the Slice 1/2 DB probes this runs with no
// network and no RLS. Every rule in the precedence chain gets a test, plus
// the failure modes that would be silent in production:
//
//   - a coach override must beat a standing slot (else "I told you they're
//     injured" gets ignored every Wednesday)
//   - a nil am_pm must match any slot that day (else workouts the coach
//     didn't pin down resolve everyone to "out")
//   - date parsing must not shift the weekday by timezone (else a Wednesday
//     workout matches Tuesday slots for anyone west of UTC)
//   - hasNoSignal must distinguish "nobody told us" from "everybody said no"
//
// Run: bash Hydrolyze/Tests/CLI/build_and_run_resolver.sh

@main
struct AttendanceResolverCLITest {

    static var passed = 0
    static var failed = 0

    /// Type-safe equality. Deliberately NOT stringly-compared: an earlier
    /// version interpolated both sides, which made `Optional(.wednesday)`
    /// compare unequal to `.wednesday` and reported 6 false failures on
    /// correct code. Comparing values directly means the compiler enforces
    /// that both sides are the same type.
    static func check<T: Equatable>(_ label: String, _ got: T, _ want: T) {
        let ok = got == want
        if ok { passed += 1 } else { failed += 1 }
        let mark = ok ? "✓" : "✗ FAIL"
        let detail = ok ? "" : "  (got \(got), want \(want))"
        print("  \(mark) \(label)\(detail)")
    }

    // MARK: - fixtures

    static func intent(
        _ swimmerId: String,
        _ workoutId: String,
        _ value: String,
        source: String = "swimmer"
    ) -> SwimmerAttendanceIntent {
        SwimmerAttendanceIntent(
            id: UUID().uuidString,
            workoutId: workoutId,
            swimmerId: swimmerId,
            intent: value,
            markedAt: "2026-07-26T00:00:00Z",
            source: source
        )
    }

    static func slot(
        _ swimmerId: String,
        _ day: Weekday,
        _ amPm: SessionSlot,
        active: Bool = true
    ) -> SwimmerTrainingSchedule {
        SwimmerTrainingSchedule(
            id: UUID().uuidString,
            swimmerId: swimmerId,
            weekday: day.rawValue,
            amPm: amPm.rawValue,
            active: active
        )
    }

    // 2026-07-29 is a Wednesday.
    static let wedAM = AttendanceResolver.WorkoutContext(
        workoutId: "w-wed", weekday: .wednesday, amPm: .am
    )

    static func main() {
        print("=== v1.17 Slice 3: AttendanceResolver truth table ===\n")

        scenario1_precedenceChain()
        scenario2_coachOverride()
        scenario3_nilAmPm()
        scenario4_dateParsing()
        scenario5_squadAndFallback()

        print("\n=== \(passed) passed, \(failed) failed ===")
        if failed > 0 {
            print("VERDICT: FAIL")
            exit(1)
        }
        print("VERDICT: PASS")
    }

    // Rule 1-4, one swimmer each.
    static func scenario1_precedenceChain() {
        print("Scenario 1 — the four precedence rules")

        let intents = [intent("s-in", "w-wed", "in"), intent("s-out", "w-wed", "out")]
        let schedules = [slot("s-standing", .wednesday, .am)]

        let r1 = AttendanceResolver.resolve(
            swimmerId: "s-in", workout: wedAM, intents: intents, schedule: schedules)
        check("explicit 'in' attends", r1.isAttending, true)
        check("explicit 'in' reason", r1.reason, AttendanceResolver.Reason.explicitIn)

        let r2 = AttendanceResolver.resolve(
            swimmerId: "s-out", workout: wedAM, intents: intents, schedule: schedules)
        check("explicit 'out' does not attend", r2.isAttending, false)
        check("explicit 'out' reason", r2.reason, AttendanceResolver.Reason.explicitOut)

        let r3 = AttendanceResolver.resolve(
            swimmerId: "s-standing", workout: wedAM, intents: intents, schedule: schedules)
        check("standing slot attends with zero taps", r3.isAttending, true)
        check("standing slot reason", r3.reason, AttendanceResolver.Reason.standingSlot)

        let r4 = AttendanceResolver.resolve(
            swimmerId: "s-nobody", workout: wedAM, intents: intents, schedule: schedules)
        check("no signal does not attend (narrowing rule)", r4.isAttending, false)
        check("no signal reason", r4.reason, AttendanceResolver.Reason.noSignal)

        // An inactive standing slot is a paused pattern, not an active one.
        let paused = [slot("s-paused", .wednesday, .am, active: false)]
        let r5 = AttendanceResolver.resolve(
            swimmerId: "s-paused", workout: wedAM, intents: [], schedule: paused)
        check("paused standing slot does not attend", r5.isAttending, false)

        // A standing slot on the wrong day must not leak across weekdays.
        let mondayOnly = [slot("s-mon", .monday, .am)]
        let r6 = AttendanceResolver.resolve(
            swimmerId: "s-mon", workout: wedAM, intents: [], schedule: mondayOnly)
        check("Monday slot does not match a Wednesday workout", r6.isAttending, false)

        // Same weekday, wrong half of the day.
        let wedPM = [slot("s-pm", .wednesday, .pm)]
        let r7 = AttendanceResolver.resolve(
            swimmerId: "s-pm", workout: wedAM, intents: [], schedule: wedPM)
        check("Wed PM slot does not match a Wed AM workout", r7.isAttending, false)
        print("")
    }

    // The regression that matters most: explicit beats standing.
    static func scenario2_coachOverride() {
        print("Scenario 2 — explicit intent beats the standing pattern")

        let schedules = [slot("s-1", .wednesday, .am)]

        let coachOut = [intent("s-1", "w-wed", "out", source: "coach")]
        let r1 = AttendanceResolver.resolve(
            swimmerId: "s-1", workout: wedAM, intents: coachOut, schedule: schedules)
        check("coach 'out' beats a standing slot", r1.isAttending, false)
        check("...and reports as explicit", r1.isExplicit, true)

        let swimmerOut = [intent("s-1", "w-wed", "out", source: "swimmer")]
        let r2 = AttendanceResolver.resolve(
            swimmerId: "s-1", workout: wedAM, intents: swimmerOut, schedule: schedules)
        check("swimmer opt-out beats their own standing slot", r2.isAttending, false)

        // The opt-out is per-workout, so a different workout on the same
        // weekday must still resolve from the standing pattern.
        let otherWed = AttendanceResolver.WorkoutContext(
            workoutId: "w-wed-2", weekday: .wednesday, amPm: .am)
        let r3 = AttendanceResolver.resolve(
            swimmerId: "s-1", workout: otherWed, intents: swimmerOut, schedule: schedules)
        check("opt-out is per-workout, not per-weekday", r3.isAttending, true)
        check("...and falls back to the standing reason", r3.reason,
              AttendanceResolver.Reason.standingSlot)

        // Intent rows for a different swimmer must not bleed across.
        let othersIntent = [intent("s-other", "w-wed", "out")]
        let r4 = AttendanceResolver.resolve(
            swimmerId: "s-1", workout: wedAM, intents: othersIntent, schedule: schedules)
        check("another swimmer's 'out' does not apply", r4.isAttending, true)
        print("")
    }

    // A workout with no am_pm must not silently exclude everyone.
    static func scenario3_nilAmPm() {
        print("Scenario 3 — nil am_pm matches any slot that weekday")

        let anySlot = AttendanceResolver.WorkoutContext(
            workoutId: "w-any", weekday: .wednesday, amPm: nil)

        let r1 = AttendanceResolver.resolve(
            swimmerId: "s-am", workout: anySlot, intents: [],
            schedule: [slot("s-am", .wednesday, .am)])
        check("nil am_pm matches an AM standing slot", r1.isAttending, true)

        let r2 = AttendanceResolver.resolve(
            swimmerId: "s-pm", workout: anySlot, intents: [],
            schedule: [slot("s-pm", .wednesday, .pm)])
        check("nil am_pm matches a PM standing slot", r2.isAttending, true)

        let r3 = AttendanceResolver.resolve(
            swimmerId: "s-thu", workout: anySlot, intents: [],
            schedule: [slot("s-thu", .thursday, .am)])
        check("nil am_pm still respects the weekday", r3.isAttending, false)
        print("")
    }

    // Timezone-safe date -> weekday conversion.
    static func scenario4_dateParsing() {
        print("Scenario 4 — scheduled_at parses to the right weekday")

        // 2026-07-29 is a Wednesday; 2026-07-26 is a Sunday.
        let wed = AttendanceResolver.WorkoutContext(
            workoutId: "w", scheduledAt: "2026-07-29", amPm: "AM")
        check("2026-07-29 is Wednesday", wed?.weekday == .wednesday, true)

        let sun = AttendanceResolver.WorkoutContext(
            workoutId: "w", scheduledAt: "2026-07-26", amPm: "PM")
        check("2026-07-26 is Sunday", sun?.weekday == .sunday, true)
        check("PM parses to the PM slot", sun?.amPm == .pm, true)

        // Postgres may hand back a full timestamp; only the date matters.
        let withTime = AttendanceResolver.WorkoutContext(
            workoutId: "w", scheduledAt: "2026-07-29T00:00:00Z", amPm: nil)
        check("timestamp form still parses to Wednesday", withTime?.weekday == .wednesday, true)
        check("missing am_pm stays nil (matches any)", withTime?.amPm == nil, true)

        // Malformed input must be nil, not a silent Sunday default.
        let bad = AttendanceResolver.WorkoutContext(
            workoutId: "w", scheduledAt: "not-a-date", amPm: "AM")
        check("malformed date returns nil, not a wrong weekday", bad == nil, true)

        // Real case, found by the Slice 3 DB probe: this database contains
        // a workout with scheduled_at = NULL (an in_progress row that never
        // got a date). IntentService compactMaps those away, but the empty
        // and partial forms must also refuse rather than guess.
        check("empty date string returns nil",
              AttendanceResolver.WorkoutContext(
                workoutId: "w", scheduledAt: "", amPm: "AM") == nil, true)
        check("partial date (year-month only) returns nil",
              AttendanceResolver.WorkoutContext(
                workoutId: "w", scheduledAt: "2026-07", amPm: "AM") == nil, true)
        check("garbage am_pm degrades to nil (matches any), not a crash",
              AttendanceResolver.WorkoutContext(
                workoutId: "w", scheduledAt: "2026-07-29", amPm: "EVENING")?.amPm == nil, true)

        // Timezone independence: the same date string must yield the same
        // weekday regardless of the device's calendar timezone.
        var sydney = Calendar(identifier: .gregorian)
        sydney.timeZone = TimeZone(identifier: "Australia/Sydney")!
        var honolulu = Calendar(identifier: .gregorian)
        honolulu.timeZone = TimeZone(identifier: "Pacific/Honolulu")!

        let inSydney = AttendanceResolver.WorkoutContext(
            workoutId: "w", scheduledAt: "2026-07-29", amPm: "AM", calendar: sydney)
        let inHonolulu = AttendanceResolver.WorkoutContext(
            workoutId: "w", scheduledAt: "2026-07-29", amPm: "AM", calendar: honolulu)
        check("Sydney reads Wednesday", inSydney?.weekday == .wednesday, true)
        check("Honolulu reads Wednesday too (no date shift)", inHonolulu?.weekday == .wednesday, true)
        print("")
    }

    // Squad-level resolution + the fallback signal.
    static func scenario5_squadAndFallback() {
        print("Scenario 5 — squad resolution and the no-signal fallback")

        let ids = ["a", "b", "c", "d", "e", "f"]
        let intents = [
            intent("a", "w-wed", "in"),
            intent("b", "w-wed", "out"),
        ]
        let schedules = [
            slot("c", .wednesday, .am),
            slot("d", .wednesday, .am),
            slot("e", .monday, .am),      // wrong day
        ]

        let resolved = AttendanceResolver.resolveSquad(
            swimmerIds: ids, workout: wedAM, intents: intents, schedules: schedules)

        check("resolves one row per swimmer", resolved.count, 6)
        let attending = AttendanceResolver.attendingIds(resolved)
        check("attending = explicit-in + two standing", attending.count, 3)
        check("attending set is a, c, d", attending.sorted().joined(separator: ","), "a,c,d")
        check("order is preserved", attending, ["a", "c", "d"])

        check("mixed squad is not a no-signal squad",
              AttendanceResolver.hasNoSignal(resolved), false)

        // Nobody has told us anything — the coach should get the fallback.
        let cold = AttendanceResolver.resolveSquad(
            swimmerIds: ids, workout: wedAM, intents: [], schedules: [])
        check("cold squad attends nobody", AttendanceResolver.attendingIds(cold).count, 0)
        check("cold squad IS a no-signal squad", AttendanceResolver.hasNoSignal(cold), true)

        // Everybody genuinely said no — that is real information, and the
        // coach must NOT be handed the everyone-attends fallback.
        let allOut = ids.map { intent($0, "w-wed", "out") }
        let refused = AttendanceResolver.resolveSquad(
            swimmerIds: ids, workout: wedAM, intents: allOut, schedules: [])
        check("all-declined attends nobody", AttendanceResolver.attendingIds(refused).count, 0)
        check("all-declined is NOT no-signal (real answer)",
              AttendanceResolver.hasNoSignal(refused), false)

        check("empty squad is not no-signal",
              AttendanceResolver.hasNoSignal([]), false)
        print("")
    }
}
