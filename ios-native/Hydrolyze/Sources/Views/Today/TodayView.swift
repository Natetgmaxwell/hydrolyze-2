import SwiftUI

/// TimingNavItem — type-safe navigation token for pushing TimingView.
struct TimingNavItem: Hashable {
    let workoutId: String
}

/// Identifiable wrapper for `.fullScreenCover(item:)` so the cover can drive on a String id.
struct ActiveTimingSession: Identifiable, Hashable {
    let id: String
    // Phase 2.6 v1.6.1 fix: workoutSetId is the set the coach picked in
    // the wave preview (workoutSets[previewSetIndex].id). The TimingView
    // needs it to filter wave_assignments in save() (the bug that v1.6
    // was trying to fix). Before this, only WorkoutDetailView's
    // prefill-based path passed workoutSetId; TodayView's path dropped
    // it at the SessionStartView → TimingView boundary. Now it's part
    // of the active-session envelope so both paths carry it.
    let workoutSetId: String
}

/// TodayView — real coach home screen. Fetches today's scheduled workout on appear
/// and on pull-to-refresh. Uses @StateObject for the view model (owns the data fetch).
struct TodayView: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var viewModel = TodayViewModel()
    @State private var animateIn: Bool = false
    @State private var showSessionStart = false
    @State private var activeSession: ActiveTimingSession?
    @State private var attendanceEntries: [CoachAttendanceEntry] = []
    @State private var showAttendancePopover = false

    private var coachId: String? {
        authManager.coachId
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                iPadLayout
            } else {
                phoneLayout
            }
        }
        .fullScreenCover(isPresented: $showSessionStart) {
            SessionStartView(
                sessionId: UUID().uuidString,
                workoutSets: viewModel.todayWorkoutSets,
                onComplete: { sessionId, workoutSetId in
                    activeSession = ActiveTimingSession(
                        id: sessionId,
                        workoutSetId: workoutSetId
                    )
                }
            )
        }
        .fullScreenCover(item: $activeSession) { session in
            TimingView(sessionId: session.id, workoutSetId: session.workoutSetId)
        }
        .onAppear { animateIn = true }
        .task {
            #if DEBUG
            // V0.46 Slice 5: screenshot harness — seed a realistic
            // Monday-morning squad session; no network in the demo path.
            if ProcessInfo.processInfo.arguments.contains("-v46-demo-today") {
                viewModel.seedV46DemoToday()
                return
            }
            #endif
            await reloadAll(coachId: authManager.coachId)
        }
    }

    // MARK: - phone layout (existing compact canvas, sidebar in NavigationSplitView
    // is hidden on iPhone so we wrap our own NavigationStack + top bar title).

    private var phoneLayout: some View {
        NavigationStack {
            ZStack {
                Color.bgBase.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        dateSection
                        if let workout = viewModel.todayWorkout {
                            VStack(spacing: 12) {
                                WorkoutCard(
                                    workout: workout,
                                    setCount: viewModel.setCount,
                                    swimmerCount: viewModel.swimmerCount,
                                    onStartSession: { showSessionStart = true }
                                )
                                // Attendance badge — non-intrusive,
                                // tap to open the inline popover.
                                AttendanceBadge(
                                    attendingCount: attendingCount,
                                    totalCount: viewModel.swimmerCount
                                )
                                .padding(.horizontal, 16)
                                .onTapGesture {
                                    Haptics.selection()
                                    showAttendancePopover = true
                                }
                                .popover(isPresented: $showAttendancePopover) {
                                    AttendancePopoverContent(
                                        entries: attendanceEntries,
                                        onSetIntent: { swimmerId, intent in
                                            await setIntent(
                                                swimmerId: swimmerId,
                                                intent: intent
                                            )
                                        }
                                    )
                                }
                            }
                            .padding(.horizontal, 16)
                        } else if !viewModel.isLoading {
                            EmptyStateView()
                        }
                    }
                    .padding(.top, 8)
                }
                .redacted(reason: viewModel.isLoading && viewModel.todayWorkout == nil ? .placeholder : [])
                .refreshable { await reloadAll(coachId: authManager.coachId) }
                // V0.46 Slice 4: pull-to-refresh reads mist — wayfinding
                // chrome is teal-family; coral stays CTA-only.
                .tint(Color.textPrimary)
            }
            .navigationTitle("TODAY")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(destination: ProfileView()) {
                        Image(systemName: "gearshape.fill")
                            .foregroundColor(Color.textFaint)
                    }
                }
            }
        }
    }

    // MARK: - iPad layout (detail column of NavigationSplitView).
    // The split view already labels the section in the sidebar, so we
    // drop the inner NavigationStack/title and stretch to the full
    // detail canvas with a two-column body: primary content on the
    // left, quick-actions rail on the right.

    private var iPadLayout: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 24) {
                    dateSection
                    if let workout = viewModel.todayWorkout {
                        VStack(spacing: 12) {
                            WorkoutCard(
                                workout: workout,
                                setCount: viewModel.setCount,
                                swimmerCount: viewModel.swimmerCount,
                                onStartSession: { showSessionStart = true }
                            )
                            AttendanceBadge(
                                attendingCount: attendingCount,
                                totalCount: viewModel.swimmerCount
                            )
                            .onTapGesture {
                                Haptics.selection()
                                showAttendancePopover = true
                            }
                            .popover(isPresented: $showAttendancePopover) {
                                AttendancePopoverContent(
                                    entries: attendanceEntries,
                                    onSetIntent: { swimmerId, intent in
                                        await setIntent(
                                            swimmerId: swimmerId,
                                            intent: intent
                                        )
                                    }
                                )
                            }
                        }
                    } else if !viewModel.isLoading {
                        EmptyStateView()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Quick actions")
                        .font(.eyebrow)
                        .foregroundColor(Color.textFaint)
                    VStack(alignment: .leading, spacing: 8) {
                        if viewModel.todayWorkout != nil {
                            quickActionRow(
                                label: "Start Session",
                                icon: "play.fill",
                                color: Color.accentAction
                            ) {
                                showSessionStart = true
                            }
                        } else {
                            quickActionRow(
                                label: "Plan a session",
                                icon: "calendar.badge.plus",
                                color: Color.accentAction
                            ) {
                                // TODO: present SetScheduleView (WorkoutsListView) — stub
                            }
                        }
                        quickActionRow(
                            label: "Who's in today",
                            icon: "person.2.fill",
                            color: Color.textMuted
                        ) {
                            // TODO: navigate to SwimmersListView — stub
                        }
                    }
                    .padding(12)
                    .background(Color.bgRaised)
                    .cornerRadius(12)
                }
                .frame(width: 320)
            }
            .padding(24)
        }
        .redacted(reason: viewModel.isLoading && viewModel.todayWorkout == nil ? .placeholder : [])
        .refreshable { await reloadAll(coachId: authManager.coachId) }
        .tint(Color.textPrimary)
    }

    @ViewBuilder
    private func quickActionRow(
        label: String,
        icon: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundColor(color)
                    .frame(width: 24)
                Text(label)
                    .font(.body)
                    .foregroundColor(Color.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundColor(Color.textFaint)
                    .font(.caption)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - derived state

    /// v1.17 Slice 4: counts resolved attendance, not raw `intent == "in"`.
    /// A squad running on standing schedules used to read as "0 attending"
    /// because nobody had an explicit row.
    private var attendingCount: Int {
        attendanceEntries.filter(\.isAttending).count
    }

    // MARK: - data flow

    private func reloadAll(coachId: String?) async {
        await viewModel.loadTodayWorkout(coachId: coachId)
        if let workout = viewModel.todayWorkout {
            await loadAttendance(workoutId: workout.id)
        }
    }

    private func loadAttendance(workoutId: String) async {
        do {
            attendanceEntries = try await CoachIntentService()
                .fetchResolvedAttendance(forWorkoutId: workoutId)
                .entries
        } catch {
            // Includes AttendanceError.unschedulable — a workout with no
            // date can't be resolved against a weekday pattern. Empty is
            // the honest answer; the badge reads "0 of N".
            attendanceEntries = []
        }
    }

    private func setIntent(swimmerId: String, intent: String) async {
        guard let workoutId = viewModel.todayWorkout?.id else { return }
        do {
            try await CoachIntentService().setIntent(
                workoutId: workoutId,
                swimmerId: swimmerId,
                intent: intent
            )
            Haptics.tap()
            await loadAttendance(workoutId: workoutId)
        } catch {
            Haptics.error()
        }
    }

    private var dateSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(formattedDate)
                .font(.titleMedium)
                .foregroundColor(Color.textPrimary)

            Text(greeting)
                .font(.body)
                .foregroundColor(Color.textMuted)
                .opacity(animateIn ? 1.0 : 0.0)
                .animation(
                    reduceMotion ? nil : Animations.gentle.delay(0.15),
                    value: animateIn
                )
        }
        .opacity(animateIn ? 1.0 : 0.0)
        .scaleEffect(animateIn ? 1.0 : 0.95)
        .animation(reduceMotion ? nil : Animations.springSoft, value: animateIn)
        .padding(.horizontal, 16)
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter.string(from: Date())
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 12 { return "Good morning, Coach." }
        else if hour < 17 { return "Good afternoon, Coach." }
        else { return "Good evening, Coach." }
    }
}

