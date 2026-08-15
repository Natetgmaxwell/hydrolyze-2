import SwiftUI

/// TimingView — pool-deck timing screen (I9a).
/// State machine: .setup → .ready → .running → .finished
/// The LAP button is the on-screen interface; I9b adds volume-button support.
/// Use `prefill` param when launching from a specific workout set (WorkoutDetailView).
/// Omit it for bare start from TodayView (swimmer + stroke/distance picked inside).
/// `sessionId` is set when launched from SessionStart flow for review wiring.
struct TimingView: View {
    @Environment(AuthManager.self) private var authManager
    @StateObject private var viewModel = TimingViewModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    let prefill: SetPrefill?
    var sessionId: String?
    /// Phase 2.6 v1.6.1: explicit workoutSetId parameter. The prefill
    /// also carries a workoutSetId, but TodayView's path doesn't
    /// construct a prefill (it just passes sessionId + workoutSetId
    /// from the SessionStartView's onComplete callback). So accept
    /// workoutSetId as its own parameter for clarity and to make the
    /// intent obvious. workoutSetId wins if both are present — the
    /// prefill is for ad-hoc single-set timing from WorkoutDetailView,
    /// the explicit param is for the full multi-step TodayView flow.
    var workoutSetId: String?
    /// t_d59998d9 (2026-08-05) + t_bec2b88b (2026-08-06): recorded-time
    /// callback. Fires once when the stopwatch transitions out of
    /// `.running` (to `.finished` or `.saving`). Delivers the full
    /// `StopwatchCapturePayload` (the canonical handoff shape
    /// documented in `stopwatch-capture-payload.ts`). The payload
    /// carries recordedTimeMs, fragment metadata, the original
    /// set text, and identifiers for session / coach / swimmer
    /// context — everything the persistence layer (task 3,
    /// t_1789d5c7) needs to write the row. The prior
    /// `(fragmentId, elapsedMs)` tuple was implicit; this is the
    /// typed contract.
    ///
    /// Nil on paths without a per-fragment context AND without an
    /// active session (bare start from TodayView, multi-swimmer
    /// timing where `assembleCapturePayload` returns nil because
    /// the bare-start-with-no-session path is not part of the
    /// persistence contract). The View guards before firing.
    var onRecord: ((StopwatchCapturePayload) -> Void)? = nil

    init(
        prefill: SetPrefill? = nil,
        sessionId: String? = nil,
        workoutSetId: String? = nil,
        onRecord: ((StopwatchCapturePayload) -> Void)? = nil
    ) {
        self.prefill = prefill
        self.sessionId = sessionId
        self.workoutSetId = workoutSetId
        self.onRecord = onRecord
    }

    @State private var showSwimmerPicker = false
    @State private var showReview = false
    @State private var lapFlashOpacity: Double = 0

    var body: some View {
        // PHASE 2.6 v1.8: render SessionReviewView directly when
        // the save succeeds. Previous design used
        // .onChange(of: viewModel.hasSavedPairedLaps) +
        // .navigationDestination(isPresented: $showReview), which
        // turned out to be fragile in the iOS 17+ NavigationStack
        // model — the .onChange fired but the conditional
        // `if let sid = sessionId` inside the destination closure
        // left the destination empty in some race conditions, and
        // the user was stuck on the .saving screen even though
        // save() had completed successfully.
        //
        // Bypass: when hasSavedPairedLaps is true AND sessionId
        // is non-nil, render SessionReviewView directly in the
        // body. The if-let guard is evaluated at body-render
        // time (not in a closure), so the sessionId capture
        // can't drift. The .onChange + .navigationDestination
        // chain is kept as a fallback for any environment that
        // doesn't trigger this branch.
        //
        // ponytail 2026-07-18: per-view portrait lock for the
        // stopwatch would require a custom UIHostingController
        // subclass (SwiftUI has no .supportedInterfaceOrientations
        // modifier in iOS 17). For now the stopwatch rotates with
        // the iPad — the iPad Info.plist lists all orientations
        // (landscape included) so the rest of the app rotates too.
        // A future commit can add the UIHostingController subclass
        // if the user wants the stopwatch specifically locked.
        if viewModel.hasSavedPairedLaps, let sid = sessionId {
            SessionReviewView(sessionId: sid)
        } else {
            timingBody
        }
    }

