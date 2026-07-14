import SwiftUI

@MainActor
final class WorkoutDetailViewModel: ObservableObject {
    @Published var workout: Workout?
    @Published var sets: [WorkoutSet] = []
    @Published var isLoading: Bool = true
    @Published var errorMessage: String?
    @Published var showDeleteConfirmation: Bool = false

    private let workoutService = WorkoutService()

    func loadWorkout(workoutId: String) async {
        isLoading = true
        errorMessage = nil

        do {
            async let workoutTask = workoutService.fetchWorkout(workoutId: workoutId)
            async let setsTask = workoutService.fetchWorkoutSets(workoutId: workoutId)
            workout = try await workoutTask
            sets = try await setsTask
        } catch {
            errorMessage = "Couldn't load workout: \(error)"
        }

        isLoading = false
    }

    func deleteWorkout(workoutId: String) async {
        do {
            try await workoutService.deleteWorkout(workoutId: workoutId)
        } catch {
            errorMessage = "Couldn't delete workout."
        }
    }

    func markComplete(workoutId: String) async {
        do {
            _ = try await workoutService.updateWorkout(workoutId: workoutId, updates: ["status": "complete"])
            workout?.status = .complete
        } catch {
            errorMessage = "Couldn't update workout."
        }
    }

    func startSession() {
        print("[WorkoutDetail] startSession tapped — placeholder for SetPicker")
    }

    func editWorkout() {
        print("[WorkoutDetail] editWorkout tapped — placeholder for I7 builder")
    }
}

/// WorkoutDetailView — pushed from WorkoutsListView. Shows parsed workout + actions.
struct WorkoutDetailView: View {
    let workoutId: String
    @Environment(AuthManager.self) private var authManager
    @StateObject private var viewModel = WorkoutDetailViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var activeSession: ActiveSession? = nil
    @State private var navigateToBuilder = false
    @State private var timingPrefill: SetPrefill?
    @State private var showSessionStart = false
    @State private var pendingSessionId = UUID().uuidString

    /// Wrapper for `.fullScreenCover(item:)` — needs Identifiable to drive the cover.
    /// Plain `String?` doesn't conform; without this the bottom TabView stays visible during timing.
    private struct ActiveSession: Identifiable, Hashable {
        let id: String
        // Phase 2.6 v1.6.1: workoutSetId is the set the coach picked in
        // the wave preview. Threaded into TimingView via the
        // SessionStartView.onComplete callback so the save() filter has
        // the current set id. The prefill-based path also sets
        // workoutSetId in TimingView.onAppear, but the explicit param
        // is the cleaner source of truth and matches TodayView's path.
        let workoutSetId: String
    }