/// TodayViewModel — @StateObject ownership pattern (iOS 17 equivalent of useState + useEffect).
/// SwiftUI destroys and recreates this when the view struct is recomputed.
@MainActor
final class TodayViewModel: ObservableObject {
    @Published var todayWorkout: Workout?
    @Published var todayWorkoutSets: [WorkoutSet] = []
    @Published var setCount: Int = 0
    @Published var swimmerCount: Int = 0
    @Published var isLoading: Bool = true
    @Published var errorMessage: String?

    private let workoutService = WorkoutService()

    func loadTodayWorkout(coachId: String?) async {
        guard let coachId = coachId else {
            isLoading = false
            return
        }
        isLoading = true
        errorMessage = nil

        do {
            let workout = try await workoutService.fetchTodayWorkout(coachId: coachId)
            todayWorkout = workout
            if let workout = workout {
                let sets = try await workoutService.fetchWorkoutSets(workoutId: workout.id)
                todayWorkoutSets = sets
                setCount = sets.count
                swimmerCount = 0
            }
        } catch {
            errorMessage = "Couldn't load today's workout."
        }

        isLoading = false
    }

    #if DEBUG
    /// V0.46 Slice 5: screenshot-harness seed. The shape mirrors a real
    /// Monday-morning fetch: one scheduled workout, five sets across the
    /// zone ramp, a 14-swimmer squad. Network is never touched.
    func seedV46DemoToday() {
        let today = ISO8601DateFormatter().string(from: Date())
        let workout = Workout(
            id: "v46-demo-workout",
            coachId: "v46-demo-coach",
            title: "Threshold Tuesday",
            description: "Warm-up, main threshold block, warm-down.",
            scheduledAt: today,
            amPm: "am",
            completedAt: nil,
            status: .scheduled,
            createdAt: today,
            updatedAt: nil,
            sessionType: nil
        )
        func set(_ i: Int, _ reps: Int?, _ distance: Int?, _ stroke: String?, _ zone: String?) -> WorkoutSet {
            WorkoutSet(
                id: "v46-demo-set-\(i)",
                workoutId: workout.id,
                orderIndex: i,
                reps: reps,
                distance: distance,
                stroke: stroke,
                intervalText: nil,
                intensityType: nil,
                intensityLabel: nil,
                zoneTerm: zone,
                paceTargetDistance: nil,
                gear: nil,
                suit: nil,
                startType: nil,
                dive: nil,
                fragments: nil,
                createdAt: today
            )
        }
        todayWorkout = workout
        todayWorkoutSets = [
            set(0, 1, 400, "Free", "easy"),
            set(1, 8, 50, "Free", "easy"),
            set(2, 6, 100, "Free", "steady"),
            set(3, 5, 100, "Free", "hard"),
            set(4, 8, 25, "Free", "sprint"),
        ]
        setCount = todayWorkoutSets.count
        swimmerCount = 14
        isLoading = false
        errorMessage = nil
    }
    #endif
}

#Preview {
    TodayView()
        .environment(AuthManager())
}