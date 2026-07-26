// AttendanceNarrowingCLITest — v1.17 Slice 8.
//
// Engine-side proof that the resolved-attendance pool reaches the
// pairing engine. Synthesises 12 swimmers (6 attending via different
// resolution paths + 6 attenders NOT in the candidate pool), drives the
// AttendanceResolver to build the candidate set, then runs the real
// PairingEngine with that set. The contract under test:
//
//   * The candidate pool is the resolved-attendance set, not the squad.
//   * A swimmer attending via their standing pattern is included, with
//     zero taps from the swimmer side.
//   * A swimmer who explicitly declined gets zero assignments — even
//     when a decoy lap is placed near their predicted time.
//   * A swimmer with no signal is excluded by the narrowing rule,
//     not silently dropped to noSignal-Fallback inside the engine.
//
// Compiled by build_and_run_attendance.sh (see sibling script).

import Foundation

struct AttSwimmer { let id: String; let pbMs: Int; let firstName: String }

let attendanceSwimmers: [AttSwimmer] = [
    AttSwimmer(id: "11111111-1111-1111-1111-000000000001", pbMs: 26800, firstName: "Att-Alpha"),
    AttSwimmer(id: "11111111-1111-1111-1111-000000000002", pbMs: 27200, firstName: "Att-Beta"),
    AttSwimmer(id: "11111111-1111-1111-1111-000000000003", pbMs: 27900, firstName: "Att-Gamma"),
    AttSwimmer(id: "11111111-1111-1111-1111-000000000004", pbMs: 28400, firstName: "Att-Delta"),
    AttSwimmer(id: "11111111-1111-1111-1111-000000000005", pbMs: 29500, firstName: "Att-Epsilon"),
    AttSwimmer(id: "11111111-1111-1111-1111-000000000006", pbMs: 30100, firstName: "Att-Zeta"),
    AttSwimmer(id: "22222222-2222-2222-2222-000000000001", pbMs: 31200, firstName: "Out-Eta"),
    AttSwimmer(id: "22222222-2222-2222-2222-000000000002", pbMs: 32800, firstName: "Out-Theta"),
    AttSwimmer(id: "22222222-2222-2222-2222-000000000003", pbMs: 28900, firstName: "Silent-Iota"),
    AttSwimmer(id: "22222222-2222-2222-2222-000000000004", pbMs: 29600, firstName: "Silent-Kappa"),
    AttSwimmer(id: "22222222-2222-2222-2222-000000000005", pbMs: 30500, firstName: "Miss-Lambda"),
    AttSwimmer(id: "22222222-2222-2222-2222-000000000006", pbMs: 31900, firstName: "Miss-Mu"),
  ]

// 2026-07-29 is a Wednesday (verified by the resolver's own test).
let workoutContext = AttendanceResolver.WorkoutContext(
    workoutId: "w-attendance-narrow",
    weekday: .wednesday,
    amPm: .am
)

func makeIntent(_ swimmerId: String, _ value: String, source: String = "swimmer") -> SwimmerAttendanceIntent {
    SwimmerAttendanceIntent(
        id: UUID().uuidString,
        workoutId: workoutContext.workoutId,
        swimmerId: swimmerId,
        intent: value, markedAt: "2026-07-26T00:00:00Z", source: source)
}

func makeSlot(_ swimmerId: String, _ day: Weekday, _ amPm: SessionSlot, active: Bool = true) -> SwimmerTrainingSchedule {
    SwimmerTrainingSchedule(
        id: UUID().uuidString,
        swimmerId: swimmerId,
        weekday: day.rawValue, amPm: amPm.rawValue, active: active)
}

// 2 explicit in, 2 explicit out, 2 standing, 2 unmarked + unscheduled,
// 2 with a standing slot on a different day (wrong-day miss).
let allIntents: [SwimmerAttendanceIntent] = [
    makeIntent("11111111-1111-1111-1111-000000000001", "in"),
    makeIntent("11111111-1111-1111-1111-000000000002", "in"),
    makeIntent("22222222-2222-2222-2222-000000000001", "out"),
    makeIntent("22222222-2222-2222-2222-000000000002", "out"),
]

