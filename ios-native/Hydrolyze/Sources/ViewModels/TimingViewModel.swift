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

    // Set from prefill — carried through to save
    var reps: Int?
    var interval: String?
    var intensityLabel: String?
    var workoutSetId: String?
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

    var formattedLaps: [(number: Int, elapsed: String, split: String)] {
        laps.map { lap in
            (number: lap.lapNumber, elapsed: TimingSession.formatMs(lap.elapsedMs), split: TimingSession.formatMs(lap.splitMs))
        }
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

        // Trigger visual flash in the UI
        lapFlashTrigger = UUID()

        // Re-arm haptic for next press
        haptic.prepare()

        // Auto-stop if we've reached the expected number of swimmers
        if let limit = expectedLapCount, laps.count >= limit {
            stop()
        }
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
                let created_at: String
            }
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
                    laps: laps,
                    startedAt: isoFormatter.string(from: sessionStartDate ?? Date()),
                    endedAt: isoFormatter.string(from: Date())
                )
                try await timingService.saveSession(session)
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
                let gear = "none"  // save flow defaults to no gear
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
                try await withTimeout(
                    Self.perCallTimeoutSeconds,
                    label: "savePairedLaps"
                ) {
                    try await self.timingService.savePairedLaps(
                        sessionId: sid,
                        stroke: self.stroke,
                        distance: self.distance,
                        intensity: self.intensityLabel ?? "race",
                        assignments: result.assignments
                    )
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
        state = .setup
    }
    /// Fetches session metadata to enable auto-stop logic
    /// BUGFIX (Phase 2.5-c): previously counted ALL wave_assignments for the session
    /// (N_swimmers × N_sets), so a 4-swimmer × 2-set session gave expectedLapCount = 8
    /// and the auto-stop never fired on the first set. Now counts distinct swimmer_ids
    /// — the per-set expected lap count, regardless of how many sets are in the session.
    func loadSessionContext(sessionId: String) async {
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
                        self.expectedLapCount = count
                    }
                }
            }
        } catch {
            print("[TimingViewModel] Context load failed: \(error)")
        }
    }


    /// Called by the 10ms timer to update elapsedMs.
    private func tick() {
        let now = Date().millisecondsSince1970
        elapsedMs = Int(now - repStartMs)
    }
}

// MARK: - Helpers

extension Date {
    var millisecondsSince1970: Int {
        Int(timeIntervalSince1970 * 1000)
    }
}