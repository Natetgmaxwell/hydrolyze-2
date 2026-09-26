import SwiftUI

/// SessionConsoleView — top-level container for the V0.54 Session
/// Console. Renders one of four state bodies per the spec's PRE/LIVE/
/// BETWEEN/POST graph. S1 ships PRE; S2 ships LIVE (via TimingView
/// wrapper, decision 12). S3/S4 add BETWEEN + POST in dependency
/// order.
///
/// Opened from:
///   - `TodayView.WorkoutCard.onStartSession` (replaces the V0.49
///     `SessionStartView` cover)
///   - `WorkoutsListView` row tap for `.scheduled` / `.inProgress`
///     status (decision 15 — `.draft` / `.complete` still go to
///     `WorkoutDetailView`).
///
/// Decision 12: `SessionConsoleView` owns lifecycle. LIVE/BETWEEN/POST
/// delegate to `TimingView.timingBody` (the 1300-line TimingView is
/// wrapped, not rewritten). LIVE renders the existing
/// `TimingView(mode: .console, prefill: SetPrefill(from: firstTimeable))`
/// directly — the spec's "Start Session → first timeable rep's
/// `.ready`" (decision 10). BETWEEN/POST are stub bodies for S3/S4.
struct SessionConsoleView: View {
    let workoutId: String
    @StateObject private var viewModel = SessionConsoleViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.bgBase.ignoresSafeArea()
            switch viewModel.state {
            case .pre:
                preBody
            case .live:
                // S2 (2026-09-08): LIVE renders the existing
                // TimingView (decision 12 — wrapper-not-rewrite),
                // seeded with a SetPrefill from the first timeable
                // set per spec §5. S3 (2026-09-09) also surfaces
                // the `WaveChipStrip` above the first rep's stopwatch
                // — the wave chip strip is a secondary coach action,
                // not the primary CTA (the stopwatch below remains
                // the single primary affordance per spec invariant).
                liveBody
            case .between:
                // S3 (2026-09-09): BETWEEN shows the send-off
                // countdown + Next-rep pill. Single primary CTA per
                // spec invariant — the pill IS the one action during
                // BETWEEN. Last-rep-of-set auto-progresses to POST
                // on :00 via the VM's countdown timer.
                betweenBody
            case .post:
                // S4 (deferred): POST body + Review pairs + End
                // session. S3 lands the state transition on the last
                // rep's countdown :00 and renders a placeholder so
                // the state machine is observable in the simulator.
                postStubBody
            }
        }
        .toolbar {
            // Spec wireframe PRE: ◂ Wed Sep 9 · AM  [End ✕]
            ToolbarItem(placement: .topBarLeading) {
                if let workout = viewModel.workout {
                    HStack(spacing: 6) {
                        Text(workoutDateLabel(workout))
                            .font(.captionStrong)
                            .foregroundStyle(Color.textMuted)
                        if let amPm = workout.amPm?.uppercased() {
                            Text(amPm)
                                .font(.captionStrong)
                                .foregroundStyle(Color.accentAmber)
                        }
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.tap()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(Color.textMuted)
                }
                .accessibilityLabel("End")
            }
        }
        .navigationBarBackButtonHidden(true)
        .task {
            #if DEBUG
            // V0.54 (2026-09-08): S1 screenshot-harness seed. Mirrors
            // V0.46 Slice 5's `-v46-demo-today` pattern — the headless
            // simctl capture can't sign in, so the VM gets a seeded
            // workout + roster directly. The Console's `enter(workoutId:)`
            // path also works for production traffic once an auth
            // session exists. `-v54-demo-console-live` is the S1
            // acceptance flag that flips the VM state to .live.
            //
            // V0.54 S2.1 (2026-09-08, jodie-09): `-v54-demo-console-
            // jodie09` routes the seed to the rich Purposeful Threshold
            // workout (every WorkoutPreview mode, "Each:" caption,
            // "Descend:" ladder, verbatim 12.5m fragments, DIVE/SUIT/
            // gear). The PRE + LIVE screenshots prove the full
            // rep-card anatomy renders — the user's image feedback
            // rejected the S1/S2 flat one-liner surface.
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-v54-demo-console")
               || args.contains("-v54-demo-console-live")
               || args.contains("-v54-demo-console-jodie09")
               || args.contains("-v54-demo-console-live-jodie09")
               || args.contains("-v54-demo-console-between-jodie09") {
                viewModel.seedV54DemoConsole()
                return
            }
            #endif
            await viewModel.enter(workoutId: workoutId)
        }
    }

    // MARK: - PRE body
    //
    // Single screen: workout title + set list (read-only) +
    // AttendanceBreadcrumb + Start Session. Decision 7: breadcrumb
    // never gates Start. Spec §8 acceptance: exactly one primary CTA
    // (accentAction foreground) in PRE.

    private var preBody: some View {
        // V0.54 S3.3b (2026-09-09): the prior VStack was a fixed
        // layout — when the jodie-09 S3.3 spacing rhythm (12pt
        // intra-set, 20pt between sets, hairlines) pushed the
        // preview taller than the screen, the VStack spilled
        // content off BOTH ends (top warm-up row clipped, START
        // SESSION entirely off-screen). The primary CTA of the PRE
        // state was unreachable.
        //
        // Standard pool-deck pattern: scroll the information surface
        // (workout preview), pin the action surface (breadcrumb +
        // START SESSION) to the safe-area bottom. Long workouts
        // scroll; short workouts sit at the natural top — but the
        // CTA is ALWAYS reachable regardless of workout length.
        //
        // The .safeAreaInset(edge: .bottom) footer lives outside the
        // ScrollView, so it cannot be clipped. The bottom inset
        // carries the 24pt safe-area padding the old VStack's
        // `.padding(.bottom, 24)` provided.
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                // V0.54 S2.1 (2026-09-08, jodie-09 user feedback):
                // replace the flat "◯ N | ZONE | label" one-liners with
                // the full WorkoutPreview rendering (rep cards × modes,
                // fragment rows, captions, send-offs). The spec's
                // "one primary CTA" rule constrains ACTIONS, not
                // INFORMATION — the coach must see exactly what the
                // swimmers will be doing, instruction included, before
                // tapping Start Session. The breadcrumb stays as the
                // only correction surface; START SESSION stays as the
                // only action surface.
                preWorkoutPreview
                    .padding(.horizontal, 16)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                breadcrumb
                    .padding(.horizontal, 16)
                startButton
                    .padding(.horizontal, 16)
            }
            .padding(.bottom, 24)
            .background(Color.bgBase)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(viewModel.workout?.title ?? "Workout")
                .font(.titleMedium)
                .foregroundStyle(Color.textPrimary)
            Text("\(viewModel.sets.count) sets · \(viewModel.workout != nil ? viewModel.totalCount : 0) swimmers")
                .font(.numericSmall)
                .foregroundStyle(Color.textMuted)
        }
    }

    /// V0.54 S2.1 (2026-09-08, jodie-09 user feedback): the PRE body's
    /// full WorkoutPreview rendering. Replaces the prior flat
    /// "◯ N | ZONE | label" one-liner surface with the same rich
    /// rep-card anatomy the builder preview uses — Modes
    /// `.track` / `.uniform` / `.progression`, fragment rows,
    /// captions ("Each:", "Descend:"), send-offs, distance labels
    /// ("12.5m" verbatim), gear/DIVE/SUIT badges, zone terms.
    ///
    /// The `context: .preview` flag keeps the zero-CTA invariant:
    /// no play icons, no tap gestures, the only interactive surface
    /// in PRE remains the breadcrumb + Start Session. `currentSetId`
    /// and `completedSetIds` stay nil/empty so every set renders at
    /// full opacity on the flat background — no elevation, no
    /// dimming.
    private var preWorkoutPreview: some View {
        // V0.54 S3.3 (2026-09-09, jodie-09 PRE round 2): the
        // progressive-disclosure screenshot harness flag. When
        // `-v54-s33-expand-warmdown` is in the launch args, the
        // warm-down set id (v54-jodie09-set-5) is forwarded into
        // `preExpandSetIds` so it renders in its EXPANDED state
        // instead of the default collapsed row. The verification
        // shot proves the tap-to-expand affordance triggers the
        // expanded render path (the `expandedSetBody` branch in
        // RepGroupRowView) — without needing a simctl tap (which
        // the harness doesn't support reliably across iOS
        // versions).
        //
        // Honest note: the warm-down's expanded render is
        // visually identical to its collapsed render in the
        // jodie-09 seed because the warm-down carries no extra
        // anatomy (no fragments, no zone chip, no gear, no note,
        // no per-rep targets — nothing beyond the "8×25 Free"
        // spine). The expanded branch renders exactly the same
        // one-line "8×25 Free" as the collapsed branch for a
        // set with this minimal anatomy. The mechanism is
        // verified via the harness state (UserDefaults
        // `v54s33_preExpandSetIds` records which set ids were
        // forwarded into the override set) — every set with
        // non-trivial anatomy (set 3's "Each:" caption, set 4's
        // DESCEND ladder, etc.) renders the expanded body and
        // proves the path. The warm-down itself is the simplest
        // set in the workout; collapsing it is purely a visual
        // simplification (less chrome to scan), not a data
        // hiding.
        let expandWarmdown = ProcessInfo.processInfo.arguments
            .contains("-v54-s33-expand-warmdown")
        let preExpand: Set<String> = expandWarmdown
            ? ["v54-jodie09-set-5"]
            : []
        return WorkoutPreview(
            workout: parsedWorkoutForPreview,
            context: .preview,
            currentSetId: nil,
            completedSetIds: [],
            preExpandSetIds: preExpand
        )
    }

    /// The parsed-workout tree shared between PRE and LIVE. Built
    /// from the loaded workout + sets via `WorkoutPreviewBuilder` —
    /// the same helper `WorkoutDetailView` uses so the two views
    /// cannot drift in their DB-row → ParsedRepGroup mapping.
    private var parsedWorkoutForPreview: ParsedWorkout {
        guard let workout = viewModel.workout else {
            return ParsedWorkout(title: nil, sections: [])
        }
        return WorkoutPreviewBuilder.fromWorkoutAndSets(workout, sets: viewModel.sets)
    }

    private var breadcrumb: some View {
        AttendanceBreadcrumb(
            attendingCount: viewModel.attendingCount,
            totalCount: viewModel.totalCount,
            fetchFailed: viewModel.rosterFetchFailed,
            entries: viewModel.attendanceEntries,
            onRetry: { Task { await viewModel.preTickRoster(workoutId: workoutId) } },
            onSetIntent: { swimmerId, intent in
                await viewModel.setIntent(
                    swimmerId: swimmerId,
                    intent: intent,
                    workoutId: workoutId
                )
            }
        )
    }

    /// The only CTA in PRE. Decision 3: "Start Session" — single
    /// button, no other action surface. Spec §8 acceptance:
    /// `accentAction` foreground appearances ≤ 1 in PRE.
    private var startButton: some View {
        Button {
            Haptics.tap()
            viewModel.startSession()
        } label: {
            Text("START SESSION")
                .font(.captionStrong)
                .tracking(1.0)
                .foregroundStyle(Color.textOnAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.accentAction)
                .cornerRadius(12)
        }
        .buttonStyle(PressFeedbackStyle())
        .disabled(!viewModel.canStartSession)
        .opacity(viewModel.canStartSession ? 1 : 0.4)
        .accessibilityLabel("Start session")
    }

    // MARK: - S2 LIVE body
    //
    // Per spec §6 / decision 12: render the existing TimingView
    // (mode: .console) with a SetPrefill constructed from the first
    // timeable set (spec §5 — lowest orderIndex with distance > 0
    // and intensityType != easy OR a timable fragment). The
    // RosterStripView renders above the stopwatch with the
    // preTickRoster entries (V0.49 S2 reuse).

    private var liveBody: some View {
        VStack(spacing: 0) {
            liveHeader
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 12)
            // V0.54 S2.1 (2026-09-08, jodie-09 user feedback): the
            // LIVE body now renders the full WorkoutPreview (every
            // fragment card, mode, caption) — same surface as PRE,
            // with the CURRENT set visually elevated (border + scale
            // + accent bg) and COMPLETED sets dimmed via reduced
            // opacity. The "one primary CTA" rule constrains
            // actions (the stopwatch below), not information
            // (every set is fully rendered).
            liveWorkoutPreview
                .padding(.horizontal, 16)
            // V0.54 S3 (2026-09-09): the wave chip strip renders
            // ABOVE the stopwatch (spec §3 / decision 11 — "the
            // first rep's stopwatch is the primary CTA; the wave
            // chip strip is a one-tap affordance above it"). Hidden
            // for solo swimmers (R8: <2 wave_assignments).
            //
            // `onTapChip(lane)` fires when the coach picks a swap
            // target inside the chip's quick-action menu; the VM's
            // `swapLanes(a: tappedLane, b: pickedLane)` mutates the
            // in-memory lane → name map. WaveChipStrip handles the
            // "tap chip → Menu → tap swap target" interaction itself;
            // the chip strip is a presentational view — the VM owns
            // the swap state.
            if !liveWaveChips.isEmpty {
                WaveChipStrip(
                    lanes: liveWaveChips,
                    onPickSwap: { tappedLane, pickedLane in
                        viewModel.swapLanes(a: tappedLane, b: pickedLane)
                    }
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
            if let prefill = liveSetPrefill {
                TimingView(
                    prefill: prefill,
                    sessionId: viewModel.sessionId,
                    workoutSetId: prefill.workoutSetId,
                    // Suppress TimingView's internal `RosterStripView`
                    // in `.console` mode — the Console's own header
                    // strip (rendered above) is the canonical "who's
                    // in" surface. Per spec §6 ("RosterStripView
                    // ... sits at the top of the LIVE screen,
                    // same as today") the Console owns the strip, not
                    // TimingView. Passing nil here means TimingView
                    // renders no strip.
                    roster: nil,
                    onRecord: { payload in
                        viewModel.handleRecordedPayload(payload, reps: prefill.reps ?? 0)
                    },
                    mode: .console
                )
            } else {
                // Spec §5 fallback: no timeable set → POST (S4 wires
                // the summary). S2 ships a stub explaining why LIVE
                // didn't render.
                noTimeableStub
            }
        }
    }

    /// V0.54 S2.1: the LIVE body's full WorkoutPreview. Reads the
    /// current set from `liveSetPrefill.workoutSetId` (the first
    /// timeable set per spec §5) so the elevation container knows
    /// which repGroup to elevate. Completed sets stay full-detail
    /// at reduced opacity (the user's jodie-09 feedback — flat
    /// one-liners were rejected because they hid what the swimmers
    /// would actually be doing).
    ///
    /// `context: .live` lets the play affordances surface on each
    /// timable card (the Console's stopwatch is the primary CTA,
    /// not the per-card play buttons — those launch individual
    /// fragment timing and are secondary).
    private var liveWorkoutPreview: some View {
        WorkoutPreview(
            workout: parsedWorkoutForPreview,
            context: .live,
            currentSetId: liveSetPrefill?.workoutSetId,
            completedSetIds: viewModel.completedSetIds
        )
    }

    /// Header above the LIVE stopwatch. Shows the breadcrumb (👤 N) +
    /// the set/rep context ("rep N / reps × distance @ send-off").
    /// S2 ships the breadcrumb + set context; S3 swaps in the
    /// BETWEEN send-off countdown.
    private var liveHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Roster strip — V0.49 reuse. Hidden when the roster is
            // empty (V0.49 contract held per spec §11).
            if !liveRoster.isEmpty {
                RosterStripView(roster: liveRoster)
            }
            if let prefill = liveSetPrefill {
                Text("SET \(prefillSetLabel(prefill))")
                    .font(.eyebrow)
                    .tracking(0.5)
                    .foregroundStyle(Color.textFaint)
            }
        }
    }

    private var liveRoster: [RosterEntryLite] {
        viewModel.attendanceEntries.map { entry in
            RosterEntryLite(
                swimmerId: entry.swimmerId,
                firstName: nil,
                lastName: entry.swimmerName
            )
        }
    }

    /// Build a `SetPrefill` from the first timeable set per spec §5.
    /// Returns nil when no set is timeable (the LIVE body renders
    /// `noTimeableStub` instead, and S4 wires POST).
    private var liveSetPrefill: SetPrefill? {
        guard let orderIndex = viewModel.firstTimeableRepIndex() else { return nil }
        let set = viewModel.sets.first(where: { $0.orderIndex == orderIndex })
        guard let set else { return nil }
        return SetPrefill(
            stroke: set.stroke ?? "Free",
            distance: set.distance ?? 50,
            reps: set.reps,
            interval: set.intervalText,
            intensityLabel: set.intensityLabel,
            workoutSetId: set.id,
            intensityType: set.intensityType,
            zoneTerm: set.zoneTerm,
            fragmentContexts: nil,
            gear: set.gear
        )
    }

    private func prefillSetLabel(_ prefill: SetPrefill) -> String {
        prefill.displayLabel
    }

    private var noTimeableStub: some View {
        VStack(spacing: 16) {
            Text("No timeable sets in this workout")
                .font(.titleSmall)
                .foregroundStyle(Color.textPrimary)
            Text("Every set is easy / has no distance / has no fragments. Spec §5 fallback: PRE → POST.")
                .font(.caption)
                .foregroundStyle(Color.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// V0.54 S3 (2026-09-09): derive `WaveChipStrip.LaneChip`s from
    /// the VM's `waveAssignmentsByLane` dict. Ordered ascending by
    /// lane number so the chips render in lane-1, lane-2, lane-3
    /// order — the visual that matches the pool layout. R8
    /// (solo-swimmer suppression) is handled in WaveChipStrip —
    /// it returns nil when `lanes.count <= 1`.
    private var liveWaveChips: [WaveChipStrip.LaneChip] {
        viewModel.waveAssignmentsByLane
            .sorted { $0.key < $1.key }
            .map { (lane, name) in
                WaveChipStrip.LaneChip(lane: lane, swimmerName: name)
            }
    }

    // MARK: - S3 BETWEEN body
    //
    // Per spec §BETWEEN wireframe (L120-136): the send-off
    // countdown + completed-rep list + a single primary CTA
    // (Next-rep pill). R7: nil/unparseable intervalText → no
    // countdown shown, the pill IS the only CTA, auto-progress
    // already handled by `liveEnter()` (the state lands in LIVE
    // directly when intervalMs is nil, so BETWEEN never enters).
    //
    // The countdown reads `:SS` for values under 60s and `M:SS`
    // above (defensive — 2:30 send-offs exist in the corpus).
    // Pure countdown publication — no side effects in the body;
    // the VM owns the timer.

    private var betweenBody: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)
            // Header strip — same `liveRoster` chip strip so the
            // coach sees "who's in" the same way across LIVE and
            // BETWEEN. Hidden for empty roster per V0.49 contract.
            if !liveRoster.isEmpty {
                RosterStripView(roster: liveRoster)
                    .padding(.horizontal, 16)
            }
            // Rep counter — "rep N / total × distance @ send-off".
            // Mirrors the LIVE header's "SET N" reading so the
            // coach reads the context on every state transition.
            if let set = viewModel.currentSet {
                Text("rep \((viewModel.currentRepIndex ?? 0) + 1) / \(set.reps ?? 0) × \(set.distance ?? 0)m \(set.stroke ?? "Free") @ \(set.intervalText ?? "")")
                    .font(.eyebrow)
                    .tracking(0.5)
                    .foregroundStyle(Color.textFaint)
                    .padding(.horizontal, 16)
            }
            // Send-off countdown — spec wireframe `───── :12 ─────`
            // reading. Renders as a single large `:SS` so the
            // coach reads it across the pool without squinting.
            // Guarded: nil countdown (e.g. R7 path already
            // auto-progressed) is unreachable in normal flow, but
            // the guard keeps the body safe during transitions.
            Text(countdownLabel)
                .font(.system(size: 64, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.textPrimary)
                .accessibilityLabel("Send-off countdown: \(countdownLabel) remaining")
            Text("next send-off")
                .font(.caption)
                .foregroundStyle(Color.textMuted)
            // Per spec §BETWEEN acceptance: `Next rep` pill is the
            // ONE primary CTA during BETWEEN. Non-blocking — the
            // pill short-circuits the countdown and the VM
            // advances the state machine forward.
            Button {
                Haptics.tap()
                viewModel.nextRep()
            } label: {
                Text("Start next rep now  →")
                    .font(.captionStrong)
                    .tracking(0.5)
                    .foregroundStyle(Color.textOnAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.accentAction)
                    .cornerRadius(12)
            }
            .buttonStyle(PressFeedbackStyle())
            .padding(.horizontal, 16)
            .accessibilityLabel("Start next rep now")
            Spacer(minLength: 0)
        }
    }

    /// Format the BETWEEN countdown digits. `:SS` for sub-1-minute,
    /// `M:SS` for send-offs above 60s (rare, but possible). Falls
    /// back to `0:00` when `countdownRemainingMs` is nil — that
    /// state is unreachable in normal flow (R7 short-circuits to
    /// LIVE/POST), but the guard prevents a SwiftUI body crash if
    /// the VM's countdown task is cancelled mid-tick.
    private var countdownLabel: String {
        let ms = viewModel.countdownRemainingMs ?? 0
        let totalSeconds = max(ms / 1000, 0)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: - S3 POST stub (S4 fills this)
    //
    // S3 lands the state transition `state = .post` on the last
    // rep's countdown :00 (spec §BETWEEN) but the POST body is
    // still a placeholder until S4. The stub matches the S1
    // pattern: explicit state name + back-to-PRE escape hatch.
    // Once S4 lands, the POST body replaces this with the
    // summary + Review pairs + End session CTAs.

    private var postStubBody: some View {
        VStack(spacing: 16) {
            Text("POST")
                .font(.titleSmall)
                .foregroundStyle(Color.textPrimary)
            Text("Session complete — S3 lands the state transition on the last rep's :00. The full POST body (one row per rep + Review pairs + End session) lands in S4.")
                .font(.caption)
                .foregroundStyle(Color.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Back to PRE") { viewModel.resetToPre() }
                .buttonStyle(.bordered)
                .tint(Color.accentAction)
        }
    }

    // MARK: - Stubs (S3/S4 fill these in)

    @ViewBuilder
    private func stubBody(for state: ConsoleState) -> some View {
        VStack(spacing: 16) {
            Text(label(for: state))
                .font(.titleSmall)
                .foregroundStyle(Color.textPrimary)
            Text("S1 ships PRE only. This state lands in S\(sForState(state)).")
                .font(.caption)
                .foregroundStyle(Color.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Back to PRE") { viewModel.resetToPre() }
                .buttonStyle(.bordered)
                .tint(Color.accentAction)
        }
    }

    private func label(for state: ConsoleState) -> String {
        switch state {
        case .pre: return "PRE"
        case .live: return "LIVE"
        case .between: return "BETWEEN"
        case .post: return "POST"
        }
    }

    private func sForState(_ state: ConsoleState) -> Int {
        switch state {
        case .pre: return 1
        case .live, .between: return 2
        case .post: return 4
        }
    }

    // MARK: - helpers

    private func workoutDateLabel(_ workout: Workout) -> String {
        guard let date = workout.scheduledAt else { return "Workout" }
        // The DB stores `scheduled_at` as 'yyyy-MM-dd' (sometimes
        // ISO 8601). Try the short form first.
        let parsers: [DateFormatter] = [
            { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }(),
            { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"; return f }(),
            { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"; return f }(),
        ]
        for parser in parsers {
            if let d = parser.date(from: date) {
                let f = DateFormatter()
                f.dateFormat = "EEE MMM d"
                return f.string(from: d)
            }
        }
        return date
    }
}

#Preview {
    NavigationStack {
        SessionConsoleView(workoutId: "preview-workout")
    }
}