    var body: some View {
        ZStack {
            Color.bgBase.ignoresSafeArea()

            ScrollView {
                if let workout = viewModel.workout {
                    VStack(alignment: .leading, spacing: 20) {
                        metadataSection(workout: workout)
                        WorkoutPreview(workout: buildParsedWorkout(from: workout, sets: viewModel.sets))
                            .padding(.horizontal, 16)
                        if let errorMessage = viewModel.errorMessage {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundColor(Color.statusError)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity)
                                .background(Color.statusError.opacity(0.1))
                                .cornerRadius(8)
                                .padding(.horizontal, 16)
                        }
                        setsList
                        actionButtons(workout: workout)
                    }
                    .padding(.vertical, 16)
                } else if !viewModel.isLoading {
                    Text(viewModel.errorMessage ?? "Workout not found")
                        .foregroundColor(Color.textMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                }
            }
            .redacted(reason: viewModel.isLoading && viewModel.workout == nil ? .placeholder : [])

            if viewModel.isLoading && viewModel.workout == nil {
                ProgressView()
                    .tint(Color.accentCyan)
            }
        }
        .navigationTitle(viewModel.workout?.title ?? "Workout")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    viewModel.showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(Color.statusError)
                }
            }
        }
        .alert("Delete Workout?", isPresented: $viewModel.showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    await viewModel.deleteWorkout(workoutId: workoutId)
                    dismiss()
                }
            }
        } message: {
            Text("This action cannot be undone.")
        }
        .fullScreenCover(item: $activeSession) { session in
            // Phase 2.6 v1.6.1 fix: pull the workoutSetId from
            // the timing prefill (built from the picked set) and
            // pass it explicitly to TimingView. The prefill path
            // still works (TimingView.onAppear reads it), but
            // the explicit param is the cleaner source of truth.
            TimingView(
                prefill: timingPrefill,
                sessionId: session.id,
                workoutSetId: timingPrefill?.workoutSetId
            )
        }
        .navigationDestination(isPresented: $navigateToBuilder) {
            WorkoutBuilderView(workoutId: workoutId)
        }
        .sheet(isPresented: $showSessionStart) {
            SessionStartView(
                sessionId: pendingSessionId,
                workoutSets: viewModel.sets,
                // Phase 2.6 v1.6.1 fix: onComplete now passes
                // both the sessionId and the picked workoutSetId.
                // The picked set comes from SessionStartView's
                // previewSetIndex at Start time.
                onComplete: { sessionId, workoutSetId in
                    showSessionStart = false
                    activeSession = ActiveSession(
                        id: sessionId,
                        workoutSetId: workoutSetId
                    )
                }
            )
        }
        .task {
            await viewModel.loadWorkout(workoutId: workoutId)
        }
    }

    // Per-set start buttons — inline in the sets list
    private var setsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SETS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color.textFaint)
                .tracking(1.5)
                .padding(.horizontal, 16)

            if viewModel.sets.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle.portrait")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No sets in this workout")
                        .font(.headline)
                    Text("Open in the workout builder to add sets.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            }

            ForEach(viewModel.sets) { set in
                setRow(set)
            }
        }
    }

    private func setRow(_ set: WorkoutSet) -> some View {
        let prefill = SetPrefill(
            stroke: set.stroke ?? "Free",
            distance: set.distance ?? 50,
            reps: set.reps,
            interval: set.intervalText,
            intensityLabel: set.intensityLabel,
            workoutSetId: set.id
        )
        let isTimeable = set.distance != nil && set.distance! > 0

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                timingPrefill = prefill
                pendingSessionId = UUID().uuidString
                showSessionStart = true
            } label: {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(set.label)
                            .font(.bodyEmphasis)
                            .foregroundColor(Color.textPrimary)
                            .multilineTextAlignment(.leading)

                        HStack(spacing: 8) {
                            if let gear = set.gear {
                                Text(gear)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(Color.accentCyan)
                            }
                            if let intensity = set.intensityLabel {
                                Text(intensity)
                                    .font(.system(size: 11))
                                    .foregroundColor(Color.accentAmber)
                            }
                        }
                    }

                    Spacer()

                    if isTimeable {
                        Image(systemName: "play.fill")
                            .font(.system(size: 12))
                            .foregroundColor(Color.accentCyan)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(isTimeable ? Color.clear : Color.clear)
            }
            .disabled(!isTimeable)
            .opacity(isTimeable ? 1 : 0.5)

            Divider()
                .background(Color.bgInset)
                .padding(.leading, 16)
        }
    }

    private func metadataSection(workout: Workout) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(workout.title ?? "Untitled")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(Color.textPrimary)

            HStack(spacing: 8) {
                if let scheduledAt = workout.scheduledAt {
                    Text(formatDate(scheduledAt))
                        .font(.system(size: 12))
                        .foregroundColor(Color.textFaint)
                }

                if let amPm = workout.amPm {
                    Text("·")
                        .foregroundColor(Color.textFaint)
                    Text(amPm)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color.accentAmber)
                }

                Text("·")
                    .foregroundColor(Color.textFaint)
                Text(workout.status.rawValue.capitalized)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(statusColor(workout.status))
            }
        }
        .padding(.horizontal, 16)
    }

    private func actionButtons(workout: Workout) -> some View {
        VStack(spacing: 12) {
            if workout.status == .draft || workout.status == .scheduled {
                Button("Edit Workout") {
                    navigateToBuilder = true
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Color.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(Color.bgSunken)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.divider, lineWidth: 1)
                )
            }

            if workout.status == .inProgress {
                Button("Mark Complete") {
                    Task { await viewModel.markComplete(workoutId: workoutId) }
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Color.statusSuccess)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(Color.bgSunken)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.statusSuccess.opacity(0.3), lineWidth: 1)
                )
            }
        }
        .padding(.horizontal, 16)
    }

    private func buildParsedWorkout(from workout: Workout, sets: [WorkoutSet]) -> ParsedWorkout {
        ParsedWorkout(
            title: workout.title,
            sections: [
                ParsedSection(
                    title: nil,
                    namedSets: [
                        ParsedNamedSet(
                            label: nil,
                            note: nil,
                            repGroups: sets.map { set in
                                ParsedRepGroup(
                                    reps: set.reps,
                                    distance: set.distance,
                                    stroke: set.stroke,
                                    interval: set.intervalText,
                                    intensity: set.intensityLabel.map {
                                        ParsedIntensity(
                                            type: ParsedIntensityType(rawValue: set.intensityType ?? "easy") ?? .easy,
                                            label: $0
                                        )
                                    },
                                    pacing: nil,
                                    pattern: [],
                                    patternType: nil,
                                    connectors: nil,
                                    note: nil,
                                    gear: set.gear.map { [$0] },
                                    gearOptional: false,
                                    descend: nil,
                                    details: nil
                                )
                            }
                        )
                    ]
                )
            ]
        )
    }

    private func formatDate(_ dateStr: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: dateStr + "T00:00:00Z") ?? formatter.date(from: dateStr) ?? Date()
        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "EEE MMM d"
        return displayFormatter.string(from: date).uppercased()
    }

    private func statusColor(_ status: WorkoutStatus) -> Color {
        switch status {
        case .draft: return Color.accentAmber
        case .scheduled: return Color.accentCyan
        case .inProgress: return Color.accentCyan
        case .complete: return Color.statusSuccess
        }
    }
}

#Preview {
    NavigationStack {
        WorkoutDetailView(workoutId: "test-id")
    }
    .environment(AuthManager())
}