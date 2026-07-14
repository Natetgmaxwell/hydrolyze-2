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
    @StateObject private var viewModel = TodayViewModel()
    @State private var showSessionStart = false
    @State private var activeSession: ActiveTimingSession?
    @State private var attendanceEntries: [CoachAttendanceEntry] = []
    @State private var showAttendancePopover = false

    private var coachId: String? {
        authManager.coachId
    }

    var body: some View {
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
                // PHASE 2.6 v1.17.0: emotional-design Slice 1 motion
                // change. The pull-to-refresh indicator picks up the
                // cyan tint automatically — small detail that makes
                // the surface feel brand-consistent.
                .tint(Color.accentCyan)
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
        }
        .task {
            await reloadAll(coachId: authManager.coachId)
        }
    }

    // MARK: - derived state

    private var attendingCount: Int {
        attendanceEntries.filter { $0.intent == "in" }.count
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
                .fetchAttendance(forWorkoutId: workoutId)
        } catch {
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
        }
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
}

#Preview {
    TodayView()
        .environment(AuthManager())
}