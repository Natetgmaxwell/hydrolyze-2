import SwiftUI

/// SessionReviewView — post-timing review screen.
/// Coach sees all laps with swimmer names, confidence badges, lane/wave context.
/// Tap a row → bottom sheet to reassign. "Needs Review" tab is default.
struct SessionReviewView: View {
    @StateObject private var viewModel = SessionReviewViewModel()
    @Environment(\.dismiss) private var dismiss
    let sessionId: String

    // PHASE 2.6 v1.17.0: Slice 2 of the emotional design plan. The
    // celebration moment fires after the coach approves all pairing
    // engine matches (a data-integrity milestone, NOT a state
    // transition like STOP). Triggered from both the non-alert confirm
    // path (handleConfirmTap) and the "Confirm Anyway" alert path.
    // Auto-dismisses back to TodayView after the 1.7s tick-mark
    // animation completes. See
    // [[concepts/tick-mark-celebration-pattern]] for the design.
    @State private var showCelebration = false
    /// Testing utility (V0.46): confirm dialog for the Discard button.
    @State private var showDiscardConfirm = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bgBase.ignoresSafeArea()

                VStack(spacing: 0) {
                    filterTabs
                    rowsList
                    confirmButton
                }
            }
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // Testing utility (V0.46): discard the session's
                    // recorded times and pop back to Today. Destructive
                    // — confirmed first. The label is the "trash" icon
                    // so it reads as delete without an extra word.
                    Button {
                        Haptics.warning()
                        showDiscardConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(Color.statusError)
                    }
                    .accessibilityLabel("Discard times")
                }
            }
            .alert("Discard times?", isPresented: $showDiscardConfirm) {
                Button("Cancel", role: .cancel) {
                    Haptics.selection()
                }
                Button("Discard", role: .destructive) {
                    Haptics.success()
                    Task { await viewModel.discardSession() }
                }
            } message: {
                Text("This permanently deletes all recorded times for this session. This cannot be undone.")
            }
            .sheet(isPresented: $viewModel.showReassignSheet) {
                if let row = viewModel.selectedRow {
                    ReassignSheet(
                        row: row,
                        // PHASE 2.6 v1.14: pass ordered candidates. For
                        // .likelyWrong rows, they're sorted by
                        // predicted-time proximity. For other bands
                        // the existing order is preserved.
                        candidates: viewModel.reassignCandidates(for: row),
                        onSelect: { swimmerId in
                            Task {
                                await viewModel.reassign(timeId: UUID(uuidString: row.id) ?? UUID(), toSwimmerId: swimmerId)
                            }
                        }
                    )
                }
            }
            .alert("Unconfirmed Rows", isPresented: $viewModel.showConfirmWarning) {
                Button("Cancel", role: .cancel) {
                    Haptics.selection()
                }
                Button("Confirm Anyway", role: .destructive) {
                    Haptics.success()
                    Task { 
                        await viewModel.confirmAll(force: true)
                        // PHASE 2.6 v1.17.0: trigger celebration from
                        // the alert path too. The handleConfirmTap
                        // function doesn't run in this branch (the
                        // alert dismisses and the confirm runs from
                        // here directly), so we trigger the
                        // celebration explicitly.
                        triggerCelebration()
                    }
                }
            } message: {
                Text("\(viewModel.effectiveUnconfirmedCount) row(s) have low confidence. Confirm anyway, or tap individual rows to reassign.")
            }
        }
        // PHASE 2.6 v1.17.0: celebration overlay. Sits on top of
        // everything including the navigation bar so the tick mark
        // animation reads as full-screen. .allowsHitTesting(false)
        // on the celebration component itself keeps the overlay
        // from blocking any post-celebration taps during the fade.
        .overlay {
            if showCelebration {
                TickMarkCelebrationView()
                    .transition(.opacity)
                    .zIndex(1000)
            }
        }
        .task {
            #if DEBUG
            // V0.46 Slice 5: screenshot harness — seed review rows
            // across all three confidence bands; no network.
            if ProcessInfo.processInfo.arguments.contains("-v46-demo-review") {
                viewModel.seedV46DemoRows()
                return
            }
            #endif
            await viewModel.load(sessionId: sessionId)
        }
        .onChange(of: viewModel.didDiscard) { discarded in
            if discarded {
                dismiss()
            }
        }
    }

    private var filterTabs: some View {
        HStack(spacing: 0) {
            // PHASE 2.6 v1.14: iterate Filter.displayed (3 tabs) instead
            // of Filter.allCases (which would also show the legacy
            // .needsReview case). Each tab gets a (N) count badge.
            ForEach(SessionReviewViewModel.Filter.displayed, id: \.rawValue) { f in
                Button {
                    // Micro-interaction: selection haptic on tab
                    // change. The .animation on the background
                    // and foreground below makes the swap
                    // visually smooth (cyan background slides
                    // into the selected tab). Together the
                    // haptic + the background morph = the user
                    // feels the filter change in two ways.
                    Haptics.selection()
                    withAnimation(Animations.snap) {
                        viewModel.filter = f
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(f.rawValue)
                            .font(.system(size: 14, weight: .medium))
                        Text("(\(viewModel.count(for: f)))")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundColor(
                                viewModel.filter == f
                                ? Color.textPrimary.opacity(0.75)
                                : Color.textFaint.opacity(0.75)
                            )
                    }
                    .foregroundColor(viewModel.filter == f ? Color.textPrimary : Color.textFaint)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        viewModel.filter == f ?
                        Color.bgSelected : Color.clear
                    )
                    .cornerRadius(8)
                    // Animate the (N) count badge color too —
                    // when the user switches tabs and the count
                    // values swap, the badges cross-fade into
                    // the new values.
                    .animation(Animations.snap, value: viewModel.filter)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var rowsList: some View {
        ScrollView {
            if viewModel.isLoading && viewModel.rows.isEmpty {
                // PHASE 2.6 v1.17.0: emotional-design Slice 3 — the
                // loading state uses the PhasedProgressView (single
                // pulsing dot) instead of a generic ProgressView.
                // The coach sees "we're fetching your session" rather
                // than a generic spinner. The label stays clinical
                // ("Loading review…") per the warmth-through-motion
                // direction.
                VStack(spacing: 12) {
                    PhasedProgressView(
                        phaseCount: 1,
                        currentPhase: 0,
                        phaseLabels: [],
                        currentDescription: nil
                    )
                    Text("Loading review…")
                        .font(.caption)
                        .foregroundColor(Color.textFaint)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 64)
            } else if let error = viewModel.errorMessage {
                Text(error)
                    .font(.body)
                    .foregroundColor(Color.statusError)
                    .padding()
            } else if viewModel.filteredRows.isEmpty {
                // PHASE 2.6 v1.14: empty-state copy now lives on the
                // Filter enum (icon, title, subtitle). The view no longer
                // branches on filter cases; the model owns the truth.
                VStack(spacing: 8) {
                    Image(systemName: viewModel.filter.emptyStateIcon)
                        .font(.system(size: 32, weight: .light))
                        .foregroundColor(Color.textFaint)
                    Text(viewModel.filter.emptyStateTitle)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Color.textFaint)
                    if let subtitle = viewModel.filter.emptyStateSubtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundColor(Color.textFaint)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 64)
                .padding(.horizontal, 32)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.filteredRows) { row in
                        // PHASE 2.6 v1.14: extract ALL three callbacks to
                        // let bindings. ReviewRowView has 3 function-typed
                        // params (onTap, onAccept, onMarkIntensity). When
                        // we tried to use multiple trailing closures with
                        // one of them passed as a named argument, the
                        // Swift parser got confused and produced three
                        // build errors at every call site (the trailing
                        // closure rule says "first trailing closure binds
                        // to the first function-typed param in declaration
                        // order" — when one is named-arg'd and skipped
                        // over, the parser loses the binding). Two
                        // attempts at the trailing-closure form failed
                        // (the v1.14.0 ternary trap, the v1.14.1 let-
                        // extract trap). The robust answer: name all
                        // three callbacks in the parameter list. No
                        // trailing closures. Let-bindings for readability
                        // — onMarkIntensity is 25+ lines of arg-packing.
                        let onAcceptCallback: (() -> Void)? = row.band == .likelyCorrect ? {
                            Haptics.success()
                            viewModel.acceptLowConfidenceRow(row.id)
                        } : nil
                        let onTapCallback: () -> Void = {
                            Haptics.tap()
                            viewModel.selectedRow = row
                            viewModel.showReassignSheet = true
                        }
                        let onMarkIntensityCallback: (String) async -> Void = { intensity in
                            // PHASE 2.6 v1.13.1: write a coach-confirmed
                            // PB at the chosen intensity. The lap time
                            // becomes a new (swimmer, intensity) PB,
                            // used by the predictor on the next session.
                            //
                            // PHASE 2.6 v1.17.0: pass real distance and
                            // stroke from the recordedTime row (after
                            // the model upgrade). The v1.13.1 placeholder
                            // WorkoutSet is gone; the function takes
                            // Int? / String? directly and falls back to
                            // 50m / "Free" if missing.
                            await viewModel.markRowIntensity(
                                timeId: UUID(uuidString: row.id) ?? UUID(),
                                swimmerId: row.recordedTime.pairedSwimmerId ?? row.recordedTime.swimmerId ?? "",
                                intensity: intensity,
                                lapTimeMs: row.recordedTime.timeMs,
                                gear: row.recordedTime.gear,
                                distance: row.recordedTime.paceDistance,
                                stroke: row.recordedTime.stroke
                            )
                            Haptics.success()
                        }
                        // V0.38 Slice 5 (2026-08-16): the 3MT
                        // panel is per-swimmer, not per-row. A 3MT
                        // session emits 9+ recorded_times rows per
                        // swimmer (one per split), so rendering the
                        // panel on every row would repeat the same
                        // panel 9 times. The parent identifies the
                        // FIRST row per swimmer (the row whose
                        // `rep_index` is the lowest in the filtered
                        // set) and passes the profile + curve ONLY
                        // to that row; subsequent split rows get
                        // nil and render no panel.
                        let swimmerKey = row.recordedTime.pairedSwimmerId ?? row.recordedTime.swimmerId ?? ""
                        let isFirstRowForSwimmer = viewModel.firstRowRepIndexBySwimmer[swimmerKey] == row.recordedTime.repIndex
                        let panelProfile: SwimmerTestProfile? = isFirstRowForSwimmer
                            ? viewModel.testProfiles[swimmerKey]
                            : nil
                        let panelCurve: [Double]? = isFirstRowForSwimmer
                            ? viewModel.testProfileCurves[swimmerKey]
                            : nil
                        ReviewRowView(
                            row: row,
                            isAcceptedByCoach: viewModel.coachConfirmedRowIds.contains(row.id),
                            // PHASE 2.6 v1.14: named args in struct
                            // declaration order. The previous fix
                            // (commit ae1c1aa) had onAccept before
                            // onTap, but the struct declares onTap
                            // (3rd param) before onAccept (4th).
                            // "Argument 'onTap' must precede argument
                            // 'onAccept'" — reorder the named args.
                            onTap: onTapCallback,
                            onAccept: onAcceptCallback,
                            onMarkIntensity: onMarkIntensityCallback,
                            // V0.38 Slice 5 (2026-08-16): per-swimmer
                            // 3MT panel data (see comment above).
                            threeMTProfile: panelProfile,
                            threeMTCurveSpeeds: panelCurve
                        )
                        // PHASE 2.6 v1.14: row enter/exit transition.
                        // When the user bulk-accepts rows or switches
                        // filters, rows fade + slide into their new
                        // positions instead of just appearing.
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity.combined(with: .scale(scale: 0.95))
                        ))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 80)
                .animation(Animations.springSoft, value: viewModel.filteredRows)
            }
        }
    }

    private var confirmButton: some View {
        VStack(spacing: 8) {
            if viewModel.effectiveUnconfirmedCount > 0 {
                Text("\(viewModel.effectiveUnconfirmedCount) row(s) need review")
                    .font(.numericSmall)
                    .foregroundColor(Color.textFaint)
            }

            // PHASE 2.6 v1.14: smart Confirm button. Label and tap
            // behavior depend on the row mix (see ConfirmButtonState).
            // The "Confirm Anyway" wording is gone — the button now
            // says what's about to happen.
            //
            // Micro-interactions:
            // - Haptics.warning() when the button is in the
            //   .withFlagged state (you're about to save with
            //   unconfirmed rows). Tactile "are you sure?"
            // - Haptics.success() on .allAuto (clean save).
            // - Haptics.tap() on the button press itself.
            // - StrongPressFeedbackStyle — the button compresses
            //   visibly on press.
            if case .empty = viewModel.confirmButtonState {
                EmptyView()
            } else {
                Button {
                    let state = viewModel.confirmButtonState
                    switch state {
                    case .empty:
                        return
                    case .allAuto:
                        Haptics.tap()
                    case .onlyLikelyCorrect:
                        Haptics.tap()
                    case .withFlagged:
                        // Tactile "are you sure?" before the alert
                        // re-confirms. Pairs with the destructive
                        // "Confirm Anyway" alert button.
                        Haptics.warning()
                    }
                    Task { await handleConfirmTap() }
                } label: {
                    Text(confirmButtonLabel)
                        .font(.titleSmall)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.accentAction)
                        .foregroundColor(Color.textOnAccent)
                        .cornerRadius(12)
                        // Animate the label change — when the
                        // row mix changes (e.g., a row moves
                        // from .likelyWrong to .likelyCorrect),
                        // the button label cross-fades into the
                        // new state. The .id() below forces a
                        // re-mount so the transition fires.
                        // The label is a unique-per-state String,
                        // so the id is unique-per-state too.
                        .id("confirm-button-\(confirmButtonLabel)")
                        .transition(.opacity)
                }
                .buttonStyle(StrongPressFeedbackStyle(scale: 0.97))
            }
        }
        .padding(16)
        .background(Color.bgDeep)
    }

    /// PHASE 2.6 v1.14: smart label for the Confirm button.
    private var confirmButtonLabel: String {
        switch viewModel.confirmButtonState {
        case .empty:
            return ""
        case .allAuto:
            return "Save session"
        case .onlyLikelyCorrect(_, let likelyCorrect):
            return "Accept \(likelyCorrect) + save"
        case .withFlagged(let total, _, let likelyWrong):
            // NOTE: the spec proposed "Save N with M flagged" but that
            // wording implies a `needs_review: true` flag in the DB.
            // Per the spec's "Ask first" list, adding a column to
            // `sessions` requires a migration + sign-off. The save
            // goes through with the unconfirmed rows in local state;
            // the DB still gets `reviewed_at` set. A follow-up
            // migration would surface this as a real flag.
            return "Save \(total) (\(likelyWrong) unconfirmed)"
        }
    }

    /// PHASE 2.6 v1.14: tap behavior for the Confirm button.
    private func handleConfirmTap() async {
        switch viewModel.confirmButtonState {
        case .empty:
            return
        case .allAuto:
            await viewModel.confirmAll()
        case .onlyLikelyCorrect:
            viewModel.bulkAcceptLikelyCorrect()
            await viewModel.confirmAll()
        case .withFlagged:
            await viewModel.confirmAll(force: true)
        }
        // PHASE 2.6 v1.17.0: trigger celebration after the confirm
        // resolves. The TickMarkCelebrationView plays for 1.7s, then
        // dismisses the SessionReviewView back to TodayView. This
        // is the data-integrity milestone (per emotional design plan
        // Slice 2) — the coach has approved all pairing matches, the
        // session is on disk, the work is done.
        //
        // V0.46 fix (2026-08-20): ONLY celebrate/dismiss on success.
        // Previously the celebration fired unconditionally after
        // confirmAll, so a confirm error (e.g. a failed sessions
        // write) set errorMessage but then the 1.7s celebration
        // auto-dismissed the screen — carrying the error message
        // away before the coach could read it. On failure, stay on
        // the review screen so the error is visible and retryable.
        if viewModel.errorMessage == nil {
            triggerCelebration()
        } else {
            print("[Review] confirm did not celebrate: \(viewModel.errorMessage ?? "unknown error")")
        }
    }

    /// PHASE 2.6 v1.17.0: centralized celebration trigger. Called
    /// from both the non-alert confirm path (handleConfirmTap above)
    /// and the "Confirm Anyway" alert path. Sets showCelebration,
    /// then auto-dismisses after the 1.7s animation completes.
    /// The dismiss action walks up the view hierarchy — SessionReviewView
    /// is rendered as a child of TimingView's body, which is itself
    /// presented as a fullScreenCover from TodayView, so dismiss()
    /// pops back to TodayView.
    private func triggerCelebration() {
        showCelebration = true
        Task {
            try? await Task.sleep(for: .milliseconds(1700))
            // Only dismiss if the celebration is still showing (it
            // could have been dismissed early by the user via swipe-back
            // gesture or similar).
            if showCelebration {
                showCelebration = false
                dismiss()
            }
        }
    }
}