    /// The original body, retained as a separate computed property
    /// so the direct-render branch above can use it as a fallback.
    private var timingBody: some View {
        ZStack {
            // PHASE 2.6 v1.17.0: emotional-design Slice 1 — state
            // transitions are now smooth crossfades (each state's
            // view carries a .transition modifier, and the ZStack
            // carries .animation(Animations.springSoft, value:
            // viewModel.state)). The .setup → .ready → .running
            // → .saving → .finished sequence feels like the app is
            // responding, not jumping.
            switch viewModel.state {
            case .setup:
                setupView
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.98)),
                        removal: .opacity
                    ))
            case .ready:
                readyView
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.98)),
                        removal: .opacity
                    ))
            case .running:
                runningView
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.98)),
                        removal: .opacity
                    ))
            case .saving:
                savingView
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.98)),
                        removal: .opacity
                    ))
            case .finished:
                finishedView
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.98)),
                        removal: .opacity
                    ))
            }
        }
        .animation(reduceMotion ? .linear(duration: 0.01) : Animations.springSoft, value: viewModel.state)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Cancel is shown in .setup and .ready only. During .running, the only
            // exit path is the on-screen STOP button (deliberate action — Cancel
            // mid-set would discard captured laps). In .finished, the exit is
            // Save or Discard inside the finished view.
            if viewModel.state == .setup || viewModel.state == .ready {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(.white)
                }
            }
        }
        // Fallback navigation path — kept for completeness, the
        // direct-render branch above is the primary path now.
        .onChange(of: viewModel.hasSavedPairedLaps) { _, saved in
            if saved {
                // Success haptic when the save completes and we're
                // about to navigate to SessionReviewView. Pairs
                // with the cyan flash + the SPAV navigate. The
                // "ding-ding-rise" pattern signals "your session
                // is on disk and ready to review."
                Haptics.success()
                showReview = true
            }
        }
        .navigationDestination(isPresented: $showReview) {
            if let sid = sessionId {
                SessionReviewView(sessionId: sid)
            }
        }
        // t_d59998d9 (2026-08-05): recorded-time callback. Fires once
        // when the stopwatch transitions out of `.running` to either
        // `.finished` (single-swimmer prefill path) or `.saving`
        // (multi-swimmer / SessionStart path). The payload is
        // assembled via `viewModel.assembleCapturePayload(...)` and
        // carries the full structured surface the persistence layer
        // (task 3, t_1789d5c7) consumes: recordedTimeMs, fragment
        // metadata, source set text, session/coach/swimmer context,
        // capture moment, and idempotencyKey. OnRecord is nil for
        // paths without a coachId (signed out) or an active session
        // (bare-start-with-no-session is not part of the persistence
        // contract), so we guard before firing.
        //
        // Re-entry on the same fragment is a fresh eventId +
        // idempotencyKey, so the persistence layer inserts a new
        // row per stopwatch run. This is the spec's "re-entering a
        // fragment produces an independent timing run" acceptance
        // gate, satisfied at the iOS level.
        .onChange(of: viewModel.state) { oldValue, newValue in
            guard oldValue == .running, newValue != .running else { return }
            guard let onRecord = onRecord,
                  let coachId = authManager.coachId else { return }
            do {
                let payload = try viewModel.assembleCapturePayload(
                    coachId: coachId,
                    sessionId: sessionId,
                    // The source set text is the prefill's display
                    // label, which WorkoutDetailView populates with
                    // the original raw text the coach entered. For
                    // the bare-start path (prefill == nil) the
                    // assembler falls back to the fragment's
                    // descriptor; for the per-fragment CTA path the
                    // WorkoutDetailView holds the original text.
                    sourceSetText: prefill?.displayLabel
                )
                guard let payload = payload else { return }
                onRecord(payload)
            } catch {
                print("[TimingView] assembleCapturePayload FAILED: \(error.localizedDescription) — onRecord not fired")
            }
        }
    }

    // MARK: - Setup

    private var setupView: some View {
        VStack(spacing: 32) {
            Spacer()

            Text("START SESSION")
                .font(.eyebrowLarge)
                .foregroundColor(Color.textFaint)
                .tracking(2)

            // When launched from a workout set, show locked label instead of pickers
            if let prefill = prefill {
                Text(prefill.displayLabel)
                    .font(.titleLarge)
                    .foregroundColor(Color.textPrimary)
                    .padding(.bottom, 8)
            }

            // Swimmer picker
            VStack(alignment: .leading, spacing: 8) {
                Text("SWIMMER")
                    .font(.eyebrow)
                    .foregroundColor(Color.textFaint)

                Button {
                    Haptics.selection()
                    showSwimmerPicker = true
                } label: {
                    HStack {
                        Text(viewModel.selectedSwimmerName ?? "Select swimmer")
                            .font(.system(size: 17))
                            .foregroundColor(
                                viewModel.selectedSwimmerId != nil
                                ? Color.textPrimary
                                : Color.textFaint
                            )
                        Spacer()
                        Image(systemName: "chevron.down")
                            .foregroundColor(Color.textFaint)
                            .rotationEffect(.degrees(showSwimmerPicker ? 180 : 0))
                            .animation(reduceMotion ? .linear(duration: 0.01) : Animations.snap, value: showSwimmerPicker)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(Color.bgRaised)
                    .cornerRadius(10)
                }
            }
            .padding(.horizontal, 24)

            // Stroke + distance — only shown when no prefill (bare start)
            if prefill == nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("STROKE")
                        .font(.eyebrow)
                        .foregroundColor(Color.textFaint)

                    FlowLayout(spacing: 8) {
                        ForEach(["Free", "Back", "Breast", "Fly", "IM"], id: \.self) { stroke in
                            strokeChip(stroke, selected: viewModel.stroke == stroke) {
                                viewModel.stroke = stroke
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)

                VStack(alignment: .leading, spacing: 8) {
                    Text("DISTANCE")
                        .font(.eyebrow)
                        .foregroundColor(Color.textFaint)

                    FlowLayout(spacing: 8) {
                        ForEach([25, 50, 100, 200], id: \.self) { dist in
                            strokeChip("\(dist)m", selected: viewModel.distance == dist) {
                                viewModel.distance = dist
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
            }

            Spacer()

            // Confirm button
            Button {
                if let swimmerId = viewModel.selectedSwimmerId {
                    Haptics.action()
                    let stroke = prefill?.stroke ?? viewModel.stroke
                    let distance = prefill?.distance ?? viewModel.distance
                    viewModel.confirmSetup(swimmerId: swimmerId, swimmerName: viewModel.selectedSwimmerName ?? "", stroke: stroke, distance: distance)
                }
            } label: {
                Text("CONTINUE")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Color.bgBase)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(
                        viewModel.selectedSwimmerId != nil
                        ? Color.accentCyan
                        : Color.bgInset
                    )
                    .cornerRadius(12)
            }
            .disabled(viewModel.selectedSwimmerId == nil)
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .sheet(isPresented: $showSwimmerPicker) {
            SwimmerPickerSheet(selectedId: $viewModel.selectedSwimmerId, selectedName: $viewModel.selectedSwimmerName)
        }
        .onAppear {
            // Carry the sessionId into the VM so `stop()` can auto-save
            // for multi-swimmer sessions. nil for single-swimmer (prefill)
            // flows — `stop()` will leave the .finished view visible in
            // that case so the coach can review before saving.
            viewModel.sessionId = sessionId

            if let sid = sessionId {
                viewModel.confirmSessionSetup()
                // Phase 2.6 v1.6.1 fix: prefer the explicit
                // workoutSetId parameter (set by TodayView's
                // SessionStartView path). The prefill-based path
                // (WorkoutDetailView) also sets workoutSetId in
                // the else branch below. workoutSetId wins if
                // both are present.
                if let setId = workoutSetId {
                    viewModel.workoutSetId = setId
                }
                // t_c74dffbc (2026-08-04): if a prefill is present
                // (e.g. per-fragment CTA), propagate its fragment
                // contexts into the view model so the save flow
                // keys predictions per (swimmer, fragment).
                if let prefill = prefill, let fragments = prefill.fragmentContexts {
                    viewModel.fragmentContexts = fragments
                }
                Task {
                    await viewModel.loadSessionContext(sessionId: sid)
                }
            } else if let prefill = prefill {
                viewModel.stroke = prefill.stroke
                viewModel.distance = prefill.distance
                viewModel.reps = prefill.reps
                viewModel.interval = prefill.interval
                viewModel.intensityLabel = prefill.intensityLabel
                // V0.38 Slice 4 (2026-08-16): copy the structured
                // intensity_type rawValue alongside the human label so
                // 3MT detection can match "3mt" without relying on the
                // label text. The label may be "3-minute all-out"
                // (parser) or "3mt" (raw); both should classify the
                // session correctly via `viewModel.is3MTSession`.
                viewModel.intensityType = prefill.intensityType
                viewModel.workoutSetId = prefill.workoutSetId
                // t_c74dffbc (2026-08-04): per-fragment contexts for
                // composite sets. nil/empty means the existing
                // parent-set prediction path; non-empty means the
                // save flow keys predictions per (swimmer, fragment).
                if let fragments = prefill.fragmentContexts {
                    viewModel.fragmentContexts = fragments
                }
                // V0.38 Slice 4 (2026-08-16): derive the 3MT gate from
                // the prefill right after copying the fields. Gates
                // the countdown in the running view and the
                // analyzer-on-stop path in save().
                viewModel.is3MTSession = viewModel.deriveIs3MTSession()
            }
        }
    }

    private func strokeChip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(selected ? Color.bgBase : Color.textMuted)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(selected ? Color.accentCyan : Color.bgRaised)
                .cornerRadius(20)
        }
        // Subtle scale on press for the chip — these are tappable
        // pills and the scale sells the press without making the
        // chip "bounce."
        .buttonStyle(PressFeedbackStyle(scale: 0.94, dim: 0.85))
    }

    // MARK: - Ready (Phase 2.5-c: B&W + 20% cyan stopwatch aesthetic)

    private var readyView: some View {
        VStack(spacing: 0) {
            Spacer()

            // Huge monospaced 0:00.00 — same display as .running for visual continuity
            Text("0:00.00")
                .font(.jetBrainsMono(size: 86, weight: .bold))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .foregroundColor(.white)
                .padding(.bottom, 16)

            // READY label
            Text("READY")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
                .tracking(4)

            // Set context (white 0.4 = subtle)
            Text("\(viewModel.stroke) · \(viewModel.distance)m")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
                .padding(.top, 12)

            Text("Press volume up or tap to start")
                .font(.caption)
                .foregroundColor(.white.opacity(0.4))
                .padding(.top, 4)

            Spacer()

            // Big cyan START button — the 20% splash.
            //
            // Micro-interactions:
            // - Haptics.action() on tap — the loudest "I did the
            //   thing" signal in the app.
            // - StrongPressFeedbackStyle — the button compresses
            //   visibly on press (0.92 scale + dim) so the user
            //   gets immediate confirmation their tap registered
            //   before the time actually starts running.
            // - phaseAnimator breathing — gentle 1.0 → 1.04 → 1.0
            //   scale on a 1.4s cycle. The button "invites" the
            //   tap. The animation only runs while the button is
            //   visible (i.e., in .ready state), so the
            //   `.running` state isn't visually noisy.
            Button {
                Haptics.action()
                viewModel.start()
            } label: {
                Text("START")
                    .font(.system(size: 26, weight: .heavy, design: .monospaced))
                    .foregroundColor(.black)
                    .frame(width: 200, height: 200)
                    .background(Color.accentCyan)
                    .clipShape(Circle())
                    // Soft outer glow that intensifies with the
                    // breathing pulse — the button radiates
                    // energy when it wants to be tapped.
                    .shadow(
                        color: Color.accentCyan.opacity(0.35),
                        radius: 24, x: 0, y: 0
                    )
            }
            .buttonStyle(StrongPressFeedbackStyle(scale: 0.92))
            .phaseAnimator([1.0, 1.04, 1.0]) { content, scale in
                content
                    .scaleEffect(scale)
                    .shadow(
                        color: Color.accentCyan.opacity(scale == 1.0 ? 0.35 : 0.55),
                        radius: scale == 1.0 ? 24 : 32, x: 0, y: 0
                    )
            } animation: { _ in
                reduceMotion ? .linear(duration: 0.01) : .easeInOut(duration: 1.4)
            }

            Spacer()
        }
    }

    // MARK: - Running (Phase 2.5-c: B&W + 20% cyan stopwatch aesthetic)

    private var runningView: some View {
        ZStack {
            VStack(spacing: 0) {
                // HUGE time display — the main visual element, white monospaced
                // (JetBrains Mono Nerd Font — see Fonts/README.md for the file).
                // .minimumScaleFactor(0.5) lets the text shrink on narrow
                // devices (iPhone 13 = 390pt, 86pt at JetBrains Mono is well
                // within the screen, but the safety net stays for narrower
                // devices like iPhone SE). .lineLimit(1) prevents
                // truncation-with-"..." if a longer time format appears
                // (e.g., a 10-minute set).
                Text(viewModel.formattedTime)
                    .font(.jetBrainsMono(size: 86, weight: .bold))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .padding(.horizontal, 16)
                    .foregroundColor(.white)
                    .padding(.top, 60)
                    .padding(.bottom, 4)

                // V0.38 Slice 4 (2026-08-16): 3MT countdown display.
                // Shown only when `viewModel.is3MTSession` — the
                // timing screen for a 3-minute all-out test carries a
                // coach-facing "3:00 → 0:00" countdown alongside the
                // audit-trail stopwatch (the stopwatch total keeps
                // running for the recorded_times row). The stopwatch
                // auto-stops at 0 via `tick()` in the VM.
                //
                // Placement: directly under the main stopwatch,
                // visually secondary (smaller monospaced type, white
                // 0.85 normally). <30s remaining → amber so the
                // coach sees the test is in the final third. NO new
                // colors / fonts — `Color.accentAmber` and
                // `.jetBrainsMono` are both already in the type
                // scale (used by SwimmerAnalyticsView / the main
                // stopwatch respectively).
                if viewModel.is3MTSession {
                    Text(viewModel.threeMinuteTestCountdownText)
                        .font(.jetBrainsMono(size: 32, weight: .semibold))
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .padding(.horizontal, 16)
                        .foregroundColor(
                            viewModel.threeMinuteTestRemainingMs < 30_000
                                ? Color.accentAmber
                                : .white.opacity(0.85)
                        )
                        .padding(.bottom, 8)
                }

                // "LAP N" counter — subtle, white 0.7
                Text("LAP \(viewModel.laps.count + 1)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                    .tracking(2)
                    .padding(.bottom, 16)

                // Lap list (kept as-is per Nathan's Q1 answer)
                lapList
                    .padding(.horizontal, 24)

                Spacer()

                // Big cyan LAP button — the 20% splash.
                //
                // Micro-interactions:
                // - Haptics.action() on tap. The LAP tap is the
                //   coach's PRIMARY action — they press it dozens
                //   of times per session. The medium impact is
                //   strong enough to feel through pool-deck noise
                //   (echoes, splashes, swimmer chatter) without
                //   being intrusive.
                // - StrongPressFeedbackStyle — visible press
                //   compression (0.92 scale + dim) so the tap is
                //   obviously registered.
                // - Cyan flash overlay — see `lapFlashOpacity`
                //   below. Spring-animated (not easeOut) for a
                //   more "punchy" feel that matches the medium
                //   haptic.
                Button {
                    Haptics.action()
                    viewModel.lap()
                } label: {
                    Text("LAP")
                        .font(.system(size: 26, weight: .heavy, design: .monospaced))
                        .foregroundColor(.black)
                        .frame(width: 160, height: 160)
                        .background(Color.accentCyan)
                        .clipShape(Circle())
                }
                .buttonStyle(StrongPressFeedbackStyle(scale: 0.90))
                .padding(.bottom, 16)

                // STOP — on-screen only, intentionally subtle (white 0.4).
                // Micro-interaction: Haptics.heavy() on tap. The
                // heavy impact (versus the medium LAP impact) is a
                // tactile "are you sure?" — STOP is destructive in
                // the sense that it ends the running state and
                // moves to the .finished view. A heavier buzz
                // signals "this is a different kind of action."
                Button {
                    Haptics.heavy()
                    viewModel.stop()
                } label: {
                    Text("STOP")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.4))
                        .tracking(3)
                        .padding(.bottom, 32)
                }
                .buttonStyle(PressFeedbackStyle(scale: 0.96, dim: 0.7))
            }

            // Cyan flash overlay — pulses on each lap for
            // haptic-visual confirmation. Spring-animated (not
            // easeOut) for a more "punchy" feel that matches the
            // medium LAP haptic.
            Color.accentCyan
                .opacity(lapFlashOpacity)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .animation(reduceMotion ? .linear(duration: 0.01) : Animations.springSnappy, value: lapFlashOpacity)
        }
        .onChange(of: viewModel.lapFlashTrigger) { _, _ in
            // Pulse the cyan flash to 0.4 (was 0.35 — slightly
            // more visible to match the stronger spring) and
            // decay back via spring. .task(id:) below handles
            // the decay; this onChange handles the up-spike
            // synchronously so the flash feels instant on tap.
            lapFlashOpacity = 0.4
        }
        .task(id: viewModel.lapFlashTrigger) {
            // Wait briefly so the up-spike is visible, then
            // decay back to 0 with a soft spring. Replaces the
            // original DispatchQueue.main.asyncAfter approach,
            // which was brittle (could miss the timing if a
            // re-render preempted the closure).
            // PHASE 1 (T8.5, 2026-06-20): lapFlashTrigger changed
            // from Int counter to UUID? in TimingViewModel (each
            // lap save produces a fresh UUID; the .task(id:) modifier
            // re-runs the body when the value changes). The "is the
            // trigger active?" check is therefore nil vs non-nil,
            // not > 0. UUID? comparison with Int doesn't compile.
            guard viewModel.lapFlashTrigger != nil else { return }
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(Animations.springSoft) {
                lapFlashOpacity = 0
            }
        }
    }

    // MARK: - Lap list (Phase 2.5-c: B&W, no card backgrounds, JetBrains Mono)

    private var lapList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(viewModel.formattedLaps.reversed(), id: \.number) { lap in
                    HStack {
                        Text("LAP \(lap.number)")
                            .font(.jetBrainsMono(size: 14))
                            .foregroundColor(.white.opacity(0.7))
                        Spacer()
                        Text(lap.elapsed)
                            .font(.jetBrainsMono(size: 16, weight: .bold))
                            .foregroundColor(.white)
                        Text(lap.split)
                            .font(.jetBrainsMono(size: 12))
                            .foregroundColor(.white.opacity(0.4))
                            .frame(width: 70, alignment: .trailing)
                    }
                    .padding(.vertical, 4)
                    // No card background — pure B&W, list rows separated by spacing
                }
            }
        }
        .frame(maxHeight: 240)
    }

    // MARK: - Saving (Phase 2.5-c: skip the complete page)
    // Shown briefly while the pairing engine runs + writes to Supabase. The
    // existing .onChange(of: viewModel.hasSavedPairedLaps) navigates to
    // SessionReviewView on success. On failure, the VM falls back to
    // .finished so the coach sees the error and can retry.
    //
    // Phase 2.6 v1.2: live progress (currentSaveStep), errorMessage
    // display, CANCEL button, and SKIP PAIRING button. The Skip Pairing
    // button is the escape hatch — it bypasses the pairing engine
    // entirely and just records the raw times so the coach can manually
    // assign each lap in the SessionReviewView.
    //
    // Phase 2.6 v1.4: the v1.4 "opt-in pairing engine" experiment was
    // reverted (commit 4ba83b0) — the user explicitly said "the
    // pairing is essential." The default flow is the engine. SKIP
    // PAIRING stays as an escape hatch for true hangs, NOT as the
    // primary path.
    private var savingView: some View {
        VStack(spacing: 20) {
            Spacer()

            // PHASE 2.6 v1.17.0: emotional-design Slice 3 — the
            // saving state now uses the new PhasedProgressView
            // component (1-5 dots, active dot pulses cyan). Replaces
            // the generic ProgressView + rawValue text with a phased
            // indicator that shows WHERE the save is (fetching /
            // predicting / pairing / saving / done) instead of a
            // generic spinner. See plans/emotional-design-coverage-
            // matrix.md §"Slice 3: phased loading + saving state".
            // The saveLog tail stays — it's the diagnostic for a
            // silent hang, not a "what's happening" UI element.
            PhasedProgressView(
                phaseCount: 5,
                currentPhase: savePhaseIndex,
                phaseLabels: ["FETCHING", "PREDICTING", "PAIRING", "SAVING", "DONE"],
                currentDescription: viewModel.saveLog.last
            )

            // Live diagnostic log tail (Phase 2.6 v1.5). Shows the
            // last 6 lines of the saveLog so the user can see WHERE
            // the engine is (or hung) at any moment. The full log
            // also goes to the Xcode console via `print()`. This is
            // the primary diagnostic for a silent hang.
            if !viewModel.saveLog.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(viewModel.saveLog.suffix(6).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 9, weight: .regular, design: .monospaced))
                            .foregroundColor(.white.opacity(0.35))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.top, 4)
            }

            // Error display — if the save threw, show it immediately
            // instead of making the user wait for the watchdog timeout.
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(Color.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 4)
            }

            // Action buttons — SKIP PAIRING (escape hatch) and CANCEL.
            // Both fall back to the .finished view. The engine is
            // still running in the background, but the user is unblocked.
            VStack(spacing: 12) {
                // SKIP PAIRING — escape hatch. Bypasses the engine
                // entirely if it's hung. Records the raw lap times
                // so the coach can manually pair them in review.
                Button {
                    Task { await viewModel.skipPairing() }
                } label: {
                    Text("SKIP PAIRING — JUST RECORD TIMES")
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(1.5)
                        .foregroundColor(Color.accentCyan)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(Color.accentCyan, lineWidth: 1)
                        )
                }

                // CANCEL — falls back to the .finished view, user
                // can tap SAVE in there to retry the engine.
                Button {
                    viewModel.cancelSave()
                } label: {
                    Text("CANCEL")
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(2)
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                }

                // PHASE 2.6 v1.8: "Copy Debug Info" button. The user
                // asked: "show everything so I can copy and paste it
                // back to you — to close the loop and assist with
                // improvement and debugging." The saveLog already
                // surfaces 6 lines on screen; this button dumps
                // the FULL log + state + device context to the
                // system clipboard so the user can paste it into
                // a chat. Pair with the .saving view's on-screen
                // log tail — on-screen for at-a-glance, clipboard
                // for the full picture.
                Button {
                    let info = """
                    === Hydrolyze Save Debug Info ===
                    Captured: \(Date().formatted(date: .abbreviated, time: .standard))
                    App version: \(Bundle.main.appVersion)
                    Build: \(Bundle.main.buildNumber)
                    iOS: \(Bundle.main.osVersion)
                    State: \(viewModel.state)
                    Current step: \(viewModel.currentSaveStep.rawValue.isEmpty ? "(none)" : viewModel.currentSaveStep.rawValue)
                    hasSavedPairedLaps: \(viewModel.hasSavedPairedLaps)
                    sessionId: \(sessionId ?? "(nil)")
                    errorMessage: \(viewModel.errorMessage ?? "(none)")
                    Laps captured: \(viewModel.laps.count)
                    Wave assignments (after filter): \(viewModel.lastWaveAssignmentCount.map(String.init) ?? "(none yet)")
                    saveLog lines: \(viewModel.saveLog.count)

                    === saveLog (full) ===
                    \(viewModel.saveLog.joined(separator: "\n"))
                    === end saveLog ===
                    """
                    UIPasteboard.general.string = info
                } label: {
                    Text("COPY DEBUG INFO")
                        .font(.eyebrow)
                        .tracking(1.5)
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        )
                }
                .padding(.top, 4)
            }
            .padding(.top, 8)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // PHASE 2.6 v1.17.0: emotional-design Slice 3 helper. Maps the
    // TimingViewModel's `currentSaveStep` enum (idle / fetching /
    // predicting / pairing / saving / complete) to a 0-4 phase
    // index for the PhasedProgressView. The `.idle` state collapses
    // into phase 0 (FETCHING) — the progress indicator shows what
    // the save IS doing, not what it hasn't started yet.
    private var savePhaseIndex: Int {
        switch viewModel.currentSaveStep {
        case .idle, .fetching: return 0
        case .predicting: return 1
        case .pairing: return 2
        case .saving: return 3
        case .complete: return 4
        }
    }

    // MARK: - Finished (Phase 2.5-c: B&W + 20% cyan stopwatch aesthetic)

    private var finishedView: some View {
        VStack(spacing: 0) {
            Text("SESSION COMPLETE")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
                .tracking(3)
                .padding(.top, 40)
                .padding(.bottom, 16)

            // Final time — large monospaced
            Text(viewModel.formattedTime)
                .font(.jetBrainsMono(size: 56, weight: .bold))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .foregroundColor(.white)
                .padding(.bottom, 24)

            // Lap review (kept as-is)
            lapList
                .padding(.horizontal, 24)

            Spacer()

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.bottom, 8)
            }

            HStack(spacing: 16) {
                // DISCARD — subtle, no cyan (it's a destructive action, deliberately quieter).
                // Micro-interaction: Haptics.heavy() on tap. The
                // heavy impact signals "this destroys data" so the
                // coach is sure before they confirm in the alert.
                Button {
                    Haptics.heavy()
                    viewModel.discard()
                } label: {
                    Text("DISCARD")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(12)
                }
                .buttonStyle(PressFeedbackStyle(scale: 0.97, dim: 0.85))

                // SAVE — cyan, the positive action.
                // Micro-interaction: Haptics.action() on tap.
                // The success haptic (ding-ding-rise) fires when
                // the save completes and we're about to navigate
                // to SessionReviewView — see the .onChange below.
                Button {
                    Haptics.action()
                    Task {
                        // v1.12: pass live AuthManager.coachPreferences so
                        // the HistoricalTimePredictor uses the coach's
                        // chosen algorithm (median vs EMA). Default
                        // falls back to .default if the env is nil.
                        await viewModel.save(
                            sessionId: sessionId,
                            preferences: authManager.coachPreferences
                        )
                    }
                } label: {
                    if viewModel.isSaving {
                        ProgressView().tint(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.accentCyan)
                            .cornerRadius(12)
                    } else {
                        Text("SAVE")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.accentCyan)
                            .cornerRadius(12)
                    }
                }
                .buttonStyle(PressFeedbackStyle(scale: 0.97, dim: 0.92))
                .disabled(viewModel.isSaving)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
    }
}

