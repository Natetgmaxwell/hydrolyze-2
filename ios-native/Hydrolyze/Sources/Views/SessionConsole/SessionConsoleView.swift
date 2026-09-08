import SwiftUI

/// SessionConsoleView — top-level container for the V0.54 Session
/// Console. Renders one of four state bodies per the spec's PRE/LIVE/
/// BETWEEN/POST graph. S1 ships only PRE; S2/S3/S4 add the rest in
/// dependency order.
///
/// Opened from:
///   - `TodayView.WorkoutCard.onStartSession` (replaces the V0.49
///     `SessionStartView` cover)
///   - `WorkoutsListView` row tap for `.scheduled` / `.inProgress`
///     status (decision 15 — `.draft` / `.complete` still go to
///     `WorkoutDetailView`).
///
/// Decision 12: `SessionConsoleView` owns lifecycle. LIVE/BETWEEN/POST
/// delegate to `TimingView.timingBody` (S2 — the 1300-line TimingView
/// is wrapped, not rewritten). S1's PRE body is the only screen that
/// ships today; the `state` switch returns a stub for the other three
/// so the compiler is happy and S2 can fill them in.
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
            case .live, .between, .post:
                // S1 ships only PRE. Other states land in S2/S3/S4.
                // Render a one-line placeholder so the compiler is happy
                // and the debug harness can verify the state advance
                // (PRE → LIVE on Start Session tap).
                stubBody(for: viewModel.state)
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
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-v54-demo-console") || args.contains("-v54-demo-console-live") {
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
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 16)
            setList
                .padding(.horizontal, 16)
            Spacer(minLength: 16)
            breadcrumb
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            startButton
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
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

    /// Read-only set list. Renders one row per set with the same
    /// "◯ N  ZONE  label" vocabulary as the spec wireframe. Each row
    /// is plain text — no buttons, no taps (the WorkoutPreview
    /// zero-CTA contract held).
    private var setList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(viewModel.sets.sorted(by: { $0.orderIndex < $1.orderIndex })) { set in
                HStack(spacing: 12) {
                    Text("◯")
                        .font(.titleSmall)
                        .foregroundStyle(Color.textFaint)
                        .frame(width: 18)
                    Text("\(set.orderIndex + 1)")
                        .font(.numericSmall)
                        .foregroundStyle(Color.textMuted)
                        .frame(width: 24, alignment: .leading)
                    if let zone = set.zoneTerm?.uppercased() {
                        Text(zone)
                            .font(.eyebrow)
                            .foregroundStyle(Color.textFaint)
                            .tracking(0.5)
                            .frame(width: 84, alignment: .leading)
                    }
                    Text(set.label)
                        .font(.body)
                        .foregroundStyle(Color.textPrimary)
                    Spacer()
                }
            }
        }
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
        .accessibilityLabel("Start session")
    }

    // MARK: - Stubs (S2/S3/S4 fill these in)

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