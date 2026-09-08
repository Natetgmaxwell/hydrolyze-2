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
    /// S2 (2026-09-08): per-rep recorded-ms (indexed by rep index)
    /// for the LIVE body's compressed one-liner summary. Mirrors the
    /// TimingView's `lap()` writes (via `mode == .console` branch)
    /// and the `handleRecordedPayload` path. S5 will thread this
    /// into `recorded_times` row construction.
    @Published private(set) var repsByRepIndex: [Int: Int] = [:]
    /// S2 (2026-09-08): the rep index the LIVE body is currently
    /// focused on (0-based). Used to decide which rep card is
    /// expanded vs collapsed. nil until the first LAP fires.
    @Published private(set) var currentRepIndex: Int? = nil
    /// V0.54 S2.1 (2026-09-08, jodie-09 user feedback): the set-ids
    /// of completed sets in order. Drives the LIVE body's reduced-
    /// opacity treatment on those sets — every set keeps full
    /// WorkoutPreview detail (rep cards × modes, fragment rows,
    /// captions) but renders at 50% opacity so the coach's eye
    /// lands on the current set without losing the workout truth.
    /// Updated by `lapRecorded` + `stopRep` once those land; the S2
    /// seed seeds one completed set so the LIVE screenshot proves
    /// the dimming renders.
    @Published private(set) var completedSetIds: [String] = []

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

    /// S2 (2026-09-08): wire the TimingView's `onRecord` callback
    /// into the Console's rep summary. The TimingView emits the
    /// stopwatch capture (per `StopwatchCapturePayload`) when the
    /// stopwatch stops; we feed the recorded ms into
    /// `repsByRepIndex[lastRepIndex]` and advance `currentRepIndex`
    /// so the LIVE body can render the one-liner at the top of the
    /// screen. The TimingView's own `lap()` already mirrors into
    /// the VM (`@Published var repsByRepIndex`) during the
    /// `.running → .finished` transition — this path is for the
    /// single-swimmer `.finished` save flow (no LAPS — just one
    /// capture).
    func handleRecordedPayload(_ payload: StopwatchCapturePayload, reps: Int) {
        let totalReps = max(reps, 1)
        for i in 0..<totalReps {
            // Distribute the capture evenly across the rep count;
            // the TimingView's per-LAP path is authoritative when
            // it fires; this path is the fallback for the
            // single-capture single-swimmer case.
            repsByRepIndex[i] = payload.recordedTimeMs / totalReps
        }
        currentRepIndex = totalReps - 1
    }

    // MARK: - S1 firstTimeableRepIndex (acceptance test surface)

    /// S2.1 (2026-09-08, jodie-09 user feedback): DEBUG-only seed
    /// for the screenshot harness. The `-v54-demo-console-jodie09`
    /// launch arg seeds the full **jodie-09 Purposeful Threshold**
    /// workout (the rich case from the user's image feedback) so
    /// the Console's PRE + LIVE screenshots prove the full rep-card
    /// anatomy renders — not flat one-liners. The seed exercises
    /// every mode in `WorkoutPreview`'s `repCardMode(for:)`:
    ///
    ///   - Mode 1 (track):   4 × 50 @ 1:00 — 25 event rhythm / 25 easy
    ///                       + 4 × 50 — 12.5 strong / 12.5 easy
    ///   - Mode 2 (uniform): 6 × 100 — Each: 50 @ 65% / 50 @ 70% / 50 @ 75%
    ///   - Mode 3 (progression): 4 × 50 Descend: 1-4 — descending ladder
    ///   - fragmentless:    400 free easy (warm-up), 8 × 25 free easy (warm-down)
    ///
    /// Plus DIVE/SUIT/gear badges, suit gear, the "Each:" caption,
    /// the "Descend:" ladder, the verbatim "12.5m" fragment distance.
    ///
    /// The `-v54-demo-console` flag keeps the original simple 5-set
    /// Threshold Tuesday seed for S1 acceptance (it asserts the
    /// first-timeable heuristic returns orderIndex == 2). The two
    /// flags are mutually exclusive — jodie-09 wins if both present.
    #if DEBUG
    func seedV54DemoConsole() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-v54-demo-console-jodie09") || args.contains("-v54-demo-console-live-jodie09") {
            seedV54DemoConsoleJodie09()
        } else {
            seedV54DemoConsoleThreshold()
        }
    }

    /// Original S1 5-set Threshold Tuesday seed — kept for the
    /// `firstTimeableRepIndex() == 2` acceptance assertion. Uses
    /// flat sets (no fragments) so the WorkoutPreview renders the
    /// spine-only Mode 2 fallback path.
    private func seedV54DemoConsoleThreshold() {
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
        attendanceEntries = [
            CoachAttendanceEntry(swimmerId: "v54-swimmer-1", swimmerName: "Jack", intent: "in", markedAt: now, isAttending: true, reason: .explicitIn),
            CoachAttendanceEntry(swimmerId: "v54-swimmer-2", swimmerName: "Ariana", intent: "in", markedAt: now, isAttending: true, reason: .explicitIn),
            CoachAttendanceEntry(swimmerId: "v54-swimmer-3", swimmerName: "Sofie", intent: nil, markedAt: nil, isAttending: true, reason: .standingSlot)
        ]
        rosterFetchFailed = false
        if ProcessInfo.processInfo.arguments.contains("-v54-demo-console-live") {
            state = .live
        } else {
            state = .pre
        }
    }

    /// V0.54 S2.1 (2026-09-08, jodie-09 user feedback): the rich
    /// Purposeful Threshold workout — every WorkoutPreview mode
    /// represented, plus DIVE/SUIT/gear, the Each: caption, the
    /// Descend ladder, verbatim 12.5m fragment distances.
    ///
    /// Set order:
    ///   0. 400 free easy                     — fragmentless (warm-up)
    ///   1. 4 × 50 @ 1:00 — 25 event / 25 easy — Mode 1 (track), event rhythm
    ///   2. 4 × 50 — 12.5 strong / 12.5 easy  — Mode 1 (track), verbatim 12.5m
    ///   3. 6 × 100 — Each: 50 @ 65%/70%/75%  — Mode 2 (uniform) w/ Each: caption
    ///   4. 4 × 50 Descend: 1-4               — Mode 3 (progression)
    ///   5. 8 × 25 free easy                  — fragmentless (warm-down)
    ///
    /// First timeable set is orderIndex == 1 (the event-rhythm block).
    /// For the `-v54-demo-console-live` harness, we also seed
    /// `completedSetIds = ["v54-jodie09-set-1"]` so the LIVE
    /// screenshot proves the dimmed-completed render path.
    private func seedV54DemoConsoleJodie09() {
        let now = ISO8601DateFormatter().string(from: Date())
        workout = Workout(
            id: "v54-jodie09-workout",
            coachId: "v54-demo-coach",
            title: "Purposeful Threshold",
            description: "Sprint Club Purposeful Threshold main set.",
            scheduledAt: now,
            amPm: "am",
            completedAt: nil,
            status: .scheduled,
            createdAt: now,
            updatedAt: nil,
            sessionType: nil
        )
        // Fragment row helper — V0.54 S2.2 (2026-09-09, jodie-09
        // Console parse fidelity): carries the verbatim source-text
        // `distanceLabel` ("12.5") AND the coach's verbatim
        // intensity word (`intensityLabel` = "race rhythm" / "easy")
        // alongside the int wire values. The WorkoutPreviewBuilder
        // forwards both onto the ParsedFragment; the segment renderer
        // prefers `distanceLabel` for distance ("12.5m" not "13m")
        // and `intensityLabel` for the word ("race rhythm" not
        // "race_pace"). The int distanceMeters stays the wire/timing
        // key (V0.51 contract — Swift JSONDecoder rejects fractional
        // JSON numbers, so the timing values remain Int).
        func frag(_ id: String, _ orderIndex: Int, _ distance: Int, _ reps: Int, _ intensity: String, _ start: String, _ distanceLabel: String? = nil, _ intensityLabel: String? = nil) -> WorkoutSetFragment {
            WorkoutSetFragment(
                id: id,
                orderIndex: orderIndex,
                distanceMeters: distance,
                reps: reps,
                intensity: intensity,
                startType: start,
                paceTargetSec: nil,
                confidence: 0.97,
                distanceLabel: distanceLabel,
                intensityLabel: intensityLabel
            )
        }
        // 0: 400 free easy — no fragments
        let set0 = WorkoutSet(
            id: "v54-jodie09-set-0", workoutId: workout?.id ?? "v54-jodie09-workout",
            orderIndex: 0, reps: 1, distance: 400, stroke: "Free",
            intervalText: nil, intensityType: "easy", intensityLabel: nil,
            zoneTerm: "easy", paceTargetDistance: nil, gear: nil, suit: nil,
            startType: nil, dive: nil, fragments: nil, createdAt: now
        )
        // 1: 4 × 50 @ 1:00 — Mode 1 (track): 25 event rhythm / 25 easy
        let set1 = WorkoutSet(
            id: "v54-jodie09-set-1", workoutId: workout?.id ?? "v54-jodie09-workout",
            orderIndex: 1, reps: 4, distance: 50, stroke: "Free",
            intervalText: "1:00", intensityType: "race_pace",
            intensityLabel: "race_pace", zoneTerm: "hard",
            paceTargetDistance: nil, gear: ["pull"], suit: nil,
            startType: nil, dive: true,
            fragments: [
                // V0.54 S2.2 (2026-09-09, jodie-09 Console parse
                // fidelity): verbatim intensity word "race rhythm"
                // — overrides the parser type token "race_pace"
                // the segment renderer used to fall back to. The
                // rendered segment reads "25m race rhythm" instead
                // of "25m race_pace".
                frag("f-set1-25e", 0, 25, 4, "race_pace", "dive", nil, "race rhythm"),
                frag("f-set1-25z", 1, 25, 4, "easy", "push", nil, "easy")
            ],
            createdAt: now
        )
        // 2: 4 × 25 — Mode 1 (track): 12.5 strong / 12.5 easy — verbatim 12.5
        // V0.54 S2.2 (2026-09-09, jodie-09 Console parse fidelity):
        // parent distance is 25 (not 50 — each rep = 12.5 + 12.5).
        // The V0.53.3 server fix rounds 12.5 → 13 on the int wire,
        // so fragment `distanceMeters` is 13 (timing value, V0.51
        // contract); `distanceLabel: "12.5"` carries the verbatim
        // source text. Render now reads "4 × 25m" header with
        // "12.5m strong | 12.5m easy" segments — arithmetic visibly
        // sums to 25, no rounding leak. Verbatim intensity words
        // "strong" / "easy" override the parser type tokens
        // "sprint" / "easy" so the coach's language wins.
        let set2 = WorkoutSet(
            id: "v54-jodie09-set-2", workoutId: workout?.id ?? "v54-jodie09-workout",
            orderIndex: 2, reps: 4, distance: 25, stroke: "Free",
            intervalText: "1:00", intensityType: "sprint",
            intensityLabel: "strong", zoneTerm: "sprint",
            paceTargetDistance: nil, gear: nil, suit: true,
            startType: nil, dive: nil,
            fragments: [
                frag("f-set2-125s", 0, 13, 4, "sprint", "dive", "12.5", "strong"),
                frag("f-set2-125z", 1, 13, 4, "easy", "push", "12.5", "easy")
            ],
            createdAt: now
        )
        // 3: 6 × 100 — Mode 2 (uniform) w/ Each: caption
        // V0.54 S2.2: `note` carries the verbatim "Each: 50 @ 65%
        // / 70% / 75%" caption that the parser emits from the
        // source line "Each: 50 @ 65% / 70% / 75%". The header
        // HStack (WorkoutPreview.swift:461) renders it in italic
        // so the coach sees the per-set per-rep target structure.
        let set3 = WorkoutSet(
            id: "v54-jodie09-set-3", workoutId: workout?.id ?? "v54-jodie09-workout",
            orderIndex: 3, reps: 6, distance: 100, stroke: "Free",
            intervalText: "1:30", intensityType: "percent_range",
            intensityLabel: "65-75%", zoneTerm: "steady",
            paceTargetDistance: nil, gear: ["pull"], suit: nil,
            startType: nil, dive: nil,
            fragments: nil, // parser collapses into a single rg w/ Each: note
            // V0.54 S2.2: set-level Each: note — what the coach
            // actually wrote, not the parser's percent-range
            // shorthand. Renders as "(Each: 50 @ 65% / 70% / 75%)"
            // under the "6×100m Free @ 65-75%" spine.
            note: "Each: 50 @ 65% / 70% / 75%",
            createdAt: now
        )
        // 4: 4 × 50 Descend: 1-4 — Mode 3 (progression)
        // V0.54 S2.2: `descend: "1-4"` + `perRepTargets: [...]`
        // activate the ProgressionRepCard ladder. Without these,
        // Mode 3 fires on the parser's `descend` heuristic in
        // WorkoutPreview.swift:2882 BUT the per-rep target labels
        // synthesise from the intensity percent range (70-85%) and
        // the ladder collapses to four identical cards. With the
        // explicit per-rep targets, each card carries its own
        // chevron + percent label so the coach reads the build
        // sequence visually.
        let set4 = WorkoutSet(
            id: "v54-jodie09-set-4", workoutId: workout?.id ?? "v54-jodie09-workout",
            orderIndex: 4, reps: 4, distance: 50, stroke: "Free",
            intervalText: "1:00", intensityType: "percent_range",
            intensityLabel: "70-85%", zoneTerm: "hard",
            paceTargetDistance: nil, gear: ["pull"], suit: nil,
            startType: nil, dive: nil,
            fragments: nil,
            descend: "1-4",
            perRepTargets: ["70%", "75%", "80%", "85%"],
            createdAt: now
        )
        // 5: 8 × 25 free easy — no fragments (warm-down)
        let set5 = WorkoutSet(
            id: "v54-jodie09-set-5", workoutId: workout?.id ?? "v54-jodie09-workout",
            orderIndex: 5, reps: 8, distance: 25, stroke: "Free",
            intervalText: nil, intensityType: "easy", intensityLabel: nil,
            zoneTerm: "easy", paceTargetDistance: nil, gear: nil, suit: nil,
            startType: nil, dive: nil, fragments: nil, createdAt: now
        )
        sets = [set0, set1, set2, set3, set4, set5]
        attendingCount = 14
        totalCount = 14
        attendanceEntries = [
            CoachAttendanceEntry(swimmerId: "v54-swimmer-1", swimmerName: "Jack", intent: "in", markedAt: now, isAttending: true, reason: .explicitIn),
            CoachAttendanceEntry(swimmerId: "v54-swimmer-2", swimmerName: "Ariana", intent: "in", markedAt: now, isAttending: true, reason: .explicitIn),
            CoachAttendanceEntry(swimmerId: "v54-swimmer-3", swimmerName: "Sofie", intent: nil, markedAt: nil, isAttending: true, reason: .standingSlot)
        ]
        rosterFetchFailed = false
        // V0.54 S2.1: seed one completed set so the LIVE screenshot
        // proves the reduced-opacity "completed set" treatment.
        // The current set (the one elevated) is the first timable —
        // set1 (event rhythm). set0 (warm-up) is the completed one.
        completedSetIds = ["v54-jodie09-set-0"]
        // S2.1: combine the -live flag with the jodie-09 seed so
        // the LIVE screenshot of the rich workout is capturable.
        // `-v54-demo-console-live-jodie09` wins over `-v54-demo-
        // console-live` (the original S1 flag) for harness
        // predictability — same -live semantics, different seed.
        if ProcessInfo.processInfo.arguments.contains("-v54-demo-console-live")
            || ProcessInfo.processInfo.arguments.contains("-v54-demo-console-live-jodie09") {
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