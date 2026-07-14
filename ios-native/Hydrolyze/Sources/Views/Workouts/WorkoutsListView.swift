import SwiftUI

@MainActor
final class WorkoutsListViewModel: ObservableObject {
    @Published var workouts: [WorkoutRowData] = []
    @Published var selectedFilter: WorkoutFilter = .all
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    private let workoutService = WorkoutService()

    func loadWorkouts(coachId: String?) async {
        guard let coachId = coachId else { return }
        isLoading = true
        errorMessage = nil

        do {
            let allWorkouts = try await workoutService.fetchWorkouts(coachId: coachId)

            if selectedFilter == .all {
                workouts = allWorkouts.map { WorkoutRowData(from: $0) }
            } else {
                let statusValue = filterStatusValue(selectedFilter)
                workouts = allWorkouts
                    .filter { $0.status.rawValue == statusValue }
                    .map { WorkoutRowData(from: $0) }
            }
        } catch {
            print("[WorkoutsListViewModel] Error loading workouts: \(error)")
            errorMessage = "Couldn't load workouts: \(error.localizedDescription)"
        }

        isLoading = false
    }

    func deleteWorkout(id: String) async {
        do {
            try await workoutService.deleteWorkout(workoutId: id)
            workouts.removeAll { $0.id == id }
        } catch {
            errorMessage = "Couldn't delete workout."
        }
    }

    private func filterStatusValue(_ filter: WorkoutFilter) -> String {
        switch filter {
        case .all: return ""
        case .scheduled: return "scheduled"
        case .draft: return "draft"
        case .complete: return "complete"
        }
    }
}

/// Lightweight row data type — mirrors the RN's WorkoutRow interface.
struct WorkoutRowData: Identifiable {
    let id: String
    let title: String?
    let status: WorkoutStatus
    let scheduledAt: Date?
    let amPm: String?

    init(from workout: Workout) {
        self.id = workout.id
        self.title = workout.title
        self.status = workout.status
        self.amPm = workout.amPm
        if let s = workout.scheduledAt {
            let formatter = ISO8601DateFormatter()
            self.scheduledAt = formatter.date(from: s + "T00:00:00Z")
        } else {
            self.scheduledAt = nil
        }
    }
}

/// WorkoutsListView — all workouts for the coach, grouped by date, filterable.
struct WorkoutsListView: View {
    @Environment(AuthManager.self) private var authManager
    @StateObject private var viewModel = WorkoutsListViewModel()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bgBase.ignoresSafeArea()

                VStack(spacing: 0) {
                    filterPills
                    workoutList
                }
            }
            .navigationTitle("WORKOUTS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(destination: WorkoutBuilderView(workoutId: nil)) {
                        Text("+ New")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.accentCyan)
                            .cornerRadius(8)
                    }
                }
            }
        }
        .task {
            viewModel.selectedFilter = .all
            await viewModel.loadWorkouts(coachId: authManager.coachId)
        }
        .onChange(of: viewModel.selectedFilter) { _, _ in
            Task { await viewModel.loadWorkouts(coachId: authManager.coachId) }
        }
    }

    private var filterPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(WorkoutFilter.allCases, id: \.self) { filter in
                    Button {
                        viewModel.selectedFilter = filter
                    } label: {
                        Text(filter.rawValue)
                            .font(.captionStrong)
                            .foregroundColor(viewModel.selectedFilter == filter ? Color.accentCyan : Color.textMuted)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                viewModel.selectedFilter == filter
                                    ? Color.accentCyan.opacity(0.15)
                                    : Color.bgInset
                            )
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(
                                        viewModel.selectedFilter == filter ? Color.accentCyan : Color.divider,
                                        lineWidth: 1
                                    )
                            )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color.bgBase)
    }

    private var workoutList: some View {
        List {
            if viewModel.workouts.isEmpty && !viewModel.isLoading {
                VStack(spacing: 8) {
                    Text("No \(emptyStateLabel) workouts")
                        .font(.body)
                        .foregroundColor(Color.textMuted)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
                .listRowBackground(Color.bgBase)
            }

            ForEach(groupedWorkouts.keys.sorted(by: { $0 > $1 }), id: \.self) { dateKey in
                Section {
                    ForEach(groupedWorkouts[dateKey] ?? []) { workout in
                        NavigationLink(destination: WorkoutDetailView(workoutId: workout.id)) {
                            WorkoutRowView(workout: workout, onDelete: {})
                        }
                        .listRowBackground(Color.bgSunken)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task { await viewModel.deleteWorkout(id: workout.id) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text(dateKey)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(Color.textFaint)
                        .tracking(0.5)
                }
            }
        }
        .listStyle(.plain)
        .redacted(reason: viewModel.isLoading && viewModel.workouts.isEmpty ? .placeholder : [])
        .refreshable {
            await viewModel.loadWorkouts(coachId: authManager.coachId)
        }
    }

    private var groupedWorkouts: [String: [WorkoutRowData]] {
        Dictionary(grouping: viewModel.workouts) { workout in
            if let date = workout.scheduledAt {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                return formatter.string(from: date)
            }
            return "UNSCHEDULED"
        }
    }

    private var emptyStateLabel: String {
        switch viewModel.selectedFilter {
        case .all: return ""
        case .scheduled: return "scheduled"
        case .draft: return "draft"
        case .complete: return "complete"
        }
    }
}

/// WorkoutRowView — standalone row (no NavigationLink inside, for use in List).
struct WorkoutRowView: View {
    let workout: WorkoutRowData
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                if let date = workout.scheduledAt {
                    Text(formatDate(date))
                        .font(.system(size: 11))
                        .foregroundColor(Color.textFaint)
                        .tracking(0.5)
                }

                Text(workout.title ?? "Untitled")
                    .font(.titleSmall)
                    .foregroundColor(Color.textPrimary)

                Text(statusLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(statusColor)
                    .tracking(0.5)
            }

            Spacer()

            if let amPm = workout.amPm {
                Text(amPm)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color.accentAmber)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentAmber.opacity(0.15))
                    .cornerRadius(4)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 4)
    }

    private var statusLabel: String {
        switch workout.status {
        case .draft: return "Draft"
        case .scheduled: return "Scheduled"
        case .inProgress: return "In Progress"
        case .complete: return "Complete"
        }
    }

    private var statusColor: Color {
        switch workout.status {
        case .draft: return Color.accentAmber
        case .scheduled: return Color.accentCyan
        case .inProgress: return Color.accentCyan
        case .complete: return Color.statusSuccess
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE MMM d"
        return formatter.string(from: date).uppercased()
    }
}

#Preview {
    WorkoutsListView()
        .environment(AuthManager())
}