// MARK: - Review Row

struct ReviewRowView: View {
    let row: SessionReviewViewModel.ReviewRow
    var isAcceptedByCoach: Bool = false   // Phase 2.6 v1.1: coach explicitly accepted despite low confidence
    var onTap: () -> Void
    /// PHASE 2.6 v1.14: callback for the inline ✓ accept button on
    /// .likelyCorrect rows. When non-nil, a checkmark icon appears
    /// on the right side of the subtle hint; tapping it accepts the
    /// row without opening the reassign sheet. nil = no button.
    var onAccept: (() -> Void)? = nil
    /// PHASE 2.6 v1.13.1: callback for the "Mark actual intensity"
    /// context menu. The view passes the chosen intensity to the
    /// view model, which writes a coach-confirmed PB.
    var onMarkIntensity: (String) async -> Void = { _ in }
    /// V0.38 Slice 5 (2026-08-16): the per-swimmer 3MT result
    /// profile, when present. The parent (`SessionReviewView`'s
    /// `rowsList`) passes the profile for the FIRST row per
    /// swimmer (lowest `rep_index`); subsequent split rows for
    /// the same swimmer get `nil` so the panel only renders once
    /// per swimmer — the work order calls for a per-swimmer panel,
    /// not per-lap.
    var threeMTProfile: SwimmerTestProfile? = nil
    /// V0.38 Slice 5 (2026-08-16): the per-swimmer per-split
    /// speed array (m/s). Mirrors `threeMTProfile` in scope —
    /// passed only for the first row per swimmer.
    var threeMTCurveSpeeds: [Double]? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: 12) {
                Circle()
                    .fill(row.confidenceLevel.color)
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.swimmerName)
                        .font(.bodyEmphasis)
                        .foregroundColor(Color.textPrimary)

                    // PHASE 2.6 v1.14: LOUD variance hint for likelyWrong,
                    // rendered as the FIRST child of the row content.
                    // Amber (#F5B34B) 13pt semibold with warning-triangle
                    // icon — the coach understands WHY the row is flagged
                    // in <1s.
                    if row.band == .likelyWrong, let h = row.varianceHint {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Predicted \(String(format: "%.1f", h.predSec))s, actual \(String(format: "%.1f", h.actualSec))s (\(String(format: "%.1f", h.zScore))σ off)")
                                .font(.eyebrowLarge)
                                .lineLimit(2)
                        }
                        .foregroundColor(Color.accentAmber)
                        .padding(.bottom, 4)
                    }

                    HStack(spacing: 8) {
                        if let lane = row.lane {
                            Text("Lane \(lane)")
                                .font(.system(size: 12))
                                .foregroundColor(Color.textFaint)
                        }
                        if let wave = row.wave {
                            Text("Wave \(wave)")
                                .font(.system(size: 12))
                                .foregroundColor(Color.textFaint)
                        }
                        Text("\(row.confidence)%")
                            .font(.numericSmall)
                            .foregroundColor(row.confidenceLevel.color)
                    }

                    // PHASE 2.6 v1.14: SUBTLE variance hint for likelyCorrect,
                    // rendered at the bottom. Gray 11pt with info-circle icon
                    // — the row is probably right; this is a "FYI."
                    // The inline ✓ button on the right is a single-tap accept
                    // (added in Slice 3, per the spec's "Accept N + save" path).
                    if row.band == .likelyCorrect, let h = row.varianceHint {
                        HStack(spacing: 4) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 10))
                            Text("Pred \(String(format: "%.1f", h.predSec))s vs \(String(format: "%.1f", h.actualSec))s (\(String(format: "%.1f", h.zScore))σ)")
                                .font(.numericSmall)
                            Spacer(minLength: 8)
                            if let onAccept = onAccept {
                                Button {
                                    onAccept()
                                } label: {
                                    // PHASE 2.6 v1.14 Slice 5b: 44pt hit
                                    // area per Apple HIG. The icon stays
                                    // 18pt visually (via the .frame), but
                                    // the tap target is 44x44 via
                                    // .contentShape(Rectangle()).
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 18))
                                        .foregroundColor(Color.textPrimary)
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .foregroundColor(Color.textFaint)
                        .padding(.top, 2)
                    }

                    // PHASE 1 (T8, 2026-06-20): calibration hint. Shown
                    // when the suit or start calibration adjusted the
                    // prediction. The format is "X% off due to suit
                    // calibration" / "Y% off due to start calibration"
                    // (per the v3 plan T8 acceptance criteria). The
                    // hint is hidden when both deltas are nil or zero.
                    if let c = row.calibrationHint {
                        HStack(spacing: 6) {
                            Image(systemName: "ruler")
                                .font(.system(size: 10))
                            if c.suitPct != 0 {
                                Text(String(format: "%.1f%% off due to suit calibration", abs(c.suitPct)))
                                    .font(.numericSmall)
                            }
                            if c.suitPct != 0 && c.startPct != 0 {
                                Text("·").font(.numericSmall).foregroundColor(Color.textFaint)
                            }
                            if c.startPct != 0 {
                                Text(String(format: "%.1f%% off due to start calibration", abs(c.startPct)))
                                    .font(.numericSmall)
                            }
                        }
                        .foregroundColor(Color.textFaint)
                        .padding(.top, 2)
                    }
                }

                Spacer()

                Text(TimingSession.formatMs(row.recordedTime.timeMs))
                    .font(.numeric)
                    .foregroundColor(Color.textPrimary)

                if isAcceptedByCoach {
                    // Visual confirmation that the coach has accepted
                    // this low-confidence pairing. Distinct from the
                    // auto-paired high-confidence green.
                    Image(systemName: "hand.thumbsup.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Color.statusSuccess)
                } else if row.confidence >= 80 {
                    // V0.52.6 (2026-09-26): rows the engine auto-assigned
                    // (confidence ≥ 80) get a quiet success checkmark at
                    // 60% opacity — implicit acceptance without inviting
                    // a tap. Chevron stays for rows the engine has NOT
                    // committed to (below 80%).
                    Image(systemName: "checkmark")
                        .font(.system(size: 12))
                        .foregroundColor(Color.statusSuccess.opacity(0.6))
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundColor(Color.textFaint)
                }
                }
                .padding(12)
                .background(row.confidenceLevel.backgroundColor)
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .contextMenu {
            // Long-press to accept a low-confidence pairing without
            // opening the reassign sheet. Useful when the coach knows
            // the pairing is correct but the engine has high variance.
            Button {
                onTap()
            } label: {
                Label("Reassign swimmer", systemImage: "person.crop.circle.badge.exclamationmark")
            }

            // PHASE 2.6 v1.13.1: "Mark actual intensity" — lets the
            // coach teach the engine about a new unofficial PB. The
            // selected intensity becomes a coach-confirmed PB at
            // (swimmer, stroke, distance, intensity, gear), used by
            // the predictor on the next session. Closes the
            // flywheel loop. Only show this menu item for
            // low-confidence rows (where the coach might want to
            // override).
            if row.confidence < 70 {
                Divider()
                Menu {
                    ForEach(["max", "moderate", "threshold", "easy"], id: \.self) { intensity in
                        Button {
                            Task {
                                await onMarkIntensity(intensity)
                            }
                        } label: {
                            Label(intensity.capitalized, systemImage: "scope")
                        }
                    }
                } label: {
                    Label("Mark actual intensity", systemImage: "scope")
                }
            }
            }
            // V0.38 Slice 5 (2026-08-16): the per-swimmer 3MT
            // panel. Renders under the row when the parent passes
            // a profile (the parent passes it for the FIRST row
            // per swimmer — see `rowsList` in SessionReviewView).
            // For non-3MT sessions the profile is always nil and
            // the panel never appears; the review surface is
            // visually identical to pre-Slice-5.
            if let profile = threeMTProfile {
                ThreeMTPanelView(
                    profile: profile,
                    swimmerName: row.swimmerName,
                    curveSpeeds: threeMTCurveSpeeds
                )
            }
        }
    }
}