// MARK: - Swimmer Picker Sheet

/// Simple swimmer picker sheet — shows active swimmers from the roster.
/// In I9b this will auto-suggest next swimmer based on the set.
struct SwimmerPickerSheet: View {
    @Binding var selectedId: String?
    @Binding var selectedName: String?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = SwimmersListViewModel()
    @Environment(AuthManager.self) private var authManager

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bgBase.ignoresSafeArea()

                if viewModel.isLoading {
                    ProgressView().tint(Color.accentCyan)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(viewModel.filteredSwimmers) { swimmer in
                                Button {
                                    Haptics.action()
                                    selectedId = swimmer.id
                                    selectedName = swimmer.fullName
                                    dismiss()
                                } label: {
                                    HStack {
                                        Text(swimmer.fullName)
                                            .font(.system(size: 17))
                                            .foregroundColor(Color.textPrimary)
                                        Spacer()
                                        if selectedId == swimmer.id {
                                            Image(systemName: "checkmark")
                                                .foregroundColor(Color.accentCyan)
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 14)
                                    .background(Color.bgRaised)
                                }
                            }
                        }
                        .cornerRadius(10)
                        .padding(.horizontal, 16)
                    }
                }
            }
            .navigationTitle("Select Swimmer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(Color.accentCyan)
                }
            }
            .task {
                await viewModel.loadSwimmers(coachId: authManager.coachId)
            }
            // PHASE 2.8.6: same nil→non-nil race fix as SwimmersListView.
            // .task captures coachId at view-appear time; if AuthManager
            // hasn't resolved the coach row yet, coachId is nil and
            // loadSwimmers early-returns. The .onChange re-triggers the
            // load once coachId becomes available.
            .onChange(of: authManager.coachId) { _, newCoachId in
                guard let newCoachId = newCoachId else { return }
                Task { await viewModel.loadSwimmers(coachId: newCoachId) }
            }
        }
    }
}

#Preview {
    TimingView()
        .environment(AuthManager())
}