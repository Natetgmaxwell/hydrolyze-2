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

    private var coachId: String? {
        authManager.coachId
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "060e18").ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        dateSection
                        if let workout = viewModel.todayWorkout {
                            WorkoutCard(
                                workout: workout,
                                setCount: viewModel.setCount,
                                swimmerCount: viewModel.swimmerCount,
                                onStartSession: { showSessionStart = true }
                            )
                            .padding(.horizontal, 16)
                        } else if !viewModel.isLoading {
                            EmptyStateView()
                        }
                    }
                    .padding(.top, 8)
                }
                .redacted(reason: viewModel.isLoading && viewModel.todayWorkout == nil ? .placeholder : [])
                .refreshable { await viewModel.loadTodayWorkout(coachId: authManager.coachId) }
                // PHASE 2.6 v1.17.0: emotional-design Slice 1 motion
                // change. The pull-to-refresh indicator picks up the
                // cyan tint automatically — small detail that makes
                // the surface feel brand-consistent.
                .tint(Color(hex: "09d4ee"))
            }
            .navigationTitle("TODAY")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(destination: ProfileView()) {
                        Image(systemName: "gearshape.fill")
                            .foregroundColor(Color(hex: "4a6572"))
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
            await viewModel.loadTodayWorkout(coachId: authManager.coachId)
        }
    }

    private var dateSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(formattedDate)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(Color(hex: "e2f4fa"))

            Text(greeting)
                .font(.system(size: 15))
                .foregroundColor(Color(hex: "7a9bb0"))
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