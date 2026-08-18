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

    func archiveWorkout(id: String) async {
        do {
            try await workoutService.archiveWorkout(workoutId: id)
            workouts.removeAll { $0.id == id }
        } catch {
            errorMessage = "Couldn't archive workout."
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
struct WorkoutRowData: Identifiable, Equatable {
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
                        // Micro-interaction: selection haptic on filter
                        // change. Pairs with the .animation on the
                        // pill's foreground/background so the swap
                        // has a consistent tactile + visual feel.
                        Haptics.selection()
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
                            // Animate the foreground + background swap
                            // when the selected filter changes, so the
                            // pill "morphs" into the selected state
                            // instead of jumping.
                            .animation(Animations.snap, value: viewModel.selectedFilter)
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
                    Text(emptyStateMessage)
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
                        // V0.44 Slice 3 (2026-08-18): tell 8 — micro-
                        // interaction gap. NavigationLink doesn't take
                        // an action closure, so we add a simultaneous
                        // tap gesture purely for the haptic. The visual
                        // press feedback is already handled by the
                        // system's NavigationLink affordance (chevron +
                        // highlight); this just adds the tactile "I
                        // tapped a thing" tap that filter pills already
                        // use via Haptics.selection(). Light tap, no
                        // reduceMotion gate — haptics aren't motion.
                        .simultaneousGesture(
                            TapGesture().onEnded { Haptics.tap() }
                        )
                        .listRowBackground(Color.bgBase)
                        // V0.44 Slice 2 (2026-08-18): tell 5 — uniform
                        // spacing, no rhythm. Bumped the vertical
                        // insets 4 → 8 so the per-section gap lands
                        // on a 4pt grid (8 = 2 × 4) and gives sections
                        // breathing room. Leading / trailing stay at
                        // 16 (matches the screen's outer margin from
                        // the filter pills row).
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button {
                                Task { await viewModel.archiveWorkout(id: workout.id) }
                            } label: {
                                Label("Archive", systemImage: "archivebox")
                            }
                            .tint(Color.accentAmber)
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
        // V0.44 Slice 3 (2026-08-18): tell 8 — row enter/exit. Animate
        // the workouts array so inserts (initial load, refresh) and
        // removes (archive swipe) settle in with Animations.springSoft
        // — no overshoot, "settle without bounce." springSoft matches
        // the spec table's "section expand = springSoft" feel: rows
        // should look like they're arriving, not popping. WorkoutRowData
        // is Equatable so the .animation(value:) works; gated by
        // reduceMotion (a11y standard pattern, matches the on-appear
        // reveal above).
        .animation(reduceMotion ? nil : Animations.springSoft, value: viewModel.workouts)
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

    private var emptyStateMessage: String {
        switch viewModel.selectedFilter {
        case .all: return "No workouts yet — plan a session."
        case .scheduled, .draft, .complete:
            return "No \(emptyStateLabel) workouts here."
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
        // V0.44 Slice 2 (2026-08-18): leading status dot. Tells 6 in
        // the spec — "no color meaning for status" — was that draft /
        // scheduled / complete were text-only. A 6pt filled circle at
        // the leading edge (iOS-native list pattern, à la Mail /
        // Reminders) gives the status a glance-readable color without
        // crowding the title or status label. The dot reuses the
        // existing `statusColor` computed property so dot + label
        // stay coherent: same token, same color, same status.
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)

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
        // V0.44 Slice 2 (2026-08-18): draft re-mapped from accentAmber
        // to textFaint. Tell 6 in the spec — "no color meaning for
        // status" — listed draft as textFaint. Amber was reading
        // "warning / needs attention" which isn't what a draft is;
        // a draft is "not yet active" — quiet. textFaint says that.
        // The status label text also picks up this color via the
        // `.foregroundColor(statusColor)` on the Text above, so the
        // dot and the label stay in sync (a textFaint dot + amber
        // label would have been incoherent). inProgress is kept on
        // accentCyan — it's an active state and cyan is the brand
        // active color, even though inProgress isn't in the spec's
        // dot list (the spec only enumerates draft / scheduled /
        // complete).
        switch workout.status {
        case .draft: return Color.textFaint
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