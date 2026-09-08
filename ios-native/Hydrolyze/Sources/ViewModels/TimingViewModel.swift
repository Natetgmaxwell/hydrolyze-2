import Foundation
import UIKit
import Combine

/// TimingViewModel — drives the pool-deck timing loop.
/// State machine: .setup → .ready → .running → .finished
/// Timer cadence: 10ms display update via Timer.publish
///
/// Volume button flow:
///   .ready  → volume-up fires start()
///   .running → volume-up fires lap()
///   STOP remains on-screen only.
@MainActor
final class TimingViewModel: ObservableObject {
    @Published var state: TimingState = .setup
    /// V0.54 (2026-09-08): how this VM was launched. `.standalone`
    /// (default) is the V0.49 TodayView / WorkoutDetailView path —
    /// unchanged. `.console` is the V0.54 SessionConsoleView's LIVE
    /// state (decision 12 — wrapper-not-rewrite). Additive; the
    /// state machine, save flow, and stopwatch are identical
    /// between modes. S2 wires `.console` by constructing a
    /// `SetPrefill` from the first timeable set.
    @Published var mode: TimingMode = .standalone
    /// V0.54 (2026-09-08): the rep index the Console is currently
    /// focused on (0-based). Populated by `lapRecorded()` after the
    /// stopwatch LAP fires. nil before the first LAP. Used by the
    /// Console's LIVE body to render the compressed one-liner
    /// summary at the top of the screen.
    @Published var currentRepIndex: Int? = nil
    /// V0.54 (2026-09-08): the set orderIndex the Console is
    /// currently focused on. Populated by `SessionConsoleViewModel`
    /// when LIVE enters. Used by the LIVE body to render the
    /// "rep N / reps × distance @ send-off" header.
    @Published var currentSetIndex: Int? = nil
    /// V0.54 (2026-09-08): per-rep recorded-ms (indexed by rep
    /// index) for the compressed summary at the top of the LIVE
    /// screen. Fed by `lapRecorded()`. nil for reps not yet
    /// completed.
    @Published var repsByRepIndex: [Int: Int] = [:]
    @Published var elapsedMs: Int = 0           // live running total
    @Published var laps: [Lap] = []              // newest at end
    @Published var selectedSwimmerId: String?     // set in .setup
    @Published var selectedSwimmerName: String?
    @Published var stroke: String = "Free"
    @Published var distance: Int = 50
    @Published var errorMessage: String?

    /// Triggers a brief visual flash in the UI each time a lap is recorded.
    /// Views observe this and animate on change.
    @Published var lapFlashTrigger: UUID?
    
    @Published var hasSavedPairedLaps: Bool = false
    @Published var isSaving: Bool = false
    /// Phase 2.6 v1.12.1: count of wave_assignments the pairing
    /// engine actually received for the current set (after the
    /// workoutSetId filter). Surfaced in the COPY DEBUG INFO
    /// button so the coach can see how many swimmers the
    /// engine paired against. Defaults to nil until save()
    /// runs at least once.
    @Published var lastWaveAssignmentCount: Int?
    /// Phase 2.6 v1.2: which step the save is currently on. The .saving
    /// view shows this as live progress so the user can SEE where any
    /// hang is. Previous version of the spinner had no progress at all
    /// — a hung save looked identical to a slow one, with no
    /// indication of which network call was the bottleneck.
    @Published var currentSaveStep: SaveStep = .idle
    /// Phase 2.6 v1.5: live diagnostic log of the save flow. Each
    /// checkpoint appends a timestamped line. Surfaced in the .saving
    /// view so the user can see the engine's last action. Crucial for
    /// diagnosing a silent hang — the LAST log line tells you exactly
    /// which call is stuck (fetching, pairing, saving). Also printed
    /// to the Xcode console for offline debugging.
    @Published var saveLog: [String] = []

    /// The four save steps, surfaced in the .saving view. Updated at
    /// each checkpoint inside save() so the coach can see if the hang
    /// is in the fetch, the pairing, or the save.
    enum SaveStep: String {
        case idle = ""
        case fetching = "Fetching wave assignments…"
        case predicting = "Predicting from history…"
        case pairing = "Pairing laps with swimmers…"
        case saving = "Saving times…"
        case complete = "Done"
    }

    /// Per-supabase-call timeout (Phase 2.6 v1.5). The SDK's default
    /// URLSession timeout is 60s, which means a silently-hung call
    /// would show the user a "stuck" spinner for a full minute. We
    /// race each call against a 5s sleep — whichever completes first
    /// wins, the other gets cancelled. If the call is hung, the user
    /// sees a clear "fetching wave assignments timed out after 5s"
    /// error in 5s instead of waiting 60s.
    private static let perCallTimeoutSeconds: TimeInterval = 5