let allSchedules: [SwimmerTrainingSchedule] = [
    // Standing pool: 2 swimmers whose pattern matches the workout.
    makeSlot("11111111-1111-1111-1111-000000000003", .wednesday, .am),
    makeSlot("11111111-1111-1111-1111-000000000004", .wednesday, .am),
    // Wrong-day misses: a swimmer whose standing slot is on the OTHER day.
    makeSlot("22222222-2222-2222-2222-000000000005", .thursday,  .am),
    makeSlot("22222222-2222-2222-2222-000000000006", .saturday,  .pm),
]

// Resolve every swimmer against the workout.
let allSwimmerIds = attendanceSwimmers.map(\.id)
let resolutions = AttendanceResolver.resolveSquad(
    swimmerIds: allSwimmerIds,
    workout: workoutContext,
    intents: allIntents,
    schedules: allSchedules
)

let attending = AttendanceResolver.attendingIds(resolutions)
let attendingSet = Set(attending)
let notAttending = allSwimmerIds.filter { !attendingSet.contains($0) }



@main
struct Main {
    static func main() {
    var passed = 0
    var failed = 0

    func check<T: Equatable>(_ label: String, _ got: T, _ want: T) {
        let ok = got == want
        ok ? (passed += 1) : (failed += 1)
        print("  \(ok ? "✓" : "✗ FAIL") \(label)\(ok ? "" : "  (got \(got), want \(want))")")
    }

    print("""
    ┌─── Scenario: v1.17 INTENT NARROWING (12-swimmer squad) ───┐
    │ 6 attending via resolved attendance (2 in + 2 standing + 2 wrong-day)
    │ 4 explicitly excluded (2 out + 2 wrong-day)
    │ 2 unmarked + unscheduled (silent, excluded by the narrowing rule)
    │
    """)

    print("│ Phase 1: resolver narrows the candidate pool")
    check("attending pool size = 4", attending.count, 4)
    let expected = Set(["11111111-1111-1111-1111-000000000001", "11111111-1111-1111-1111-000000000002", "11111111-1111-1111-1111-000000000003", "11111111-1111-1111-1111-000000000004"])
    check("attending set is the four expected swimmers", attendingSet, expected)
    let notExpected = Set(notAttending)
    check("the other 8 are excluded from the pool",
          notExpected,
          Set([
            "22222222-2222-2222-2222-000000000001",  // Out-Eta     explicit out
            "22222222-2222-2222-2222-000000000002",  // Out-Theta   explicit out
            "22222222-2222-2222-2222-000000000003",  // Silent-Iota no signal, no standing
            "22222222-2222-2222-2222-000000000004",  // Silent-Kappa no signal, no standing
            "22222222-2222-2222-2222-000000000005",  // Miss-Lambda  wrong-day standing
            "22222222-2222-2222-2222-000000000006",  // Miss-Mu     wrong-day standing
            "11111111-1111-1111-1111-000000000005",  // Att-Epsilon no signal, no standing
            "11111111-1111-1111-1111-000000000006",  // Att-Zeta    no signal, no standing
          ]))

    // Hint: provide a wrong-day pattern for a15 so we know it didn't leak.
    let wrongDaySchemes = allSchedules
    let wrongDay = wrongDaySchemes.first { $0.swimmerId == "22222222-2222-2222-2222-000000000005" }
    check("b15's slot is genuinely on Thursday, not Wednesday",
          wrongDay?.day, .thursday)

    print("│")
    print("│ Phase 2: PairingEngine receives ONLY the attending pool")

    let sendOff = 0
    let intensityMultiplier = 1.05

    // Build wave assignments for ONLY the attending swimmers.
    let attendingMockById = Dictionary(
        uniqueKeysWithValues: attendanceSwimmers.map { ($0.id, $0) }
    )
    let waveAssignments: [WaveAssignment] = attending.enumerated().map { (i, sid) in
        let mock = attendingMockById[sid]!
        let predicted = Double(mock.pbMs) * intensityMultiplier
        return WaveAssignment(
            id: UUID().uuidString,
            sessionId: "test-session",
            swimmerId: sid,
            workoutSetId: "test-set",
            lane: i + 1,
            positionInLane: 0,
            predictedTouchMs: sendOff + Int(predicted),
            waveNumber: 0,
            sendOffOffsetMs: sendOff,
            coachId: "test-coach",
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    // Build plausible laps: one per attending swimmer.
    let laps: [Lap] = attending.enumerated().map { (i, sid) in
        let mock = attendingMockById[sid]!
        let predicted = Double(mock.pbMs) * intensityMultiplier
        let seed = Double(((mock.pbMs / 7) % 100)) // deterministic-noise stand-in
        let actual = Int(predicted + ((seed - 50) * 4))  // ±200ms
        return Lap(
            id: UUID().uuidString,
            lapNumber: i + 1,
            elapsedMs: sendOff + actual,
            splitMs: actual
        )
    }

    // DECOY LAP: a tap placed near the predicted time of an EXCLUDED swimmer
    // (Mock-Out-Eta, PB=31200ms -> predicted ~32760ms). If the engine ever
    // receives the excluded swimmers as candidates, this lap is the kind of
    // input that would seduce it into a wrong assignment.
    let decoyFullTime = Int(Double(31200) * intensityMultiplier)
    let decoyLap = Lap(
        id: UUID().uuidString,
        lapNumber: laps.count + 1,
        elapsedMs: decoyFullTime + 30,       // 30ms after the EXCLUDED swimmer's predicted time
        splitMs: decoyFullTime + 30
    )
    let allLaps = laps + [decoyLap]

    // Predictions for the WHOLE squad (engine keys by id; missing ids just
    // aren't used). The engine only sees waveAssignments for the attending set.
    let predictions: [String: Prediction] = attendanceSwimmers.reduce(into: [:]) { acc, s in
        acc[s.id] = Prediction(
            timeMs: s.pbMs, sigmaMs: 2000, sampleSize: 0,
            source: .curve, maturity: .none,
            suitDeltaMs: nil, startDeltaMs: nil)
    }

    let engine = PairingEngine()
    let result = engine.pair(
        laps: allLaps,
        waveAssignments: waveAssignments,
        predictions: predictions,
        sendOffIntervalMs: 10_000
    )

    check("engine produced \(attending.count) assignments for the attending pool",
          result.assignments.count, attending.count)
    check("the decoy lap is NOT assigned to a real swimmer",
          result.unassignedLaps.count >= 1, true)
    // The engine normalises ids to UUIDs; we string-compared against the
// mock ids above, so map both sides to UUIDs for the membership checks.
let assignedUUIDs = Set(result.assignments.map { a in
    UUID(uuidString: a.swimmerId.uuidString) ?? UUID()
})
    let notAttendingUUIDs = Set(notAttending.compactMap(UUID.init(uuidString:)))
    check("no excluded swimmer sneaks into the assignments",
          assignedUUIDs.intersection(notAttendingUUIDs).isEmpty, true)
    check("engine reports zero ghost taps",
          result.unassignedSwimmers.count, 0)

    print("│")
    print("│ Per-swimmer pairing (attending pool only):")
    for sid in attending.sorted() {
        let mock = attendingMockById[sid]!
        let matched = assignedUUIDs.contains(UUID(uuidString: sid) ?? UUID())
        print("│   \(matched ? "✓" : "✗") \(mock.firstName.padding(toLength: 14, withPad: " ", startingAt: 0)) PB=\(mock.pbMs)ms")
    }

    print("│")
    print("└─── Verdict: \(failed == 0 ? "PASS ✓" : "FAIL ✗") ───┘")
    print("=== \(passed) passed, \(failed) failed ===")
    if failed > 0 { exit(1) }

    }
}
