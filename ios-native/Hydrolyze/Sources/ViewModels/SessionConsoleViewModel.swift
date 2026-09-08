import Foundation
import SwiftUI

/// SessionConsoleViewModel — owns the V0.54 Console state for one
/// scheduled workout. Per V0.54 spec §9 S1, S1 only ships:
///   - `state: ConsoleState` (PRE → LIVE stub on tap)
///   - `preTickRoster(forWorkoutId:)` (wraps `WorkoutService.preTickRoster`)
///   - `startSession()` (advances PRE → LIVE; S2 wires the stopwatch)
///   - `firstTimeableRepIndex()` (acceptance: lowest orderIndex whose
///     set has `distance > 0` AND `intensityType != .easy`, OR a
///     fragment with `isTimable == true`).
///
/// S2/S3/S4/S5 add: `liveEnter()` (WaveAllocator fold), `lapRecorded()`,
/// `stopRep()`, `nextRep()`, `endSession()`, `reassign()`,
/// `resumeIfNeeded()`, `persistResume()`.
///
/// Decision 14: resume persists `(session_id, workout_set_id,
/// current_set_index, current_rep_index, is_running)` to UserDefaults
/// on every state change. S1 writes the bare keys; S5 adds the
/// DB-wins check.
@MainActor
final class SessionConsoleViewModel: ObservableObject {
    /// The four-state machine. S1 only mutates `pre → live`. Other
    /// transitions land in S2/S3/S4.
    @Published private(set) var state: ConsoleState = .pre

    /// Pre-ticked roster count for the breadcrumb.
    /// S1: simple count derived from `CoachIntentService.fetchResolvedAttendance`.
    @Published private(set) var attendingCount: Int = 0
    /// Total squad size — used by the breadcrumb's "0 / N" rendering.
    /// Falls back to 0 when no resolver data is available (per
    /// spec §2 edge case: empty squad → "👤 0").
    @Published private(set) var totalCount: Int = 0
    /// True while `preTickRoster` is in flight; the breadcrumb renders
    /// "👤 ?" during a fetch failure (spec §2 edge case: RLS / network
    /// error → retry tap). S1: read-only flag; S5 wires the retry button.
    @Published private(set) var rosterFetchFailed: Bool = false
    /// The full resolved roster snapshot. The breadcrumb's roster
    /// sheet reuses these entries so the edit vocabulary matches the
    /// V0.49 `AttendanceBadge` 1:1. Updated on every `preTickRoster`
    /// call (initial load + S5 retry).
    @Published private(set) var attendanceEntries: [CoachAttendanceEntry] = []

    /// The workout's full set list. Loaded alongside `preTickRoster`
    /// so `firstTimeableRepIndex()` has the data it needs.
    @Published private(set) var sets: [WorkoutSet] = []
    /// The workout itself — used by the PRE wireframe (title, set count,
    /// swimmer count header).
    @Published private(set) var workout: Workout?

    /// `WorkoutService` for the roster pre-tick and sets fetch.
    /// S1 surface; S3 (R4) lifts prediction-building into a shared
    /// service too — out of scope here.
    private let workoutService = WorkoutService()

    /// Session id for the in-flight or future session. `startSession()`
    /// mints a fresh UUID (matches the V0.49 `SessionStartView` flow).
    /// S1 surfaces it on the VM; S5 uses it for resume persistence.
    private(set) var sessionId: String = UUID().uuidString

    // MARK: - S1 entry

    /// Enter the Console for a workout. Loads the workout, its sets,
    /// and the resolved roster. Always lands in `.pre` — S1 ships no
    /// resume behaviour (S5).
    func enter(workoutId: String) async {
        state = .pre
        do {
            async let workout = workoutService.fetchWorkout(workoutId: workoutId)
            async let sets = workoutService.fetchWorkoutSets(workoutId: workoutId)
            self.workout = try await workout
            self.sets = try await sets
        } catch {
            // Spec §2: fail-open. The Console still shows PRE with an
            // empty breadcrumb — Start Session stays enabled.
            self.workout = nil
            self.sets = []
            rosterFetchFailed = true
        }
        await preTickRoster(workoutId: workoutId)
    }

    // MARK: - S1 preTickRoster

