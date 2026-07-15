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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool
    @StateObject private var viewModel = WorkoutsListViewModel()
    // ponytail (warmth-through-motion iter 4): on-appear reveal.
    // Same pattern as login reveal (d46c444), today reveal (0a90257),
    // and swimmers migration (61404f1). When Workouts tab is selected,
    // the list fades + scales in over Animations.springSoft, gated by
    // Reduce Motion for a11y.
    @State private var animateIn: Bool = false

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
                            .font(.captionStrong)
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
        // ponytail: worklist fade-in on tab appear. ScrollView is the
        // outer container; gating by reduceMotion is the standard a11y
        // pattern (matches d46c444, 0a90257, 61404f1).
        .opacity(animateIn ? 1.0 : 0.0)
        .scaleEffect(animateIn ? 1.0 : 0.98)
        .animation(reduceMotion ? nil : Animations.springSoft, value: animateIn)
        .onAppear { animateIn = true }
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
                                .padding(.vertical, 6)
                        }
                        .listRowBackground(Color.bgBase)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task { await viewModel.deleteWorkout(id: workout.id) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    // ponytail: format the dateKey ('yyyy-MM-dd') into
                    // 'Tuesday, May 12' instead of dumping the raw ISO
                    // string. Old UI literally showed '2026-05-12' at the
                    // top of the list — looked like a debug timestamp.
                    Text(formatDateKey(dateKey))
                        .font(.eyebrow)
                        .foregroundColor(Color.textMuted)
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

    private func formatDateKey(_ key: String) -> String {
        // Format 'yyyy-MM-dd' key back into a human date. Falls back to
        // the raw key if parsing fails (the 'UNSCHEDULED' group also
        // routes here).
        guard key != "UNSCHEDULED" else { return "UNSCHEDULED" }
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.timeZone = TimeZone(identifier: "UTC")
        guard let date = parser.date(from: key) else { return key }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d"
        let now = Date()
        let calendar = Calendar.current
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) {
            formatter.dateFormat = "EEEE, MMMM d, yyyy"
        }
        return formatter.string(from: date)
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
        // ponytail: card surface — raised background, rounded corners,
        // subtle hairline ring. Matches the Workouts surface identity
        // (cards on a dark surface, not raw text floating on screen).
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                // ponytail: per-row date label REMOVED. The Section header
                // (formatted via formatDateKey) already shows the date;
                // duplicating it here was visual noise.

                Text(workout.title ?? "Untitled")
                    .font(.titleSmall)
                    .foregroundColor(Color.textPrimary)

                Text(statusLabel)
                    .font(.numericSmall)
                    .foregroundColor(statusColor)
            }

            Spacer()

            if let amPm = workout.amPm {
                Text(amPm)
                    .font(.numericSmall)
                    .foregroundColor(Color.accentAmber)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentAmber.opacity(0.15))
                    .cornerRadius(4)
            }

            // ponytail: chevron via SF Symbol instead of raw '>' text.
            // Smaller, tighter weight, brand-consistent (textFaint).
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color.textFaint)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .background(Color.bgRaised)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.divider, lineWidth: 1)
        )
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