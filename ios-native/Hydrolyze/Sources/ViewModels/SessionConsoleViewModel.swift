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
    /// V0.54 S3 (2026-09-09): send-off interval parsed from the
    /// parent set's `intervalText` (e.g. "1:30" → 90000 ms).
    /// `nil` when the set has no intervalText or it's unparseable
    /// (spec R7: nil/unparseable → no countdown shown, auto-progress
    /// immediately, Next-rep pill is the only CTA, debug-log it).
    @Published private(set) var intervalMs: Int? = nil
    /// V0.54 S3 (2026-09-09): milliseconds remaining in the BETWEEN
    /// countdown. Drives the BETWEEN body's `─── :12 ───` reading.
    /// Published on a `Timer.publish(every: 0.1)` cadence so the UI
    /// ticks smoothly without re-running the state machine on every
    /// tick. `nil` when not in BETWEEN (countdown is inactive).
    @Published private(set) var countdownRemainingMs: Int? = nil
    /// V0.54 S3 (2026-09-09): wave assignments keyed by lane number,
    /// derived from `WaveAllocator.allocate(...)` at `liveEnter()`.
    /// Surfaced to the LIVE body's `WaveChipStrip` (one chip per
    /// lane; tap-to-swap). Single-swimmer sets surface no chips
    /// (spec R8: solo swimmer → hidden).
    @Published private(set) var waveAssignmentsByLane: [Int: String] = [:]
    /// V0.54 S3 (2026-09-09): the `WorkoutSet` the Console is
    /// currently focused on. S2 inlined the first-timeable set into
    /// the LIVE body via `liveSetPrefill`; S3 holds it on the VM
    /// so BETWEEN/LIVE can both read `currentSet.intervalText`
    /// without re-deriving the first-timeable heuristic on every
    /// state transition.
    @Published private(set) var currentSet: WorkoutSet? = nil
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
    /// first-timeable heuristic; S3 runs the WaveAllocator fold via
    /// `liveEnter()` (spec §3 / decision 8 — wave assignment confirmed
    /// at the first rep's stopwatch entry, not in PRE).
    func startSession() {
        guard state == .pre else { return }
        state = .live
        liveEnter()
    }

    /// V0.54 S3 (2026-09-09): invoked on entering LIVE. Per spec §3 /
    /// decision 8, WaveAllocator runs HERE (the first rep's stopwatch
    /// is about to arm), NOT in PRE. The allocations are persisted
    /// idempotently via `WorkoutService.synthesizeWaveAssignmentsIfMissing`
    /// (V0.51 contract held), and the lane → swimmer mapping is
    /// cached on the VM as `waveAssignmentsByLane` for the
    /// `WaveChipStrip` UI surface.
    ///
    /// SPEC VERIFICATION (R4, 2026-09-09): `HistoricalTimePredictor.
    /// predict()` is pure-functional — every input is a parameter,
    /// no instance state, no I/O. Calling it twice with the same
    /// inputs returns the same `Prediction`. Safe to call from here.
    ///
    /// R7 (no intervalText) + R8 (solo swimmer) are handled in the
    /// downstream consumers: BETWEEN reads `intervalMs` and falls
    /// back to immediate next-rep; `WaveChipStrip` hides itself
    /// when the assignment set has fewer than 2 swimmers.
    func liveEnter() {
        // 1. Resolve the first timeable set. `firstTimeableRepIndex()`
        //    is S1's surface — it returns the orderIndex, not the set.
        guard let orderIndex = firstTimeableRepIndex(),
                        let resolvedSet = sets.first(where: { $0.orderIndex == orderIndex })
        else {
            // Spec §5 fallback: no timeable set → POST (S4). For S3
            // we leave the state at LIVE; S4 wires the transition.
            // The S2 noTimeableStub explains the gap on screen.
            return
        }
        currentSet = resolvedSet

        // 2. Parse the intervalText (R7: nil/unparseable → intervalMs stays nil).
        intervalMs = Self.parseIntervalText(resolvedSet.intervalText)

        // 3. Wave assignment fold. Build a `Swimmer` for each roster
        //    entry (WaveAllocator needs the full Swimmer shape),
        //    allocate, and cache the lane → name mapping. The DB
        //    write is best-effort (V0.51 contract — fail-open,
        //    next launch retries).
        let swimmers: [Swimmer] = attendanceEntries.map { entry in
            Swimmer(
                id: entry.swimmerId,
                coachId: "",
                firstName: entry.swimmerName,
                lastName: nil,
                birthdate: nil,
                gender: nil,
                notes: nil,
                preferredGear: nil,
                formStroke: nil,
                mainStroke: nil,
                archivedAt: nil,
                createdAt: nil
            )
        }
        if swimmers.count >= 2 {
            let assignments = WaveAllocator.allocate(
                roster: swimmers,
                sets: [resolvedSet],
                poolConfig: WaveAllocator.PoolConfig(),
                predictions: [:]
            )
            for assignment in assignments where assignment.workoutSetId == resolvedSet.id {
                waveAssignmentsByLane[assignment.lane] = swimmerDisplayName(
                    forId: assignment.swimmerId
                )
            }
            // Best-effort persist — V0.51's idempotent writer. Failures
            // log + continue (the in-memory cache still drives the UI).
            Task { [sessionId, resolvedSet, attendanceEntries, workout] in
                await WorkoutService().synthesizeWaveAssignmentsIfMissing(
                    sessionId: sessionId,
                    workoutSetId: resolvedSet.id,
                    rosterEntries: attendanceEntries.map { entry in
                        SessionRosterSnapshot.Entry(
                            swimmerId: entry.swimmerId,
                            firstName: nil,
                            lastName: entry.swimmerName,
                            lane: nil,
                            positionInLane: nil
                        )
                    },
                    coachId: workout?.coachId
                )
            }
        } else {
            // R8: solo swimmer → strip hidden, lane map empty.
            waveAssignmentsByLane = [:]
        }
    }

    /// V0.54 S3 (2026-09-09): parse a set's `intervalText` ("1:30",
    /// "1:00", "2:20-2:30" → take the first side) to milliseconds.
    /// Returns `nil` for nil/unparseable input (spec R7).
    static func parseIntervalText(_ text: String?) -> Int? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            return nil
        }
        // Take the first half of a range ("1:30-2:00" → "1:30").
        let firstHalf = text.split(separator: "-").first.map(String.init) ?? text
        let parts = firstHalf.split(separator: ":")
        guard parts.count == 2,
                        let minutes = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                        let seconds = Int(parts[1].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return (minutes * 60 + seconds) * 1000
    }

    /// Lookup a display name for a swimmer id from the attendance
    /// entries. Falls back to the id itself when no entry exists
    /// (defensive — `WaveChipStrip` reads the name for the chip).
    private func swimmerDisplayName(forId id: String) -> String {
        attendanceEntries.first(where: { $0.swimmerId == id })?.swimmerName ?? id
    }

    /// V0.54 S3 (2026-09-09): tap LAP / capture the current rep. S2
    /// wired the TimingView callback; S3 advances the state machine
    /// to BETWEEN and starts the countdown (or auto-progresses
    /// immediately when the set has no intervalText — R7).
    func lapRecorded() {
        guard state == .live else { return }
        let reps = currentSet?.reps ?? 0
        // Mark the current rep as recorded. `repsByRepIndex` is the
        // single source of truth for the LIVE body's compressed
        // summary; the TimingView's per-LAP callback already feeds
        // it in `handleRecordedPayload`, but a STOP that doesn't
        // fire LAP leaves a nil — `lapRecorded` is the safe path.
        if let idx = currentRepIndex ?? max(reps - 1, 0) as Int? {
            repsByRepIndex[idx, default: 0] = repsByRepIndex[idx] ?? 0
        }
        enterBetween()
    }

    /// V0.54 S3 (2026-09-09): tap STOP. Per spec §LIVE: "STOP
    /// transitions to BETWEEN with the rep marked complete." S4's
    /// POST summary reads the same `repsByRepIndex` map. S3 routes
    /// through BETWEEN for parity with LAP — the countdown becomes
    /// the "rest before the next rep" affordance, identical to the
    /// LAP path from the coach's perspective.
    func stopRep() {
        guard state == .live else { return }
        // Stamp a non-zero placeholder so the row reads as "captured"
        // in the POST summary if the TimingView's onRecord didn't
        // fire (rare — TimingView fires onRecord on every stopwatch
        // stop). The POST body will overwrite with the real ms when
        // S4 lands.
        if let idx = currentRepIndex ?? 0 as Int? {
            repsByRepIndex[idx, default: 0] = repsByRepIndex[idx] ?? 0
        }
        enterBetween()
    }

    /// Internal: LIVE → BETWEEN (the countdown entry). Pulls the
    /// interval from `intervalMs` (already parsed in `liveEnter`).
    /// R7: `intervalMs == nil` → auto-progress immediately via
    /// `nextRep()` (the Next-rep pill is the only CTA, no countdown
    /// shown, debug-logged).
    private func enterBetween() {
        guard let reps = currentSet?.reps, reps > 0 else {
            // No reps to iterate — fall through to nextRep, which
            // walks the state machine forward.
            nextRep()
            return
        }
        // Advance `currentRepIndex` so the BETWEEN body shows the
        // rep that's "on deck" (the next rep, not the one we just
        // finished).
        let nextIdx = (currentRepIndex ?? -1) + 1
        // Last rep of the set → countdown auto-progresses to POST
        // on :00 (spec §BETWEEN + R7 fallback). For S3 we leave the
        // state in BETWEEN until the countdown hits :00, then
        // `nextRep` decides whether to advance LIVE or POST. S4
        // fills the POST body.
        guard let intervalMs = intervalMs else {
            // R7: no intervalText. Auto-progress immediately.
            print("[SessionConsoleViewModel] R7: no intervalText for set \(currentSet?.id ?? "nil"); auto-progressing past BETWEEN")
            nextRep()
            return
        }
        state = .between
        countdownRemainingMs = intervalMs
        startCountdown(intervalMs: intervalMs, totalReps: reps)
    }

    /// V0.54 S3 (2026-09-09): the countdown timer. Fires every
    /// 100ms so the `:12 → :11 → :10` reading updates smoothly. At
    /// 0 the timer advances via `nextRep()` (which decides LIVE vs
    /// POST). Held weakly on the VM via a private `Task` handle —
    /// cancelled when the VM re-enters a non-BETWEEN state, or when
    /// `nextRep()` short-circuits the countdown.
    private var countdownTask: Task<Void, Never>? = nil

    private func startCountdown(intervalMs: Int, totalReps: Int) {
        countdownTask?.cancel()
        let startedAt = Date()
        countdownTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
                let remaining = max(intervalMs - elapsed, 0)
                await MainActor.run {
                    self.countdownRemainingMs = remaining
                }
                if remaining <= 0 {
                    await MainActor.run {
                        self.countdownFinished(totalReps: totalReps)
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    /// V0.54 S3 (2026-09-09): the countdown hit :00. Either advance
    /// LIVE for the next rep, or — if the just-finished rep was the
    /// last in the set — transition to POST (spec §BETWEEN).
    private func countdownFinished(totalReps: Int) {
        countdownTask?.cancel()
        countdownTask = nil
        countdownRemainingMs = nil
        let finishedIdx = (currentRepIndex ?? -1) + 1
        if finishedIdx >= totalReps - 1 {
            // Last rep done — spec §BETWEEN: auto-progress to POST.
            // S4 wires the POST body; S3 lands the state transition
            // and clears the countdown. The POST body's stub is the
            // "S4 fills this" placeholder, identical to the S1 stub.
            state = .post
            return
        }
        // Otherwise advance LIVE for the next rep.
        currentRepIndex = finishedIdx
        state = .live
    }

    /// V0.54 S3 (2026-09-09): the `Next rep` pill — short-circuits
    /// the countdown (spec §BETWEEN: "non-blocking, exists for cases
    /// where the send-off is already past"). Fires from any
    /// remaining-countdown position. If the just-finished rep is
    /// the last, transitions to POST.
    func nextRep() {
        countdownTask?.cancel()
        countdownTask = nil
        countdownRemainingMs = nil
        let finishedIdx = (currentRepIndex ?? -1) + 1
        let totalReps = currentSet?.reps ?? 0
        if totalReps > 0 && finishedIdx >= totalReps - 1 {
            state = .post
            return
        }
        currentRepIndex = finishedIdx
        state = .live
    }

    /// V0.54 S3 (2026-09-09): swap two lanes' wave_assignment rows
    /// (spec §3: "Tap a lane chip → quick-action menu with the
    /// other lanes' names → tap to move."). The in-memory
    /// `waveAssignmentsByLane` is the source of truth for the UI —
    /// the DB write is a separate follow-up (V0.55 candidate per
    /// spec §11 "Ask first: removing wave drag-and-drop").
    /// `a` and `b` are lane numbers (1-indexed).
    func swapLanes(a: Int, b: Int) {
        guard a != b,
                        let aName = waveAssignmentsByLane[a],
                        let bName = waveAssignmentsByLane[b] else {
            return
        }
        waveAssignmentsByLane[a] = bName
        waveAssignmentsByLane[b] = aName
        Haptics.tap()
    }

    /// S1 stub-body escape hatch: when the LIVE/BETWEEN/POST stub
    /// body renders a "Back to PRE" button, it needs a way to flip
    /// `state` back. S2/S3/S4 will delete this — it's purely a debug
    /// surface so the S1 acceptance harness can re-enter PRE without
    /// dismissing the cover.
    func resetToPre() {
        countdownTask?.cancel()
        countdownTask = nil
        countdownRemainingMs = nil
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
        if args.contains("-v54-demo-console-jodie09")
            || args.contains("-v54-demo-console-live-jodie09")
            || args.contains("-v54-demo-console-between-jodie09") {
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
        //
        // V0.54 S3 (2026-09-09): `-v54-demo-console-between-jodie09`
        // lands in BETWEEN for the screenshot harness. After seeding
        // the rich workout + LIVE state, we run `liveEnter()` to
        // populate `intervalMs` / `waveAssignmentsByLane`, then
        // force the state to `.between` with a non-zero countdown.
        // The seeded interval is the parent set's "1:30" → 90000 ms,
        // matching the wireframe spec §BETWEEN L120-136.
        if ProcessInfo.processInfo.arguments.contains("-v54-demo-console-between-jodie09") {
            state = .live
            liveEnter()
            currentRepIndex = 0
            state = .between
            countdownRemainingMs = intervalMs ?? 90_000
        } else if ProcessInfo.processInfo.arguments.contains("-v54-demo-console-live")
            || ProcessInfo.processInfo.arguments.contains("-v54-demo-console-live-jodie09") {
            // V0.54 S3 (2026-09-09): the LIVE seed must run
            // `liveEnter()` too — without it, `waveAssignmentsByLane`
            // stays empty and the WaveChipStrip (rendered above the
            // stopwatch) is invisible. The LIVE screenshot now proves
            // WaveAllocator's output surfaces in the Console's
            // first-rep header (spec §3 / decision 11). For the
            // -between flag we set state = .live first so liveEnter's
            // `currentSet = resolvedSet` writes fire correctly — the
            // between flag then overrides state. For the -live flag
            // we stay in .live and liveEnter's state-machine
            // transitions are no-ops (it only mutates `intervalMs`,
            // `waveAssignmentsByLane`, and the best-effort DB write).
            state = .live
            liveEnter()
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