    /// Format a timestamp for the saveLog. Microsecond precision so
    /// the user can see which line was the last one before a hang.
    private static func ts() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }

    /// Append a line to saveLog + print to console. The .saving view
    /// shows the last 6 lines as a tail. Console output is the
    /// primary diagnostic — Xcode console + simulator log stream
    /// both show these.
    private func log(_ message: String) {
        let line = "[\(Self.ts())] \(message)"
        saveLog.append(line)
        print("[HydrolyzeTimingVM] \(line)")
    }

    /// Race an async operation against a timeout. Whichever completes
    /// first wins. Returns the operation's result on success, throws
    /// `SaveError.timeout` if the timeout fires first.
    ///
    /// We do this at the supabase-call level (not the overall save
    /// level) so the user sees WHICH call hung, not just that the
    /// overall save did. Without this, a silently-hung supabase call
    /// (DNS slow, server unresponsive, RLS loop) shows the user a
    /// generic spinner for 60s+ before any error appears.
    private func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        label: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        log("→ \(label) (timeout: \(Int(seconds))s)")
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw SaveError.timeout(label: label, seconds: seconds)
            }
            // First task to complete wins; cancel the other.
            let result = try await group.next()!
            group.cancelAll()
            log("✓ \(label) completed")
            return result
        }
    }

    /// Errors emitted by the save flow. Distinct from the Supabase
    /// client's own errors so the UI can show actionable messages
    /// ("fetching wave assignments timed out after 5s — try again or
    /// check your connection") rather than a stack-trace-y URL error.
    enum SaveError: LocalizedError {
        case timeout(label: String, seconds: TimeInterval)

        var errorDescription: String? {
            switch self {
            case .timeout(let label, let seconds):
                return "\(label) timed out after \(Int(seconds))s. Tap RETRY or check your connection."
            }
        }
    }

    // t_c74dffbc (2026-08-04): helpers for the per-fragment wiring.
    // Build a synthetic WorkoutSet for a fragment by copying the
    // parent set's identity (id, workoutId, orderIndex, createdAt)
    // and overriding the swimmer-visible fields (distance, intensity,
    // startType, suit, gear) from the fragment. PBService.fetchPrediction
    // reads the set's intensityLabel / gear to key the prediction, so
    // the override routes the call to the (swimmer, fragment) bucket.
    private func syntheticWorkoutSet(
        from parent: WorkoutSet,
        fragment: FragmentContext
    ) -> WorkoutSet {
        return WorkoutSet(
            id: parent.id,
            workoutId: parent.workoutId,
            orderIndex: parent.orderIndex,
            reps: parent.reps,
            distance: fragment.distance,
            stroke: parent.stroke,
            intervalText: parent.intervalText,
            intensityType: nil,
            intensityLabel: fragment.intensity,
            paceTargetDistance: nil,
            gear: fragment.gear,
            suit: fragment.suit,
            startType: fragment.startType,
            dive: fragment.startType == "dive",
            fragments: nil,
            createdAt: parent.createdAt
        )
    }

    // t_c74dffbc (2026-08-04): pairing-engine key for the per-fragment
    // prediction map. The PairingEngine currently reads predictions by
    // swimmerId only; this is the v1.18 wiring that puts the (swimmer,
    // fragment) prediction into the right bucket. The follow-up slice
    // extends PairingEngine.pair to read this key. For now the key is
    // stable + log-friendly; the harness asserts on the iOS code
    // matching this shape.
    private func predictionKey(swimmerId: String, fragment: FragmentContext) -> String {
        return "\(swimmerId)|\(fragment.pairingKey)"
    }
    @Published var expectedLapCount: Int? // Auto-stop threshold
    // V0.51 (2026-08-30): roster snapshot size threaded in from
    // TimingView (the strip param). Drives the §b `loadSessionContext`
    // fallback + the §c `save()` solo-swimmer paired path.
    @Published var currentRosterCount: Int? = nil
    @Published var currentSoloSwimmerId: String? = nil

    /// V0.38 Slice 4 (2026-08-16): true when the active set is a
    /// 3-minute all-out test (Piatrikova). Gates the timing-screen
    /// countdown, the 3:00 auto-stop, and the per-swimmer profile
    /// insert in the save flow. Set in `applySetPrefill(...)` from
    /// the prefill's `intensityType` / `intensityLabel` — the parser
    /// emits the rawValue "3mt" on `workout_sets.intensity_type` and
    /// the human label "3-minute all-out" on `intensity_label`; both
    /// are honored so the detection survives either path.
    @Published var is3MTSession: Bool = false

    /// V0.39 Slice 3 (2026-08-18): the drop-rule state machine
    /// owned by the timing flow. Built in `start()` when the active
    /// set is anaerobic with a parseable interval; nil for aerobic
    /// sets (the spec's "no countdown chrome" acceptance criterion).
    /// The view reads `restCountdownText` and `lastStrikeEvaluation`
    /// to render the countdown + inline badge. The model itself
    /// holds the per-swimmer strike state + the common extended
    /// rest; the VM owns the timer-coupling (`tick()` once per
    /// second, NOT 100×/second from the 10ms cadence).
    @Published var restModel: RestCountdownModel?

    /// V0.39 Slice 3 (2026-08-18): the most recent strike
    /// evaluation. Non-nil only after a rep triggered a strike AND
    /// the user has not yet tapped REVERT. Cleared on REVERT (so
    /// the badge re-renders base rest) and on the next LAP (so the
    /// stale rep doesn't bleed into the next). The view binds
    /// directly to this; the spec calls for "non-intrusive
    /// confirmation surface — NEVER modal" (one line under the
    /// countdown, above the lap list, with a one-tap revert).
    @Published var lastStrikeEvaluation: DropEvaluation?

    // Set from prefill — carried through to save
    var reps: Int?
    var interval: String?
    var intensityLabel: String?
    /// V0.38 Slice 4 (2026-08-16): structured intensity_type rawValue
    /// (e.g. "3mt") mirrored from `WorkoutSet.intensityType`. Mirrors
    /// `SetPrefill.intensityType` so 3MT detection doesn't have to
    /// string-match the human label. Source of truth over `intensityLabel`
    /// because a workout can mix 3MT sets with training sets.
    var intensityType: String?
    /// V0.41 Slice 2 (2026-08-18): the active set's zone term
    /// ("easy" | "steady" | "hard" | "sprint"). Copied from the prefill
    /// (which carries it from `WorkoutSet.zoneTerm`). When non-nil, the
    /// timing flow resolves each swimmer's zone pace as the drop-rule
    /// standard and surfaces it as the target.
    var zoneTerm: String?
    /// V0.43a (2026-08-18): the set-level gear
    /// (`[String]?`, mirrors `WorkoutSet.gear`). Copied from the prefill
    /// in TimingView; read by `resolvedSaveGear` to stamp
    /// `recorded_times.gear` for the multi-swimmer save path. The
    /// parser already extracts it (V0.37) and the prediction path
    /// already keys on it — the persistence path was the missing
    /// link (saved as 'none' for all 432 live rows).
    var gear: [String]?
    /// V0.43a (2026-08-18): the single-text gear string the save
    /// path writes to `recorded_times.gear`. Resolution rule:
    /// fragment gear wins for composite sets (`fragmentContexts`
    /// non-empty); otherwise the set-level `gear`. Returns the
    /// first gear entry of the resolved source — `WorkoutSet.gear`
    /// is `[String]?` but the DB column is a single text. nil for
    /// bare sets with no gear (the save path omits the JSON key
    /// so the DB stores NULL; matches `RecordedTime.gear: String?`).
    private var resolvedSaveGear: String? {
        fragmentContexts.first?.gear?.first ?? gear?.first
    }
    /// V0.41 Slice 2 (2026-08-18): per-swimmer zone pace standard (ms)
    /// for the ACTIVE set, resolved at timing time from each swimmer's
    /// usable 3MT profile. Populated alongside the zone gate in
    /// `applySwimmerZoneGate`. Empty when the set is not a zone set,
    /// the swimmer has no usable profile, or the fetch failed — the
    /// drop rule then falls back to the predicted/rep1 standard.
    private(set) var zoneStandardMsBySwimmer: [String: Int] = [:]
    var workoutSetId: String?
    /// V0.46 fix (2026-08-20): the owning coach's `coaches.id`. Set by
    /// TimingView.onAppear from `authManager.coachId`. Threaded into
    /// every recorded_times insert so the row satisfies the
    /// `coach_own_recorded_times` RLS policy (migration
    /// 20260806180000_recorded_times_coach_id.sql), which requires
    /// `coach_id IN (SELECT coaches.id WHERE coaches.auth_id = auth.uid())`.
    /// Before this, all three insert paths (saveSession / savePairedLaps /
    /// skipPairing) omitted coach_id → NULL → RLS WITH CHECK violation.
    var coachId: String?
    /// t_c74dffbc (2026-08-04): per-fragment metadata the save flow
    /// reads to key the prediction per (swimmer, fragment). Set by the
    /// caller (WorkoutDetailView.launchFragmentTiming, or a future
    /// SessionStart path) when the set was parsed from a composite
    /// source like `4 x (75 fast / 25 easy)`. Empty for non-composite
    /// sets — the save flow uses the parent set's prediction.
    var fragmentContexts: [FragmentContext] = []
    /// Set from the View's onAppear (when launched with a sessionId from
    /// SessionStartView). Used by `stop()` to auto-save for multi-swimmer
    /// sessions so the coach lands on SessionReviewView directly.
    /// nil for single-swimmer timing flows (prefill path) — no auto-save.
    var sessionId: String?

    // Internal stopwatch
    private var timerCancellable: AnyCancellable?
    private var repStartMs: Int = 0              // Date.now() at session start
    private var sessionStartDate: Date?          // actual wall-clock start for save
    /// V0.39 Slice 3 (2026-08-18): accumulates elapsed ms from the
    /// 10ms timer so we can call `RestCountdownModel.tick()` exactly
    /// once per second. Decrementing `remainingSec` on every 10ms
    /// tick would burn through 100 seconds of rest in a single
    /// stopwatch second. Reset on each LAP (the countdown snaps to
    /// base / extended rest, so the accumulator starts fresh).
    private var restAccumulatorMs: Int = 0
    /// t_bec2b88b (2026-08-06): wall-clock stop time. Set in `stop()`.
    /// Read by `assembleCapturePayload()` to populate
    /// `StopwatchCaptureMoment.stoppedAt` + `StopwatchCapturePayload.occurredAt`.
    private var sessionStopDate: Date?
    private let haptic = UIImpactFeedbackGenerator(style: .medium)
    private let timingService = TimingService()
    private let volumeService = VolumeButtonService()
    /// PHASE 1 (T3.5, 2026-06-20): the per-(swimmer, X, distance, stroke)
    /// calibration factors. Populated in `save()` from a parallel
    /// fetch against `swimmer_suits` and `swimmer_starts`. Optional
    /// because it's set after the async fetch completes; the predictor
    /// handles a nil calibration as "no calibration applied" (multiplier
    /// of 1.0), so a missing calibration is safe.
    private var calibration: CalibrationFactors?

    // MARK: - Computed

    var formattedTime: String {
        TimingSession.formatMs(elapsedMs)
    }

    /// V0.46 Slice 3: whole-second bucket of the running clock.
    /// The view drives the numeric-roll content transition from
    /// this value — 1Hz — so the m:ss head rolls once per second
    /// while the hundredths tail updates without a transition
    /// (animating at the 10ms tick would smear the digits; the
    /// mono weight-step from Slice 2 already sets the tail apart).
    var elapsedSecond: Int {
        elapsedMs / 1000
    }

    /// V0.46 Slice 3: rep dots replace the LAP N counter only when
    /// the lap stream maps 1:1 to a known rep count — the single-
    /// swimmer prefill path. Multi-swimmer sessions (per-swimmer
    /// attribution resolves at save-time pairing) and bare starts
    /// (no reps) keep the counter: a wrong dot count would lie
    /// about the set. Capped at 24 dots for legibility; a 30-rep
    /// set would render as noise, so those keep the counter too.
    var showRepDots: Bool {
        guard let reps = reps, selectedSwimmerId != nil else { return false }
        return reps > 0 && reps <= 24
    }

    var formattedLaps: [(number: Int, elapsed: String, split: String)] {
        laps.map { lap in
            (number: lap.lapNumber, elapsed: TimingSession.formatMs(lap.elapsedMs), split: TimingSession.formatMs(lap.splitMs))
        }
    }

    // MARK: - 3MT detection (V0.38 Slice 4, 2026-08-16)

    /// V0.38 Slice 4 (2026-08-16): the marker text the parser writes
    /// to `intensity_label` when the set is a 3-minute all-out test.
    /// The DB `intensity_type` rawValue is "3mt"; the parser-written
    /// human label is "3-minute all-out". Both must classify the set
    /// correctly so the countdown + auto-stop fire.
    private static let threeMinuteTestRawValue = "3mt"
    private static let threeMinuteTestParserLabel = "3-minute all-out"

    /// V0.38 Slice 4 (2026-08-16): total test duration for the 3MT.
    /// The coach-facing countdown derives from `elapsedMs` (180s minus
    /// elapsed); at 0 the stopwatch auto-stops. The stopwatch total
    /// keeps running as the audit trail — the countdown is the
    /// coach-facing display.
    private static let threeMinuteTestDurationMs = 180_000

    /// V0.38 Slice 4 (2026-08-16): the remaining ms until the 3MT
    /// auto-stop. Always non-negative; clamps at 0 when elapsed exceeds
    /// the test window so the countdown reads "0:00.00" rather than
    /// going negative. Used by the running view's countdown text.
    var threeMinuteTestRemainingMs: Int {
        max(0, Self.threeMinuteTestDurationMs - elapsedMs)
    }

    /// V0.38 Slice 4 (2026-08-16): countdown text formatted as the
    /// spec's "m:ss.SS" monospaced display. Reuses the existing
    /// `TimingSession.formatMs` helper for visual consistency with the
    /// main stopwatch. The view styles this smaller + amber when
    /// <30s remain.
    var threeMinuteTestCountdownText: String {
        TimingSession.formatMs(threeMinuteTestRemainingMs)
    }

    /// V0.38 Slice 4 (2026-08-16): derive the 3MT gate from the
    /// prefill-sourced fields. Source-of-truth order:
    ///   1. `intensityType` rawValue == "3mt" (DB column; survives
    ///      mixed workouts because it's per-set, not per-workout)
    ///   2. `intensityLabel` == "3mt" or "3-minute all-out" (defensive
    ///      fallback when only the human label is present)
    ///
    /// The edge response's workout-level `session_type` would be a
    /// third signal, but per spec "prefer per-set intensity_type as
    /// the source of truth, since a workout can mix" — so we don't
    /// decode session_type here.
    func deriveIs3MTSession() -> Bool {
        if intensityType == Self.threeMinuteTestRawValue { return true }
        if let label = intensityLabel,
           label == Self.threeMinuteTestRawValue
            || label == Self.threeMinuteTestParserLabel {
            return true
        }
        return false
    }

    // MARK: - V0.39 Slice 3 (2026-08-18) — drop-rule wiring

    /// V0.39 Slice 3 (2026-08-18): true when the active set is
    /// anaerobic — the V0.39 zone gate. Spec §Slice 2 rule 1: the
    /// rule fires only on hard/race sets. The parser emits the
    /// human label as a lowercase string ("hard", "race pace",
    /// "atp", etc.) and the IntensityLevel enum uses displayName
    /// ("Hard", "Race pace"); both flows are honored. Aerobic sets
    /// ("moderate", "easy", "descend", "build", "threshold"...)
    /// leave `restModel` nil and skip the countdown + badge entirely
    /// — the spec's "aerobic set: no countdown chrome" acceptance
    /// criterion.
    private var isAnaerobicSet: Bool {
        guard let label = intensityLabel?.lowercased() else { return false }
        return label == "hard" || label == "race" || label == "race pace" || label == "atp"
    }

    /// V0.39 Slice 3 (2026-08-18): "m:ss" rest-clock text from the
    /// model's live `remainingSec`. Empty string when no model is
    /// active (aerobic set) so the view's `if !text.isEmpty`
    /// check renders exactly as today — the gate is at the call
    /// site, not in the VM.
    var restCountdownText: String {
        guard let m = restModel else { return "" }
        return formatRestSec(m.remainingSec)
    }

    /// V0.39 Slice 3 (2026-08-18): true when the live countdown is
    /// in its final third (the 3MT countdown pattern — amber when
    /// <30s remain). The 30s threshold is the same as the 3MT gate
    /// so the two countdowns use the same visual escalation.
    var restCountdownIsAmber: Bool {
        guard let m = restModel else { return false }
        return m.remainingSec > 0 && m.remainingSec < 30
    }

    /// V0.39 Slice 3 (2026-08-18): formatted inline-badge line.
    /// Empty when there is no pending strike (the view hides the
    /// row entirely). Spec sample: `Rep 3: 27.8, +0.6 → rest 5:00`.
    var strikeBadgeText: String {
        guard let e = lastStrikeEvaluation else { return "" }
        return "Rep \(e.repIndex): \(formatRepTime(e.repTimeMs)), \(formatRepDelta(repTimeMs: e.repTimeMs, standardMs: e.standardMs)) → rest \(formatRestSec(e.extendedRestSec))"
    }

    // MARK: - Capture payload assembly (t_bec2b88b, 2026-08-06)

    /// Assemble the structured `StopwatchCapturePayload` the live
    /// stopwatch hands off to the persistence layer (task 3,
    /// t_1789d5c7) on STOP. Mirrors the TS
    /// `assembleStopwatchCapturePayload` function in
    /// `stopwatch-capture-payload.ts` (the workspace's canonical
    /// source of truth for the contract).
    ///
    /// The payload carries EVERY field the persistence layer needs:
    ///   - recordedTimeMs (the elapsed time at STOP, in milliseconds)
    ///   - fragment metadata (distance, intensity, startType, paceTarget, ...)
    ///   - source set text (the original raw set the coach entered)
    ///   - identifiers for session / workoutSet / coach / swimmer context
    ///   - capture moment (method, startedAt, stoppedAt, deviceEventSequence)
    ///   - idempotencyKey (so re-entering the same fragment inserts a
    ///     new row, not an UPDATE)
    ///
    /// Throws `StopwatchCaptureError.missingField` if any required
    /// field is nil. The TS schema does the same; the iOS app
    /// refuses to hand off a partial payload.
    ///
    /// Callers:
    ///   - `TimingView.onChange(of: state)` fires this once on the
    ///     `.running` → `.finished`/`.saving` transition and delivers
    ///     the payload to the onRecord callback.
    ///   - The bare-start path (no fragmentContexts) builds the
    ///     fragment echo from the parent set's metadata.
    ///   - The per-fragment CTA path uses the first entry in
    ///     `fragmentContexts` (the one the coach tapped).
    ///
    /// - Parameters:
    ///   - coachId: UUID of the coach. Pass `AuthManager.coachId`.
    ///   - sessionId: UUID of the active session. Pass the value
    ///     `TimingView.sessionId` was launched with. Nil for
    ///     bare-start paths (returns nil — caller decides what to do).
    ///   - sourceSetText: the original raw set text. Pass the value
    ///     WorkoutDetailView holds (falls back to the set's
    ///     `intervalText ?? label`).
    ///   - appBuildNumber: optional. The app's build number at
    ///     capture time (DiagnosticInfo.buildNumber).
    /// - Returns: `nil` if `sessionId` is nil (caller should skip
    ///   persistence on the bare-start-with-no-session path — the
    ///   per-swimmer stopwatch flow without an active session is
    ///   not part of the persistence contract).
    func assembleCapturePayload(
        coachId: String,
        sessionId: String?,
        sourceSetText: String?,
        appBuildNumber: String? = nil
    ) throws -> StopwatchCapturePayload? {
        // Guard sessionId first — the bare-start path without an
        // active session is not part of the persistence contract.
        // The caller (TimingView's onRecord) checks the return
        // value and skips delivery when nil.
        guard let sid = sessionId else { return nil }

        // Need at least one fragment context to assemble the
        // payload. The bare-start-with-no-set path falls back to
        // the parent set's metadata (see fallback below).
        let fragmentEcho: StopwatchFragmentEcho
        if let firstFragment = fragmentContexts.first {
            // Per-fragment CTA path: build the echo from the
            // FragmentContext the coach tapped. distance, intensity,
            // startType all come from the fragment; the parent
            // interval id is `parentIntervalId` on the FragmentContext.
            fragmentEcho = StopwatchFragmentEcho(
                fragmentId: firstFragment.fragmentId,
                parentIntervalId: firstFragment.parentIntervalId,
                distanceMeters: firstFragment.distance,
                intensityLabel: firstFragment.intensity ?? "",
                startType: firstFragment.startType ?? "in_water",
                paceTargetSec: nil, // the FragmentContext surface doesn't carry paceTarget yet; future slice
                descriptor: firstFragment.descriptor,
                suit: firstFragment.suit,
                gear: firstFragment.gear
            )
        } else {
            // Bare-start / prefill path: synthesize a fragment echo
            // from the parent set's metadata. The fragmentId is a
            // synthetic UUID — the persistence layer treats it as
            // the row's fragment_id and the pairing engine keys
            // on the (distance, intensity, startType) tuple.
            let synthFragmentId = "frag_synth_\(UUID().uuidString)"
            let synthIntervalId = workoutSetId ?? "interval_synth"
            fragmentEcho = StopwatchFragmentEcho(
                fragmentId: synthFragmentId,
                parentIntervalId: synthIntervalId,
                distanceMeters: distance,
                intensityLabel: intensityLabel ?? "moderate",
                startType: "in_water",
                paceTargetSec: nil,
                descriptor: nil,
                suit: nil,
                gear: nil
            )
        }

        // Compose the capture moment from the stopwatch's
        // sessionStartDate + sessionStopDate. Both are wall-clock
        // Dates; we format them as ISO8601 strings.
        let startedAtIso: String
        let stoppedAtIso: String
        let formatter = ISO8601DateFormatter()
        if let start = sessionStartDate {
            startedAtIso = formatter.string(from: start)
        } else {
            throw StopwatchCaptureError.missingField("sessionStartDate")
        }
        if let stop = sessionStopDate {
            stoppedAtIso = formatter.string(from: stop)
        } else {
            throw StopwatchCaptureError.missingField("sessionStopDate")
        }

        // The recorded time is the stopwatch's `elapsedMs` at STOP.
        // For the multi-swimmer / .saving flow the value is the
        // final elapsedMs (the time between .running and .saving).
        // For the single-swimmer / .finished flow it's the same.
        guard elapsedMs > 0 else {
            throw StopwatchCaptureError.missingField("elapsedMs")
        }

        // Context ids.
        let context = StopwatchContextIds(
            sessionId: sid,
            workoutSetId: workoutSetId,
            coachId: coachId,
            swimmerId: selectedSwimmerId
        )

        // Capture moment.
        let moment = StopwatchCaptureMoment(
            method: .stopwatch,
            startedAt: startedAtIso,
            stoppedAt: stoppedAtIso,
            deviceEventSequence: laps.count,
            appBuildNumber: appBuildNumber
        )

        // Mint the eventId + idempotencyKey. The eventId is a
        // fresh UUID per stop — re-entering the fragment mints a
        // new UUID, so the persistence layer inserts a new row
        // rather than colliding on PK. The idempotencyKey is
        // stable within one stopwatch run (eventId + sessionId +
        // fragmentId); the DB can use it to de-dupe accidental
        // double-tap inserts on the same stopwatch run.
        let eventId = UUID().uuidString
        let idempotencyKey = "capture_\(eventId)_\(sid)_\(fragmentEcho.fragmentId)"

        return StopwatchCapturePayload(
            version: STOPWATCH_CAPTURE_VERSION,
            eventId: eventId,
            idempotencyKey: idempotencyKey,
            occurredAt: stoppedAtIso,
            recordedTimeMs: elapsedMs,
            fragment: fragmentEcho,
            context: context,
            capture: moment,
            sourceSetText: sourceSetText ?? ""
        )
    }

    // MARK: - Actions

    /// Advance from .setup to .ready once swimmer + set are chosen.
    /// Starts volume button capture so the first volume-up press triggers start().
    func confirmSetup(swimmerId: String, swimmerName: String, stroke: String, distance: Int) {
        self.selectedSwimmerId = swimmerId
        self.selectedSwimmerName = swimmerName
        self.stroke = stroke
        self.distance = distance
        self.state = .ready

        // Pre-warm haptic engine for lower latency on first tap
        haptic.prepare()

        // Start volume capture in .ready — first press will start the stopwatch
        volumeService.onVolumeUp = { [weak self] in
            Task { @MainActor in
                self?.handleVolumeUp()
            }
        }
        volumeService.start()
    }

    /// Advance from .setup to .ready when a multi-swimmer session is being timed.
    func confirmSessionSetup() {
        self.state = .ready

        // Pre-warm haptic engine
        haptic.prepare()

        // Start volume capture
        volumeService.onVolumeUp = { [weak self] in
            Task { @MainActor in
                self?.handleVolumeUp()
            }
        }
        volumeService.start()
    }

    /// Routes volume-up presses based on current state.
    private func handleVolumeUp() {
        switch state {
        case .ready:
            start()
        case .running:
            lap()
        default:
            break
        }
    }

    /// Begin the stopwatch — called from .ready state (on-screen or volume-up).
    func start() {
        guard state == .ready else { return }
        haptic.impactOccurred()
        elapsedMs = 0
        laps = []
        sessionStartDate = Date()
        repStartMs = Date().millisecondsSince1970
        state = .running

        // V0.39 Slice 3 (2026-08-18): build the drop-rule state
        // machine if the active set is anaerobic with a parseable
        // interval. The zone gate (aerobic vs anaerobic) and the
        // interval parse are both required: aerobic sets → no model
        // → no countdown chrome (spec's "aerobic set: no countdown
        // chrome" acceptance criterion); missing/garbled interval →
        // no model → no countdown (the spec's "interval_text parses
        // to seconds" gate). The new badge line lives on the view's
        // lastStrikeEvaluation + the model's extendedRestSec.
        if isAnaerobicSet, let base = intervalToSeconds(interval) {
            let model = RestCountdownModel(baseRestSec: base, setIsAnaerobic: true)
            restModel = model
            restAccumulatorMs = 0
            // V0.40 Slice 4 (2026-08-18): fetch the swimmer's
            // usable 3MT profile (if any) and populate the model's
            // per-swimmer zone gate. Best-effort + non-fatal — a
            // fetch failure (network, RLS, decode, no usable
            // profile) leaves the gate empty and V0.39's intensity
            // gate is the fallback. The fetch kicks off AFTER the
            // model is built so the rest of the timing flow (lap,
            // evaluate, tick) is not blocked on the network — if
            // the first lap evaluates before the fetch returns,
            // the V0.39 path runs (gate empty); subsequent laps
            // pick up the gate once it's populated.
            Task { [weak self, model] in
                await self?.applySwimmerZoneGate(to: model)
            }
        } else {
            // Aerobic / no interval — the spec's "aerobic set: no
            // countdown chrome" path. Don't leave a stale model from
            // a previous session in place; the badge line is gated
            // on `lastStrikeEvaluation != nil` and that's already
            // cleared by reset() / confirmSetup.
            restModel = nil
            restAccumulatorMs = 0
        }
        lastStrikeEvaluation = nil

        // Keep screen awake while timing
        UIApplication.shared.isIdleTimerDisabled = true

        // Volume-up is already captured and wired via confirmSetup → handleVolumeUp.
        // In .running state, handleVolumeUp calls lap().

        // 10ms display cadence — on main run loop
        timerCancellable = Timer.publish(every: 0.01, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.tick()
            }
    }

    /// Record a lap — called by on-screen LAP button or volume-up.
    func lap() {
        guard state == .running else { return }
        haptic.impactOccurred()

        let now = Date().millisecondsSince1970
        let lapElapsed = Int(now - repStartMs)
        let split = lapElapsed - (laps.last?.elapsedMs ?? 0)

        let newLap = Lap(
            id: UUID().uuidString,
            lapNumber: laps.count + 1,
            elapsedMs: lapElapsed,
            splitMs: split
        )
        laps.append(newLap)

        // V0.54 (2026-09-08): in `.console` mode, mirror the rep
        // count into `repsByRepIndex` for the compressed one-liner
        // summary at the top of the LIVE screen, and advance
        // `currentRepIndex` so the Console's LIVE body knows which
        // rep card is now expanded. Additive — non-`.console` paths
        // leave the new fields at their default nil/[:].
        if mode == .console {
            let justCompletedRep = laps.count - 1  // 0-based
            repsByRepIndex[justCompletedRep] = lapElapsed
            currentRepIndex = justCompletedRep
        }

        // Trigger visual flash in the UI
        lapFlashTrigger = UUID()

        // V0.46 Slice 3: set-progress milestone haptics, fired only
        // when the lap stream maps 1:1 to a known rep count (single-
        // swimmer prefill path — multi-swimmer attribution resolves
        // at save-time pairing, so a "final rep" would be a guess).
        // Weber-Fechner: the final rep's beat must be perceptibly
        // stronger than halfway. Halfway = success notification;
        // final = success + heavy impact stacked (a compound beat,
        // not just a louder single one). These layer on top of the
        // medium impact above — the coach still gets the same LAP
        // confirmation they've trained on; milestones add colour.
        if let reps = reps, reps > 1, selectedSwimmerId != nil {
            let completed = laps.count
            if completed == reps {
                Haptics.success()
                Haptics.heavy()
            } else if completed == (reps + 1) / 2 {
                Haptics.success()
            }
        }

        // Re-arm haptic for next press
        haptic.prepare()

        // V0.39 Slice 3 (2026-08-18): drop-rule evaluation on each
        // lap completion. Single-swimmer flow only — multi-swimmer
        // sessions (sessionId set, selectedSwimmerId nil) have a
        // shared lap stream and per-swimmer attribution only
        // resolves at save-time pairing, so the live badge is
        // out-of-scope for v1 (spec §Slice 3 doc: "per-swimmer
        // flags ... is v1+; the single-swimmer badge satisfies
        // the acceptance criteria"). The guard is
        // `selectedSwimmerId != nil` — that's the unambiguous
        // signal that "this lap is THIS swimmer's rep".
        //
        // The rep's time is `newLap.splitMs` (the split for THIS
        // rep, not the cumulative elapsed) and the standard is
        // rep-1 (the first lap's splitMs in this set). The
        // predicted-standard refinement is reserved for Slice 4's
        // save-time path; the live badge uses Eva's literal
        // rep-1 rule (the spec calls this out as an
        // approved-scope v1 simplification). On rep 1 the standard
        // IS the rep time (no prior reference), so the delta is
        // zero — `struck == false` and the badge stays clear.
        if let swimmerId = selectedSwimmerId, let model = restModel {
            // Rep 1's standard = rep 1's split (no prior reference).
            // Subsequent reps' standard = rep 1's split.
            let firstLap = laps.first
            let rep1TimeMs = firstLap?.splitMs ?? newLap.splitMs
            if let evaluation = model.evaluate(
                swimmerId: swimmerId,
                repIndex: newLap.lapNumber,
                repTimeMs: newLap.splitMs,
                distanceMeters: self.distance,
                predictedStandardMs: nil,
                predictionMaturity: nil,
                rep1TimeMs: rep1TimeMs,
                // V0.41 Slice 2 (2026-08-18): when the swimmer has a
                // resolved zone pace for this zone set, use it as the
                // drop-rule standard (authoritative — the zone pace is
                // the target). nil for unprofiled swimmers → rep-1
                // fallback (never a phantom strike).
                zoneStandardMs: zoneStandardMsBySwimmer[swimmerId]
            ) {
                if evaluation.struck {
                    // Surface the strike in the inline badge.
                    // The view binds to this; the spec's
                    // "non-intrusive confirmation surface — NEVER
                    // modal" lives below the countdown, above the
                    // lap list.
                    lastStrikeEvaluation = evaluation
                    // Reset the countdown to the EXTENDED rest
                    // immediately (the coach sees the +30/+60 land
                    // at the moment the strike does, not after the
                    // next tick). The spec: "On LAP, reset the
                    // countdown to baseRestSec (or the extended
                    // rest if a strike just landed)".
                    model.remainingSec = model.extendedRestSec
                    restAccumulatorMs = 0
                } else {
                    // Within threshold — clear any pending badge
                    // (a subsequent good rep "earns back" the
                    // base rest, per Eva: "he's allowed two
                    // strikes again") and reset the countdown to
                    // base.
                    lastStrikeEvaluation = nil
                    model.remainingSec = model.baseRestSec
                    restAccumulatorMs = 0
                }
            }
        }

        // V0.38 Slice 4 (2026-08-16): 3MT sessions have no lap cap —
        // swimmers hit the wall when they hit it. The expectedLapCount
        // gate is a multi-swimmer "every swimmer has touched" heuristic
        // from training sets, and incorrectly fires mid-test for the
        // 3MT (where 30+ splits is normal). The 3:00 auto-stop in
        // `tick()` is the only auto-stop for 3MT.
        if !is3MTSession,
           let limit = expectedLapCount, laps.count >= limit {
            stop()
        }
    }

    /// V0.39 Slice 3 (2026-08-18): one-tap revert for the most
    /// recent strike. Restores the common rest to base (clears the
    /// per-swimmer extension + strike count), clears the badge,
    /// and arms the Slice 4 save path with a `RevertResult` to
    /// persist as `set_rest_events.reverted = true`. The spec:
    /// "every extension is visible in the badge and revertible"
    /// — the engine never silently extends.
    func revertRestExtension() {
        guard let swimmerId = selectedSwimmerId, let model = restModel else { return }
        let result = model.revert(swimmerId: swimmerId)
        lastStrikeEvaluation = nil
        // After revert the common clock is base rest (recompute via
        // the model's extendedRestSec, which the revert call updated).
        model.remainingSec = result.newExtendedRestSec
        restAccumulatorMs = 0
    }

    /// Stop the stopwatch and move to .finished — called by on-screen STOP button
    /// or by the auto-stop when laps reach the expected count.
    ///
    /// Phase 2.5-c: for multi-swimmer sessions, transition to .saving (not
    /// .finished) and auto-trigger save() so the coach lands on
    /// SessionReviewView directly — no intermediate complete page. The
    /// .finished view is bypassed in the success path. If the save fails,
    /// the VM falls back to .finished so the coach sees the error and
    /// can retry. Single-swimmer flow (no sessionId) keeps the .finished
    /// view so the coach can review the time before saving.
    ///
    /// Phase 2.6 v1.1: added a 20s watchdog. If the supabase call hangs
    /// (network drop, RLS loop, big payload, server unresponsive), the
    /// state would otherwise stay .saving forever and the user would see
    /// a spinner with no way out. The watchdog polls hasSavedPairedLaps
    /// once a second for 20s; if it's still false, force the transition
    /// to .finished with a clear "Save timed out" error. The user can
    /// then tap SAVE in .finished to retry.
    ///
    /// Phase 2.6 v1.4 (reverted in 4ba83b0): I tried making the
    /// engine opt-in. The user immediately corrected: "no the
    /// pairing is essential." Reverted to the v1.3 default —
    /// the engine runs by default. SKIP PAIRING is still in the
    /// view as an escape hatch if the engine hangs, but it is
    /// NOT the default. The pairing engine is the product.
    func stop() {
        guard state == .running else { return }
        // t_bec2b88b (2026-08-06): capture the wall-clock stop time
        // BEFORE clearing the timer. Used by `assembleCapturePayload()`
        // to populate `capture.stoppedAt` + `payload.occurredAt`.
        sessionStopDate = Date()
        timerCancellable?.cancel()
        timerCancellable = nil
        UIApplication.shared.isIdleTimerDisabled = false
        volumeService.stop()

        if let sid = sessionId {
            // Multi-swimmer: skip the complete page, go straight to
            // the review page. The pairing engine runs by default —
            // it's the core of the product. SKIP PAIRING is an
            // escape hatch in the .saving view if the engine hangs.
            state = .saving
            currentSaveStep = .fetching
            let saveTask = Task { @MainActor in
                await save(sessionId: sid)
            }
            Task { @MainActor in
                // Watchdog: poll for completion or force-fail after 10s.
                // If save() throws, the catch inside save() transitions
                // state immediately — this watchdog only fires for
                // true hangs.
                let timeoutSeconds = 10
                for _ in 0..<timeoutSeconds {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if hasSavedPairedLaps { return }
                }
                if !hasSavedPairedLaps {
                    saveTask.cancel()
                    if errorMessage == nil {
                        errorMessage = "Save timed out after \(timeoutSeconds)s. Tap RETRY to run the pairing engine again, or SKIP PAIRING to just record the raw times and manually pair them in the review."
                    }
                    currentSaveStep = .idle
                    state = .finished
                }
            }
        } else {
            // Single-swimmer: keep the .finished view for review-before-save
            state = .finished
        }
    }

    /// User-initiated cancel from the .saving view. Aborts the in-flight
    /// save and falls back to .finished so the user can retry.
    func cancelSave() {
        errorMessage = "Save cancelled. Tap SAVE to retry."
        currentSaveStep = .idle
        state = .finished
    }

    /// Phase 2.6 v1.2: permanent escape hatch from the .saving view.
    /// The pairing engine is a NICE-TO-HAVE, not a blocker. If the
    /// engine is hanging, the coach can skip it and just record the
    /// raw lap times to Supabase — the SessionReviewView will show
    /// them with no paired swimmer, and the coach can manually
    /// assign each lap via the reassign sheet.
    ///
    /// This addresses the user's persistent complaint: "the cancel
    /// button is a workaround, not a fix." The actual fix is to
    /// let the user bypass the engine entirely when it hangs.
    func skipPairing() async {
        guard let sid = sessionId else {
            errorMessage = "No session to save to. Tap RETRY."
            state = .finished
            return
        }
        currentSaveStep = .saving
        do {
            // Insert raw lap rows with NO paired_swimmer_id. The
            // SessionReviewView loads recorded_times and shows them;
            // the coach can tap each row to assign a swimmer.
            struct RawTimeRow: Encodable {
                let id: String
                let session_id: String?
                let swimmer_id: String?       // nil — not paired yet
                let workout_set_id: String?
                let time_ms: Int
                let rep_index: Int
                let intensity: String?
                let wave_number: Int
                let source: String
                let lap_order: Int
                let paired_swimmer_id: String?  // nil
                /// V0.46 fix (2026-08-20): owning coach's coaches.id.
                /// Required by the coach_own_recorded_times RLS policy.
                let coach_id: String?
                /// V0.43a (2026-08-18): gear stamp on the raw
                /// (unpaired) insert path so SKIP PAIRING also
                /// persists gear. Same resolution rule as
                /// `resolvedSaveGear`: fragment-first, else
                /// set-level, else nil (DB stores NULL).
                let gear: String?
                let created_at: String
            }
            // V0.43a (2026-08-18): bind the resolved gear once so
            // the same string stamps every row (consistent with the
            // `let timestamp` pattern above — batch rows share a
            // single value rather than re-resolving per lap).
            let resolvedGear = self.resolvedSaveGear
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let rows = self.laps.enumerated().map { (idx, lap) in
                RawTimeRow(
                    id: lap.id,
                    session_id: sid,
                    swimmer_id: nil,
                    workout_set_id: workoutSetId,
                    time_ms: lap.elapsedMs,
                    rep_index: idx,
                    intensity: intensityLabel,
                    wave_number: 0,
                    source: "unpaired",
                    lap_order: lap.lapNumber,
                    paired_swimmer_id: nil,
                    coach_id: coachId,
                    gear: resolvedGear,
                    created_at: timestamp
                )
            }
            // Phase 2.6 v1.3 fix: declare supabase locally (the other
            // supabase call sites in this file do `let supabase =
            // SupabaseService.shared.client` inside the do-block; the
            // skipPairing() addition missed this, so the build
            // errored at line 312 with 'Cannot find supabase in
            // scope').
            //
            // Phase 2.6 v1.5: wrap the insert in withTimeout(5s) for
            // the same reason as save() above — silently-hung
            // supabase call should not show a 60s+ spinner.
            //
            // Phase 2.6 v1.5.1 fix: bind the result of withTimeout
            // explicitly (or discard) — the Mac Studio build's
            // strict-concurrency pass warned at line 403 with
            // 'Result of call to withTimeout is unused'. The
            // supabase insert() doesn't return anything we need, so
            // a `_ =` discards it. (Alternative: change withTimeout
            // to return Void when the caller doesn't need the
            // result — but the generic version is cleaner.)
            let supabase = SupabaseService.shared.client
            log("skipPairing() starting (raw insert, \(self.laps.count) laps)")
            _ = try await withTimeout(
                Self.perCallTimeoutSeconds,
                label: "insert raw recorded_times"
            ) {
                try await supabase.from("recorded_times")
                    .insert(rows)
                    .execute()
            }
            log("skipPairing() insert complete, \(rows.count) rows written")
            currentSaveStep = .complete
            hasSavedPairedLaps = true
        } catch {
            log("skipPairing() FAILED: \(error.localizedDescription)")
            errorMessage = "Couldn't save times. Tap RETRY. (\(error.localizedDescription))"
            currentSaveStep = .idle
            state = .finished
        }
    }

    /// Save all laps to Supabase and return to .setup, or run pairing and navigate to review.
    /// PHASE 2.6 v1.12: `preferences` parameter added so the caller
    /// (TimingView) can pass the live `AuthManager.coachPreferences`
    /// (which the predictor reads for `predictionAlgorithm` — median
    /// vs EMA). Default = `.default` so old call sites (CLI tests,
    /// skipPairing) keep working.
    func save(sessionId: String?, preferences: CoachPreferences = .default) async {
        isSaving = true
        defer { isSaving = false }
        
        errorMessage = nil

        if let swimmerId = selectedSwimmerId {
            // Single-swimmer manual timing
            let isoFormatter = ISO8601DateFormatter()
            do {
                let session = TimingSession(
                    id: UUID().uuidString,
                    swimmerId: swimmerId,
                    stroke: stroke,
                    distance: distance,
                    reps: reps,
                    interval: interval,
                    intensityLabel: intensityLabel,
                    workoutSetId: workoutSetId,
                    gear: nil,
                    coachId: coachId,
                    laps: laps,
                    startedAt: isoFormatter.string(from: sessionStartDate ?? Date()),
                    endedAt: isoFormatter.string(from: Date())
                )
                // V0.47 (2026-08-22): stamp the fragment context on the
                // single-swimmer rows. The VM holds the coach's tapped
                // fragment (TimingView.onAppear populates fragmentContexts
                // from the prefill); forwarding it here gives the row its
                // fragment_id so the workout page can attribute the time.
                try await timingService.saveSession(session, fragment: fragmentContexts.first)
                // V0.39 Slice 4 (2026-08-18): persist the drop-rule
                // event trail. Non-fatal — the recorded times are
                // the source of truth; a rest-events write failure
                // must not fail the save (the coach still sees
                // their times). The `reverted` flag preserves
                // coach-is-authority: a reverted extension is
                // recorded (the flywheel learns the coach
                // disagreed) but the rest was not extended.
                //
                // Aerobic sets never reach here: `restModel` is
                // nil for aerobic (built in `start()` only when
                // `isAnaerobicSet && intervalToSeconds(interval)`
                // is non-nil), so `restEvents` is empty by
                // construction. The early return below is the
                // spec's "no rows for aerobic sets" acceptance.
                if let model = restModel, !model.restEvents.isEmpty {
                    do {
                        try await timingService.saveRestEvents(
                            model.restEvents,
                            sessionId: nil,
                            workoutSetId: workoutSetId
                        )
                    } catch {
                        log("set_rest_events insert FAILED (non-fatal): \(error.localizedDescription)")
                    }
                }
                reset()
            } catch {
                errorMessage = "Couldn't save times. Try again."
            }
        } else if let sid = sessionId {
            // Multi-swimmer group session: Phase 2.6 PairingEngine.
            // Per-wave constrained Hungarian with velocity-space cost.
            // Predictions (per swimmer) come from the HistoricalTimePredictor
            // data already on disk in the session — but in v1 we rebuild them
            // from the per-wave `predictedTouchMs` field on each WaveAssignment
            // (a coarse per-swimmer estimate good enough for pairing; the
            // full 3-layer predictor is reserved for the wave allocator).
            //
            // Phase 2.6 v1.2: each checkpoint updates currentSaveStep so
            // the .saving view shows the user which step is in progress
            // (or hanging).
            //
            // Phase 2.6 v1.5: each supabase call is wrapped in
            // `withTimeout(5s)`. A silently-hung supabase call
            // (DNS slow, server unresponsive, RLS loop) used to
            // show a generic spinner for 60s+ (the SDK's default
            // URLSession timeout) before any error appeared. Now
            // the per-call timeout fires at 5s with a clear
            // "fetching wave assignments timed out after 5s"
            // message, so the user knows exactly which step
            // hung and can SKIP PAIRING.
            do {
                log("save() starting (multi-swimmer, session=\(sid.prefix(8))…)")
                currentSaveStep = .fetching
                let supabase = SupabaseService.shared.client

                // Per-call timeout: fetch wave_assignments
                let waveResponse = try await withTimeout(
                    Self.perCallTimeoutSeconds,
                    label: "fetch wave_assignments"
                ) {
                    try await supabase.from("wave_assignments")
                        .select()
                        .eq("session_id", value: sid)
                        .execute()
                }
                log("decoded \(waveResponse.data.count) bytes of wave_assignments response")

                currentSaveStep = .pairing
                let allWaveAssignments = try JSONDecoder().decode([WaveAssignment].self, from: waveResponse.data)
                log("decoded \(allWaveAssignments.count) wave_assignments from supabase")

                // Phase 2.6 v1.6 fix: filter to the CURRENT set only.
                // The pairing engine groups wave_assignments by
                // wave_number, NOT by workout_set_id. If the workout
                // has multiple sets (e.g., 50 Free + 200 IM), the
                // wave_assignments span all of them. The laps the
                // coach just recorded are for ONE specific set. If
                // we don't filter, the engine tries to pair set-1
                // laps against set-2 swimmers (and vice versa). The
                // coarsePredictions map is per-swimmer, not
                // per-(set, swimmer), so set-2 swimmers get
                // set-1's PB as their prediction. The cost is huge
                // and the Hungarian matches all of them to dummy-lap
                // columns → 0 real assignments.
                //
                // This was caught by the live diagnostic log
                // (`pairing engine: 0 assignments, 0 ghost taps, 8
                // unassigned`) which is the signal-detector-style
                // observable that made the bug diagnosable in 1 line
                // instead of a 1-hour Mac Studio session.
                guard let currentSetId = self.workoutSetId else {
                    log("save() FAILED: workoutSetId is nil (TimingView didn't get it from the prefill)")
                    errorMessage = "Session is missing its workout set. Tap RETRY."
                    state = .finished
                    return
                }
                let waveAssignments = allWaveAssignments.filter { wa in
                    wa.workoutSetId == currentSetId
                }
                // Phase 2.6 v1.12.1: publish the filtered count for
                // the COPY DEBUG INFO button (so the coach can see
                // how many swimmers the engine paired against
                // after the workoutSetId filter).
                lastWaveAssignmentCount = waveAssignments.count
                log("filtered to \(waveAssignments.count) wave_assignments for current set \(currentSetId.prefix(8))…)")
                // V0.51 (2026-08-30) §c: solo-roster soft fallback.
                // A solo swimmer's skip-the-picker session can land
                // here with zero wave_assignments (orphan back-fill
                // not yet run, or synthesizeWaveAssignmentsIfMissing
                // failed). Pairing is meaningless with 1 swimmer —
                // route to the single-swimmer paired branch (same
                // chip-renderer join shape, `paired_swimmer_id =
                // the solo swimmer`). Multi-swimmer + empty
                // wave_assignments stays a hard error: that's real
                // misconfiguration, not a skip-path side-effect.
                let isSoloRosterFallback = waveAssignments.isEmpty
                    && (self.currentRosterCount == 1)
                    && (self.currentSoloSwimmerId != nil)
                if isSoloRosterFallback, let soloSwimmerId = self.currentSoloSwimmerId {
                    log("save() solo-roster fallback: routing 1-swimmer session to paired path (session=\(sid.prefix(8))…)")
                    do {
                        try await self.timingService.saveSoloPairedLaps(
                            sessionId: sid,
                            swimmerId: soloSwimmerId,
                            stroke: self.stroke,
                            distance: self.distance,
                            intensity: self.intensityLabel ?? "race",
                            gear: self.gear?.joined(separator: ","),
                            coachId: self.coachId,
                            laps: self.laps,
                            fragment: self.fragmentContexts.first,
                            workoutSetId: currentSetId
                        )
                        await MainActor.run {
                            self.hasSavedPairedLaps = true
                        }
                        return  // success — bypass the multi-swimmer guard
                    } catch {
                        log("save() solo-roster fallback FAILED: \(error.localizedDescription) — surfacing as misconfigured")
                        errorMessage = "Couldn't save solo session: \(error.localizedDescription)"
                        state = .finished
                        return
                    }
                }
                guard !waveAssignments.isEmpty else {
                    log("save() FAILED: no wave_assignments for current set — session may be misconfigured")
                    errorMessage = "No wave assignments for this set. Did the session start correctly? Tap RETRY."
                    state = .finished
                    return
                }

                // PHASE 2.6 v1.12 — wire HistoricalTimePredictor into
                // save(). Per the user's 2026-06-15 direction:
                // "the hungarian algorithm should get trained and
                // should reference the swimming history for the
                // selected component the swimmers are carrying out.
                // so the hungarian shouldn't just look at a pb for
                // the 50 free @ max intensity to should look at
                // what the EWMA. so the more history and times
                // tracked in hydrolyze hopefully the more accurate
                // and precise the pairing — at least this is the
                // goal." The flywheel: more recorded_times →
                // tighter σ → better pairings → fewer manual
                // reassigns → coach uses the app more → more data.
                //
                // We fetch the four inputs the predictor needs:
                //   (1) WorkoutSet for currentSetId
                //   (2) Swimmer rows for the unique swimmer IDs
                //   (3) RecordedTime rows for (currentSetId, those
                //       swimmer IDs) — Layer 1 input
                //   (4) SwimmerPB rows for those swimmer IDs — Layer 2
                //
                // Parallel `async let` keeps the wall-clock latency
                // bounded by the slowest single query (~150-300ms each,
                // ~1s total in parallel vs ~3-4s serialized).
                currentSaveStep = .predicting
                log("v1.12: fetching predictor inputs (workout_set, swimmers, recorded_times, swimmer_pbs)")

                let uniqueSwimmerIds = Array(Set(waveAssignments.map { $0.swimmerId }))

                // PHASE 2.6 v1.12.1 fix: do NOT add an explicit
                // `PostgrestResponse<[T]>` type annotation on the
                // `async let` declarations. The supabase SDK's
                // `.execute()` already infers the response type from
                // the schema, and forcing a type annotation breaks
                // the throw propagation (Swift then complains "No
                // calls to throwing functions occur within 'try'
                // expression" on the tuple await + the JSONDecoder
                // calls). The pattern below matches the working one
                // in SessionReviewViewModel.swift line 110+.
                async let workoutSetResponseTask = supabase
                    .from("workout_sets")
                    .select()
                    .eq("id", value: currentSetId)
                    .execute()

                async let swimmersResponseTask = supabase
                    .from("swimmers")
                    .select()
                    .in("id", values: uniqueSwimmerIds)
                    .execute()

                async let recordedTimesResponseTask = supabase
                    .from("recorded_times")
                    .select()
                    .eq("workout_set_id", value: currentSetId)
                    .in("swimmer_id", values: uniqueSwimmerIds)
                    .execute()

                async let pbsResponseTask = supabase
                    .from("swimmer_pbs")
                    .select()
                    .in("swimmer_id", values: uniqueSwimmerIds)
                    .execute()

                // PHASE 1 (T3.5, 2026-06-20): the 5th parallel fetch.
                // Calibration factors (suit + start) for these
                // swimmers. Empty calibration (no `swimmer_suits` /
                // `swimmer_starts` rows yet) is fine — the predictor
                // falls back to a multiplier of 1.0 (no adjustment)
                // when the helper returns nil.
                let calibration = CalibrationFactors()
                async let calibrationFetchTask = calibration.prefetch(
                    forSwimmerIds: uniqueSwimmerIds
                )

                // The `try` on the tuple await is needed because
                // each `async let` propagates its throw to the await
                // point. Without it, the JSONDecoder().decode()
                // calls below would see no throws (they're already
                // throws — the issue is the await is what binds
                // the throw context).
                let workoutSetResp = try await workoutSetResponseTask
                let swimmersResp = try await swimmersResponseTask
                let recordedTimesResp = try await recordedTimesResponseTask
                let pbsResp = try await pbsResponseTask
                _ = try await calibrationFetchTask
                self.calibration = calibration

                guard let workoutSet = try JSONDecoder().decode([WorkoutSet].self, from: workoutSetResp.data).first else {
                    log("save() FAILED: workout_set not found for current set id")
                    errorMessage = "Workout set not found. Tap RETRY."
                    state = .finished
                    return
                }
                let swimmers = try JSONDecoder().decode([Swimmer].self, from: swimmersResp.data)
                let recordedTimes = try JSONDecoder().decode([RecordedTime].self, from: recordedTimesResp.data)
                let pbs = try JSONDecoder().decode([SwimmerPB].self, from: pbsResp.data)
                log("v1.12: predictor inputs fetched — workoutSet=\(workoutSet.id.prefix(8))…, swimmers=\(swimmers.count), recordedTimes=\(recordedTimes.count), pbs=\(pbs.count)")

                // Build a swimmer map for O(1) lookup
                let swimmersById: [String: Swimmer] = Dictionary(uniqueKeysWithValues: swimmers.map { ($0.id, $0) })

                // PHASE 2.6 v1.13.0: use PBService as the SINGLE function
                // for live predictions. Replaces the per-(swimmer, set)
                // call to HistoricalTimePredictor. The predictor's
                // behavior is preserved (Layer 1 recorded stats, Layer
                // 2 PB curve with tiered fallbacks, Layer 3 population
                // seed), but the data flow is now unified: the wave
                // preview, the save flow, and the profile screen all
                // call the same function. The coach can trust that
                // what they see in the profile is what the engine uses.
                let pbService = PBService()
                // t_c74dffbc (2026-08-04): when fragmentContexts is
                // non-empty (composite set like `4 x (75 fast / 25
                // easy)`), key the prediction per (swimmer, fragment)
                // — not the parent set. The save flow builds a synthetic
                // WorkoutSet per fragment with the fragment's distance,
                // intensity, start, suit, gear so PBService reads the
                // matching (swimmer, fragment) recorded stats / PB curve.
                // For non-composite sets, fragmentContexts is empty and
                // the existing parent-set prediction path runs unchanged.
                let intensity = self.intensityLabel ?? "moderate"
                // V0.43a (2026-08-18): pull the resolved gear
                // (fragment-first, else set-level, else nil) so the
                // prediction key + the persisted `recorded_times.gear`
                // row are both stamped with the parsed gear. Prior
                // versions hardcoded "none" here; that's why the 432
                // live rows show 'none' despite V0.37 parsing gear
                // correctly upstream.
                let gear = self.resolvedSaveGear
                // PHASE 1 (T3.5, 2026-06-20): use the calibration
                // populated by the parallel fetch above. It's in scope
                // as a local and was awaited, so the cache is ready.
                // The `self.calibration` field mirrors this for any
                // future caller that needs the same instance.
                var livePredictions: [String: Prediction] = [:]
                var predictorLogs: [String] = []
                let useFragmentKeys = !self.fragmentContexts.isEmpty
                log("t_c74dffbc: fragment-keyed prediction path=\(useFragmentKeys) (fragmentContexts=\(self.fragmentContexts.count))")
                for wa in waveAssignments {
                    guard let swimmer = swimmersById[wa.swimmerId] else {
                        predictorLogs.append("⚠ \(wa.swimmerId.prefix(8))…: swimmer not in DB, will fall back to coarse")
                        continue
                    }
                    if useFragmentKeys {
                        // Per-fragment prediction: build a synthetic
                        // WorkoutSet for each fragment context the
                        // coach timed. The pairing engine's cost
                        // matrix will see the (swimmer, fragment)
                        // prediction; the follow-up PairingEngine
                        // change keys the cost by fragmentId.
                        for fragment in self.fragmentContexts {
                            let syntheticSet = syntheticWorkoutSet(
                                from: workoutSet,
                                fragment: fragment
                            )
                            if let pred = pbService.fetchPrediction(
                                swimmer: swimmer,
                                set: syntheticSet,
                                prefs: preferences,
                                recordedTimes: recordedTimes,
                                pbs: pbs,
                                calibration: calibration
                            ) {
                                // Key by swimmerId + fragmentKey so the
                                // pairing engine can route per-row.
                                livePredictions[predictionKey(
                                    swimmerId: wa.swimmerId,
                                    fragment: fragment
                                )] = pred
                                let algStr = preferences.predictionAlgorithm == .ema ? "EMA" : "median"
                                predictorLogs.append("✓ \(wa.swimmerId.prefix(8))…/\(fragment.pairingKey): predicted=\(pred.timeMs)ms (σ=\(pred.sigmaMs), source=\(pred.source), maturity=\(pred.maturity), alg=\(algStr), samples=\(pred.sampleSize))")
                            }
                        }
                    } else {
                        if let pred = pbService.fetchPrediction(
                            swimmer: swimmer,
                            set: workoutSet,
                            intensity: intensity,
                            gear: gear,
                            prefs: preferences,
                            recordedTimes: recordedTimes,
                            pbs: pbs,
                            calibration: calibration
                        ) {
                            livePredictions[wa.swimmerId] = pred
                            let algStr = preferences.predictionAlgorithm == .ema ? "EMA" : "median"
                            predictorLogs.append("✓ \(wa.swimmerId.prefix(8))…: predicted=\(pred.timeMs)ms (σ=\(pred.sigmaMs), source=\(pred.source), maturity=\(pred.maturity), alg=\(algStr), samples=\(pred.sampleSize))")
                        } else {
                            predictorLogs.append("⚠ \(wa.swimmerId.prefix(8))…: PBService returned nil (IM or no data), will fall back to coarse")
                        }
                    }
                }
                for line in predictorLogs { log("v1.13 PBService: " + line) }
                log("v1.13: built livePredictions map for \(livePredictions.count) entries (PBService) — fragment-keyed=\(useFragmentKeys)")

                // Build a coarse per-swimmer Prediction map from the
                // WaveAllocator's per-(swimmer, set) predictedTouchMs.
                //
                // CRITICAL: PairingEngine.pair() does
                //   actualTime = lap.elapsedMs - sendOffN
                // to get the wave-relative time before computing the
                // cost. So the prediction it expects is the WAVE-RELATIVE
                // swim time, NOT the absolute touch time. The
                // WaveAssignment.predictedTouchMs field stores
                // `sendOff + PB` (absolute), so we must subtract the
                // wave's sendOffOffsetMs to get back to the wave-relative
                // time. Without this, the Z-score is off by the full
                // sendOff amount (10s+ for wave 1+), confidence goes to
                // ~0, every wave-1+ row is "Needs Review", and the coach
                // is stuck on the SessionReviewView because Confirm All
                // is disabled. (Bug caught in v1: 2026-06-14 Mac Studio
                // test, user reported being stuck.)
                var coarsePredictions: [String: Prediction] = [:]
                for wa in waveAssignments {
                    if coarsePredictions[wa.swimmerId] == nil && wa.predictedTouchMs > 0 {
                        let waveRelativeTimeMs = max(0, wa.predictedTouchMs - wa.sendOffOffsetMs)
                        coarsePredictions[wa.swimmerId] = Prediction(
                            timeMs: waveRelativeTimeMs,
                            sigmaMs: 2000,   // default v1 sigma for the pairing cost
                            sampleSize: 0,
                            source: .curve,  // not "real" recorded data — it's PB-based
                            maturity: .none,
                            // PHASE 1 (T8.5, 2026-06-20): the coarse
                            // fallback has no calibration data available
                            // (the waveAssignments are a quick preview,
                            // not the calibrated prediction path). nil
                            // for both deltas — the SessionReview row
                            // will hide the calibrationHint in that case.
                            suitDeltaMs: nil,
                            startDeltaMs: nil
                        )
                    }
                }
                log("built coarsePredictions map for \(coarsePredictions.count) swimmers (fallback)")

                // PHASE 2.6 v1.12: live predictions win over coarse.
                // The merge picks `live` for any key present in both.
                // This means: if the predictor returns a real
                // prediction (with EWMA + reduced σ), the pairing
                // engine uses that. If the predictor returns nil
                // (IM, cold start, etc.), we fall back to the
                // static coarse from the wave preview.
                let predictions = livePredictions.merging(coarsePredictions) { live, _ in live }
                log("v1.12: merged predictions map for \(predictions.count) swimmers (live: \(livePredictions.count), coarse: \(coarsePredictions.count))")

                let pairingEngine = PairingEngine()
                let poolConfig = WaveAllocator.PoolConfig()  // default for v1
                let result = pairingEngine.pair(
                    laps: self.laps,
                    waveAssignments: waveAssignments,
                    predictions: predictions,  // v1.12: live EWMA + coarse fallback
                    sendOffIntervalMs: poolConfig.sendOffIntervalMs
                )
                log("pairing engine: \(result.assignments.count) assignments, \(result.unassignedLaps.count) ghost taps, \(result.unassignedSwimmers.count) unassigned")

                currentSaveStep = .saving
                // Per-call timeout: save the paired laps.
                // Phase 2.6 v1.5.1 fix: explicit `self.timingService`
                // — Swift 6 strict-concurrency requires explicit
                // self capture in @Sendable closures passed to
                // withThrowingTaskGroup. Mac Studio warned at line
                // 543 with 'Reference to property timingService in
                // closure requires explicit use of self'. The same
                // pattern applies to `self.stroke`, `self.distance`,
                // `self.intensityLabel` which are already prefixed.
                //
                // V0.38 Slice 4 (2026-08-16): the 3MT path overrides
                // intensity to 'race' + distance to 25 — the spec
                // says the recorded_times row carries pace_distance=25
                // and intensity='race' regardless of the parser's
                // human label ("3-minute all-out"). `self.distance` is
                // already 25 for 3MT sets (the parser sets it), but
                // we set it explicitly here so the contract survives
                // any future change to the prefill shape.
                let recordedTimesIntensity = self.is3MTSession
                    ? "race"
                    : (self.intensityLabel ?? "race")
                let recordedTimesDistance = self.is3MTSession ? 25 : self.distance
                try await withTimeout(
                    Self.perCallTimeoutSeconds,
                    label: "savePairedLaps"
                ) {
                    try await self.timingService.savePairedLaps(
                        sessionId: sid,
                        stroke: self.stroke,
                        distance: recordedTimesDistance,
                        intensity: recordedTimesIntensity,
                        // V0.43a (2026-08-18): stamp every
                        // recorded_time row with the resolved gear
                        // (fragment-first, else set-level, else nil).
                        // nil → the JSON omits the key → the DB stores
                        // NULL for bare sets.
                        gear: self.resolvedSaveGear,
                        coachId: self.coachId,
                        assignments: result.assignments,
                        // V0.47 (2026-08-22): forward the tapped
                        // fragment context so rows carry fragment_id
                        // and the workout page can attribute them.
                        fragment: self.fragmentContexts.first
                    )
                }

                // V0.38 Slice 4 (2026-08-16): on a 3MT save, the
                // timing session data (recorded_times, written above)
                // is the source of truth. The `swimmer_test_profiles`
                // row is a derived trend line the review surface
                // (slice 5) reads to show the three numbers. A
                // profiles-insert failure MUST NOT fail the save —
                // the coach still sees their times in the review
                // surface; the trend line can be backfilled later.
                //
                // Three round trips, all wrapped in a single
                // non-fatal try/catch so the existing success path
                // is unaffected:
                //   1. SELECT max(trial_number) per swimmer for this
                //      workout set (so the analyzer's trialNumber
                //      controls the .learningTrial quality flag)
                //   2. (pure, no I/O) group splits + assemble rows
                //   3. INSERT swimmer_test_profiles
                if self.is3MTSession {
                    do {
                        currentSaveStep = .predicting  // reuse existing step; not the predictor, just the indicator
                        let maxTrialResp = try await withTimeout(
                            Self.perCallTimeoutSeconds,
                            label: "fetch max trial_number (3MT)"
                        ) {
                            try await supabase.from("swimmer_test_profiles")
                                .select("swimmer_id, trial_number")
                                .eq("workout_set_id", value: currentSetId)
                                .in("swimmer_id", values: uniqueSwimmerIds)
                                .execute()
                        }
                        // V0.38 Slice 4 (2026-08-16): single SELECT
                        // returning all existing trial rows for this
                        // workout set; the Swift reduce builds the
                        // max-per-swimmer map. The dataset is small
                        // (per-swimmer × few trials), so the reduce
                        // is negligible. Decoding failure here is
                        // treated as "no prior trials" — the
                        // analyzer's trialNumber starts at 1, which
                        // matches the migration's DEFAULT 1.
                        struct TrialRow: Decodable {
                            let swimmerId: String
                            let trialNumber: Int
                            enum CodingKeys: String, CodingKey {
                                case swimmerId = "swimmer_id"
                                case trialNumber = "trial_number"
                            }
                        }
                        let trialRows = (try? JSONDecoder().decode([TrialRow].self, from: maxTrialResp.data)) ?? []
                        var maxBySwimmer: [String: Int] = [:]
                        for r in trialRows {
                            maxBySwimmer[r.swimmerId] = max(
                                maxBySwimmer[r.swimmerId] ?? 0,
                                r.trialNumber
                            )
                        }
                        log("3MT profiles: existing max trial_number for \(maxBySwimmer.count) swimmers")

                        // Pure assembly (no I/O). Same code path the
                        // CLI test exercises.
                        let swimmerSplits = groupSplitsPerSwimmer(
                            assignments: result.assignments
                        )
                        let profileRows = assembleTestProfiles(
                            swimmerAssignments: swimmerSplits,
                            workoutSetId: currentSetId,
                            sessionId: sid,
                            stroke: self.stroke,
                            poolLengthMeters: 25,
                            existingMaxTrialBySwimmer: maxBySwimmer
                        )
                        log("3MT profiles: built \(profileRows.count) profile rows from \(swimmerSplits.count) swimmers")

                        if !profileRows.isEmpty {
                            _ = try await withTimeout(
                                Self.perCallTimeoutSeconds,
                                label: "insert swimmer_test_profiles"
                            ) {
                                try await supabase.from("swimmer_test_profiles")
                                    .insert(profileRows)
                                    .execute()
                            }
                            log("3MT profiles: insert complete (\(profileRows.count) rows)")
                        }
                    } catch {
                        // Spec: profiles-insert failure must NOT fail
                        // the save. Log + continue. The recorded_times
                        // write above already succeeded, so the user
                        // lands on SessionReviewView with their times;
                        // the profile trend line will be missing until
                        // backfill (a future slice).
                        log("3MT profiles: insert FAILED (non-fatal): \(error.localizedDescription)")
                    }
                }

                currentSaveStep = .complete
                log("save() complete")
                self.hasSavedPairedLaps = true
            } catch {
                log("save() FAILED: \(error.localizedDescription)")
                errorMessage = "DB Error: \(error.localizedDescription)"
                currentSaveStep = .idle
                // Phase 2.6 v1.2: immediate state transition on error
                // so the user doesn't have to wait 20s for the watchdog.
                // The error is shown in the .finished view's red text
                // and the user can tap SAVE in the .finished view to
                // retry, or tap SKIP PAIRING to bypass the engine.
                state = .finished
            }
        }
    }

    /// Discard the session and return to .setup without saving.
    func discard() {
        reset()
    }

    /// Return to .setup state.
    private func reset() {
        timerCancellable?.cancel()
        timerCancellable = nil
        UIApplication.shared.isIdleTimerDisabled = false
        volumeService.stop()
        elapsedMs = 0
        laps = []
        lapFlashTrigger = nil
        sessionStartDate = nil
        selectedSwimmerId = nil
        expectedLapCount = nil
        // V0.39 Slice 3 (2026-08-18): clear the drop-rule model +
        // pending strike + accumulator so a fresh session starts
        // with the badge blank and the accumulator at 0. The
        // model is rebuilt in `start()` when the next anaerobic
        // set with an interval is timed.
        restModel = nil
        restAccumulatorMs = 0
        lastStrikeEvaluation = nil
        // V0.41 Slice 2 (2026-08-18): clear the per-swimmer zone
        // standard map + the resolved zone target so a fresh session
        // doesn't leak a stale zone pace from a previous set. zoneTerm
        // itself is re-copied from the next prefill in TimingView.
        zoneStandardMsBySwimmer = [:]
        state = .setup
    }
    /// Fetches session metadata to enable auto-stop logic
    /// BUGFIX (Phase 2.5-c): previously counted ALL wave_assignments for the session
    /// (N_swimmers × N_sets), so a 4-swimmer × 2-set session gave expectedLapCount = 8
    /// and the auto-stop never fired on the first set. Now counts distinct swimmer_ids
    /// — the per-set expected lap count, regardless of how many sets are in the session.
    /// V0.51 (2026-08-30): `rosterCount` is the size of the
    /// `latestRosterSnapshot.entries` that drove the skip-the-picker
    /// launch. Used to compute the auto-stop fallback when the
    /// skip path leaves `wave_assignments` empty (the V0.49 S1
    /// regression — see V0.51_SPEC §b).
    func loadSessionContext(sessionId: String, rosterCount: Int? = nil) async {
        do {
            let supabase = SupabaseService.shared.client
            let response = try await supabase.from("wave_assignments")
                .select("swimmer_id")
                .eq("session_id", value: sessionId)
                .execute()

            struct MinimalWaveAssignment: Decodable {
                let swimmerId: String
                enum CodingKeys: String, CodingKey {
                    case swimmerId = "swimmer_id"
                }
            }

            if let data = try? JSONDecoder().decode([MinimalWaveAssignment].self, from: response.data) {
                let uniqueSwimmerIds = Set(data.map { $0.swimmerId })
                let count = uniqueSwimmerIds.count
                if count > 0 {
                    await MainActor.run {
                        // V0.51 §b: max(wave_count, reps) so the auto-stop
                        // gate matches the real work. A 4×100 with 1 wave
                        // row still needs 4 laps per swimmer (16 total)
                        // — but `expectedLapCount` is the per-swimmer
                        // heuristic here, and `count` (unique swimmers)
                        // underestimates for solo-roster skip paths that
                        // only just wrote 1 wave row. Take max(unique,
                        // reps) when reps > 0 — the swimmer's reps is
                        // the minimum work they owe regardless of how
                        // many waves the session has.
                        let reps = self.reps ?? 0
                        let fallback = (reps > 0) ? max(count, reps) : count
                        self.expectedLapCount = fallback
                    }
                } else if let rosterCount, rosterCount == 1,
                          let reps = self.reps, reps > 0 {
                    // V0.51 §b: solo-roster + empty wave_assignments
                    // (the skip-the-picker regression). Use reps as
                    // the per-swimmer expected lap count — the swimmer
                    // owes exactly `reps` laps and there's nothing to
                    // pair. Defended: a multi-swimmer roster with empty
                    // wave_assignments keeps `nil` (the current
                    // behaviour), because that case is genuinely
                    // misconfigured (a 4-roster set with 0 wave rows
                    // needs pairing, not auto-stop at reps).
                    await MainActor.run {
                        self.expectedLapCount = reps
                    }
                }
            }
        } catch {
            print("[TimingViewModel] Context load failed: \(error)")
        }
    }

    /// V0.40 Slice 4 (2026-08-18): fetch the swimmer's
    /// `swimmer_test_profiles` rows (keyed by `swimmer_id`, NOT by
    /// session — single-swimmer timing flow), resolve the latest
    /// usable profile via `TrainingZoneService.latestUsableProfile(...)`,
    /// and derive the four zone boundaries via
    /// `TrainingZoneService.derive(...)`. If both succeed, build a
    /// `ZoneGate` and write it to the model's `zoneGateBySwimmer`
    /// dict for this swimmer.
    ///
    /// If any step fails (fetch error, no usable profile, derive
    /// returns nil) the gate stays empty and the V0.39
    /// `setIsAnaerobic` gate is the fallback — the spec calls
    /// this out as "zone resolution failure never crashes":
    /// partial rows, mid-migration data, RLS denial, network drop,
    /// and decode failures all fall through to V0.39 behavior.
    /// The wrap-in-do/catch is the "never break the timing flow
    /// on a profile-fetch failure" guarantee.
    ///
    /// Mirrors `SwimmerDetailViewModel.loadTrainingZones()`
    /// (V0.40 Slice 3) — same supabase query, same resolver, same
    /// fallback. The only difference is the key: this method is
    /// keyed by `swimmer_id` (the single-swimmer timing flow),
    /// not by `session_id` (the per-session review surface).
    /// `selectedSwimmerId` is the active swimmer for this timing
    /// session; if it's nil (e.g., the user discards before the
    /// fetch returns) the fetch is a no-op.
    ///
    /// `@MainActor` isolation matches the timing flow: `lap()` →
    /// `evaluate(...)` reads `zoneGateBySwimmer` on the main actor,
    /// so the mutation must land on the same actor. The supabase
    /// `.execute()` itself is non-blocking on its own executor;
    /// the `await` suspends and resumes on the main actor (the
    /// function's isolation), keeping the gate dict read/write
    /// race-free without an explicit lock.
    @MainActor
    private func applySwimmerZoneGate(to model: RestCountdownModel) async {
        guard let swimmerId = selectedSwimmerId else { return }
        do {
            let response = try await SupabaseService.shared.client
                .from("swimmer_test_profiles")
                .select()
                .eq("swimmer_id", value: swimmerId)
                .execute()
            let profiles = try JSONDecoder().decode(
                [SwimmerTestProfile].self,
                from: response.data
            )
            // V0.40 Slice 4 (2026-08-18): resolver picks the
            // latest usable profile (trial ≥ 2, no learning
            // flag). If non-nil, derive the four zone boundaries
            // and convert to s/100m for the model's gate. If
            // either step returns nil, the gate stays empty and
            // V0.39's intensity gate is the fallback.
            if let profile = TrainingZoneService.latestUsableProfile(profiles: profiles),
               let zones = TrainingZoneService.derive(
                   criticalSpeedMps: profile.criticalSpeedMps,
                   peakSpeedMps: profile.peakSpeedMps,
                   sourceTrialNumber: profile.trialNumber
               ) {
                // Build a passive ZoneGate — the model receives the
                // boundary paces pre-computed in s/100m and does NOT
                // know about TrainingZones, SwimmerTestProfile, or
                // the DB. The CLI test runner compiles the model
                // without these types so the model stays decoupled.
                // 100 / mps → s/100m (the boundaries in
                // TrainingZones are stored as mps; the gate works
                // in pace space).
                let gate = ZoneGate(
                    hasProfile: true,
                    easyBoundarySecPer100: 100.0 / zones.easy.mps,
                    steadyBoundarySecPer100: 100.0 / zones.steady.mps,
                    hardBoundarySecPer100: 100.0 / zones.hard.mps,
                    sprintBoundarySecPer100: 100.0 / zones.sprint.mps
                )
                model.zoneGateBySwimmer[swimmerId] = gate
                log("V0.40 zone gate populated for \(swimmerId.prefix(8))… (trial \(profile.trialNumber))")

                // V0.41 Slice 2 (2026-08-18): when the active set is a
                // zone set, resolve the swimmer's zone pace at the set's
                // zone term as the drop-rule standard. The zone pace is
                // authoritative (usable profile, trial >= 2) — it replaces
                // the rep-1/predicted standard for a profiled swimmer on
                // a zone set. Unknown/empty zone term, or a term that
                // doesn't map to a boundary → no zone standard (rep-1
                // fallback; never a phantom strike).
                if let term = zoneTerm,
                   let mps = Self.zoneBoundaryMps(for: term, zones: zones),
                   mps.isFinite, mps > 0, distance > 0 {
                    let zoneStandard = Int((Double(distance) / mps) * 1000.0)
                    zoneStandardMsBySwimmer[swimmerId] = zoneStandard
                }
            }
            // No usable profile → leave the gate empty. The model
            // treats an empty entry as V0.39 fallback (always
            // evaluate when `setIsAnaerobic`).
        } catch {
            // V0.40 Slice 4 (2026-08-18): data-absent / fetch-
            // failed = no zone gate. Log and proceed; the V0.39
            // `isAnaerobicSet` gate is the fallback. The timing
            // flow is never broken by a profile-fetch failure.
            log("V0.40 zone gate fetch failed (non-fatal, V0.39 fallback): \(error.localizedDescription)")
        }
    }

    /// V0.41 Slice 2 (2026-08-18): the boundary m/s for a zone term,
    /// from a resolved `TrainingZones`. Maps the four coach zone words
    /// to the corresponding boundary. Returns nil for an unknown/empty
    /// term (so a malformed zone term falls back cleanly to the rep-1
    /// standard — never a phantom strike).
    private static func zoneBoundaryMps(
        for term: String,
        zones: TrainingZones
    ) -> Double? {
        switch term.lowercased() {
        case "easy": return zones.easy.mps
        case "steady": return zones.steady.mps
        case "hard": return zones.hard.mps
        case "sprint": return zones.sprint.mps
        default: return nil
        }
    }

    /// V0.41 Slice 2 (2026-08-18): the coach-facing zone target line
    /// for the ready view, e.g. "Steady · 1:12/100m". Non-nil only when
    /// the active set is a zone set AND the active swimmer has a usable
    /// profile (zone pace resolved). nil when not a zone set, no usable
    /// profile, or resolution failed — the view renders nothing (the
    /// unprofiled swimmer times normally with predicted targets).
    var zoneTargetText: String? {
        guard let term = zoneTerm,
              let swimmerId = selectedSwimmerId,
              let zoneMs = zoneStandardMsBySwimmer[swimmerId],
              zoneMs > 0,
              distance > 0 else {
            return nil
        }
        // Per-100m pace string from the zone standard: the standard is
        // the whole-set ms; scale to per-100m ms and render m:ss/100m.
        let per100Ms = Double(zoneMs) * (100.0 / Double(distance))
        let totalSecs = Int(per100Ms / 1000.0)
        let mins = totalSecs / 60
        let secs = totalSecs % 60
        return "\(term.capitalized) · \(mins):\(String(format: "%02d", secs))/100m"
    }


    /// Called by the 10ms timer to update elapsedMs.
    private func tick() {
        let now = Date().millisecondsSince1970
        elapsedMs = Int(now - repStartMs)
        // V0.38 Slice 4 (2026-08-16): 3MT sessions auto-stop at 3:00.
        // The countdown text the view renders is `elapsedMs`-derived;
        // the same tick that updates elapsedMs is the natural place to
        // fire the auto-stop. `stop()` guards on `.running` so an
        // over-shoot after stop() initiated is a no-op.
        if is3MTSession, elapsedMs >= Self.threeMinuteTestDurationMs {
            stop()
        }
        // V0.39 Slice 3 (2026-08-18): drive the rest countdown at
        // 1Hz from the 10ms display cadence. The Timer.publish
        // machinery is the same one the stopwatch uses — no new
        // timer, no new Combine subscriptions, no extra main-runloop
        // load. The accumulator holds the millisecond remainder so
        // we call `model.tick()` exactly once per full second (the
        // model's tick() decrements `remainingSec` by 1 with a 0
        // floor; calling 100×/s would burn through 100s of rest in
        // a single stopwatch second).
        if let model = restModel, state == .running {
            restAccumulatorMs += 10
            if restAccumulatorMs >= 1000 {
                restAccumulatorMs -= 1000
                model.tick()
            }
        }
    }
}

// V0.38 Slice 4 (2026-08-16): the pure helpers
// (`groupSplitsPerSwimmer`, `assembleTestProfiles`, `TestProfileRow`)
// live in `Services/ThreeMinuteTestSaveSupport.swift` so the CLI
// runner can compile them without UIKit. The save flow below calls
// them — same production code the CLI test exercises.

// MARK: - Helpers

extension Date {
    var millisecondsSince1970: Int {
        Int(timeIntervalSince1970 * 1000)
    }
}