    /// Pre-tick the breadcrumb from `WorkoutService.preTickRoster`,
    /// which wraps `CoachIntentService.fetchResolvedAttendance` — the
    /// same path `AttendanceBadge` uses today (V0.49). Spec §6 edit-list
    /// names `WorkoutService.preTickRoster(forWorkoutId:)` as the
    /// wrapper so the Console and the badge cannot drift.
    ///
    /// Edge cases per spec §2:
    ///   - empty squad → "👤 0", Start Session enabled (fail-open).
    ///   - all marked out → "👤 0 / N", one-line caption rendered by
    ///     `AttendanceBreadcrumb`; coach can override in the roster
    ///     sheet.
    ///   - RLS / network error → "👤 ?" with a retry tap (S5 wires
    ///     the retry; S1 surfaces the flag and the call site can
    ///     re-invoke `preTickRoster`).
    func preTickRoster(workoutId: String) async {
        do {
            let resolved = try await CoachIntentService().fetchResolvedAttendance(forWorkoutId: workoutId)
            attendanceEntries = resolved.entries
            attendingCount = resolved.entries.filter(\.isAttending).count
            totalCount = resolved.entries.count
            rosterFetchFailed = false
        } catch {
            // Spec §2: fail-open. Start Session stays enabled.
            attendanceEntries = []
            attendingCount = 0
            totalCount = 0
            rosterFetchFailed = true
        }
    }

    /// S1 (2026-09-08): the breadcrumb's roster sheet calls this
    /// whenever the coach flips an In/Out toggle. Wraps
    /// `CoachIntentService.setIntent` (the same path the V0.49
    /// `AttendanceBadge` popover uses) and reloads the resolved
    /// roster so the breadcrumb count stays coherent with the sheet.
    /// Decision 13 (correction-feedback counter) lands in S5; S1
    /// writes the durable `SwimmerAttendanceIntent` row only.
    func setIntent(swimmerId: String, intent: String, workoutId: String) async {
        do {
            try await CoachIntentService().setIntent(
                workoutId: workoutId,
                swimmerId: swimmerId,
                intent: intent
            )
            Haptics.tap()
            await preTickRoster(workoutId: workoutId)
        } catch {
            Haptics.error()
        }
    }

    // MARK: - S1 startSession

    /// Tap "Start Session". S1 advances PRE → LIVE with no intermediate
    /// screens (decision 10). S2 wires the stopwatch + the
    /// first-timeable heuristic; S1 only flips the state so the
    /// acceptance test (PRE → LIVE on tap) passes.
    func startSession() {
        guard state == .pre else { return }
        state = .live
    }

    /// S1 stub-body escape hatch: when the LIVE/BETWEEN/POST stub
    /// body renders a "Back to PRE" button, it needs a way to flip
    /// `state` back. S2/S3/S4 will delete this — it's purely a debug
    /// surface so the S1 acceptance harness can re-enter PRE without
    /// dismissing the cover.
    func resetToPre() {
        state = .pre
    }

    // MARK: - S1 firstTimeableRepIndex (acceptance test surface)