// MARK: - Reassign Sheet

struct ReassignSheet: View {
    let row: SessionReviewViewModel.ReviewRow
    // PHASE 2.6 v1.14: replaced `allSwimmerNames: [(String, String)]`
    // with `candidates: [ReassignCandidate]` so the predicted time
    // rides with the candidate (used for the "Pred: X.Xs" suffix
    // and the proximity sort in the view-model).
    let candidates: [SessionReviewViewModel.ReassignCandidate]
    let onSelect: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bgBase.ignoresSafeArea()

                List {
                    ForEach(candidates) { candidate in
                        let swimmerId = UUID(uuidString: candidate.id) ?? UUID()
                        Button {
                            Haptics.action()
                            onSelect(swimmerId)
                            dismiss()
                        } label: {
                            HStack(spacing: 8) {
                                Text(candidate.name)
                                    .foregroundColor(Color.textPrimary)
                                Spacer()
                                // PHASE 2.6 v1.14: "Pred: X.Xs" suffix
                                // so the coach can see why this row is
                                // where it is in the sort order.
                                if let pred = candidate.predictedTimeMs {
                                    Text("Pred: \(String(format: "%.1f", Double(pred) / 1000))s")
                                        .font(.numericSmall)
                                        .foregroundColor(Color.textFaint)
                                }
                                if candidate.id == row.id {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(Color.textPrimary)
                                }
                            }
                        }
                        .listRowBackground(Color.bgDeep)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Assign Swimmer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        Haptics.tap()
                        dismiss()
                    }
                    .foregroundColor(Color.textPrimary)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

#Preview {
    SessionReviewView(sessionId: "test")
}