    /// S1 (2026-09-08): DEBUG-only seed for the screenshot harness. The
    /// V0.46 Slice 5 pattern (`seedV46DemoToday()` on TodayViewModel)
    /// shows that the screenshot route bypasses the network; this
    /// mirrors it for the Console so the `-v54-demo-console` launch
    /// arg can capture a clean PRE screenshot without an auth session.
    ///
    /// Seeds a 5-set Threshold Tuesday workout + 14 attending + the
    /// breadcrumb showing 14/14. The first timeable set is
    /// `orderIndex == 2` (the steady 6×100), so the heuristic
    /// assertion (`firstTimeableRepIndex() == 2`) is exercisable
    /// from this seed too.
    #if DEBUG
    func seedV54DemoConsole() {
        let now = ISO8601DateFormatter().string(from: Date())
        workout = Workout(
            id: "v54-demo-workout",
            coachId: "v54-demo-coach",
            title: "Threshold Tuesday",
            description: "Warm-up, main threshold block, warm-down.",
            scheduledAt: now,
            amPm: "am",
            completedAt: nil,
            status: .scheduled,
            createdAt: now,
            updatedAt: nil,
            sessionType: nil
        )
        func set(_ i: Int, _ reps: Int?, _ distance: Int?, _ stroke: String?, _ zone: String?, _ intensity: String?) -> WorkoutSet {
            WorkoutSet(
                id: "v54-demo-set-\(i)",
                workoutId: workout?.id ?? "v54-demo-workout",
                orderIndex: i,
                reps: reps,
                distance: distance,
                stroke: stroke,
                intervalText: i == 2 || i == 3 ? "1:30" : nil,
                intensityType: intensity,
                intensityLabel: nil,
                zoneTerm: zone,
                paceTargetDistance: nil,
                gear: nil,
                suit: nil,
                startType: nil,
                dive: nil,
                fragments: nil,
                createdAt: now
            )
        }
        sets = [
            set(0, 1, 400, "Free", "easy", "easy"),
            set(1, 8, 50, "Free", "easy", "easy"),
            set(2, 6, 100, "Free", "steady", "steady"),
            set(3, 5, 100, "Free", "hard", "hard"),
            set(4, 8, 25, "Free", "sprint", "sprint")
        ]
        attendingCount = 14
        totalCount = 14
        attendanceEntries = []
        rosterFetchFailed = false
        // S1 acceptance: the -v54-demo-console-live harness flag proves
        // the state-machine advance (PRE → LIVE on Start Session tap)
        // compiles + renders without needing an interactive tap. S2 will
        // retire this and wire the real stopwatch.
        if ProcessInfo.processInfo.arguments.contains("-v54-demo-console-live") {
            state = .live
        } else {
            state = .pre
        }
    }
    #endif

    /// Lowest-orderIndex set whose parsed content has at least one
    /// timable surface. Per V0.54 spec §5:
    ///   `set.distance > 0 AND (intensityType != .easy OR a fragment
    ///   with isTimable == true)`.
    ///
    /// Spec §5 fallback: if no set is timeable, return `nil` (the
    /// Console transitions PRE → POST instead of LIVE — out of S1 scope).
    ///
    /// Returns the `Int` orderIndex, not the set id — S2's LIVE body
    /// reads it as an index into `sets.sorted(by: orderIndex)`.
    ///
    /// SPEC DELTA (report): the spec's "isTimable == true (V0.53.1
    /// contract)" is a derived predicate, not a stored field.
    /// `WorkoutSetFragment` (the DB-row shape stored in
    /// `workout_sets.fragments`) carries `intensity` as a free-form
    /// String — there's no `isTimable` column. `ParsedFragment`'s
    /// `isTimableFragment(_:)` helper (WorkoutPreview.swift:1519)
    /// derives it from `intensity.type != .easy`. We mirror that
    /// contract here via `WorkoutSetFragment.isTimable` (a computed
    /// property) so the heuristic matches the FragmentCTARow gate
    /// used by the existing timing flow.
    ///
    /// SPEC DELTA 2 (report): the parser maps `easy | recovery |
    /// warm-up | ez | relaxed` → `intensity_type = "easy"` at
    /// _llm.ts:560 (per `WorkoutPreview.swift:1513-1518` doc-comment).
    /// The spec text `intensityType != .easy` reads literally, but
    /// the parser canonicalises the whole family to the single token
    /// `"easy"` before persistence, so the literal check is correct
    /// for DB rows. We've kept `WorkoutSetFragment.isTimable`'s
    /// normalization (lowercased comparison + canonical easy-token
    /// set) so any future parser that writes the raw token string
    /// (rather than canonicalising) stays coherent.
    func firstTimeableRepIndex() -> Int? {
        let ordered = sets.sorted { $0.orderIndex < $1.orderIndex }
        let canonicalEasy: Set<String> = ["easy", "recovery", "warm-up", "warmup", "ez", "relaxed"]
        for set in ordered {
            guard let distance = set.distance, distance > 0 else { continue }
            // Set-level shortcut: a non-canonical-easy intensity means
            // the set is timable.
            if let intensity = set.intensityType?.lowercased(),
               !canonicalEasy.contains(intensity) {
                return set.orderIndex
            }
            // Fragment-level fallback: at least one fragment whose
            // intensity isn't the canonical "easy" — mirrors
            // `isTimableFragment(_:)` in WorkoutPreview.swift:1519
            // so the heuristic stays coherent with the existing
            // FragmentCTARow gate.
            if let fragments = set.fragments,
               fragments.contains(where: { $0.isTimable }) {
                return set.orderIndex
            }
        }
        return nil
    }
}