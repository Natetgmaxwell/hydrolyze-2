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

    #if DEBUG
    /// V0.46 Slice 5: screenshot-harness seed. Three statuses across
    /// two weeks plus a 3MT template row — the list's real shape.
    /// Network is never touched.
    func seedV46DemoWorkouts() {
        let fmt = ISO8601DateFormatter()
        let cal = Calendar.current
        func day(_ offset: Int) -> String { fmt.string(from: cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: Date()))!) }
        func row(_ id: String, _ title: String, _ status: WorkoutStatus, _ dayOffset: Int, amPm: String? = "am", sessionType: String? = nil) -> WorkoutRowData {
            WorkoutRowData(from: Workout(
                id: id,
                coachId: "v46-demo-coach",
                title: title,
                description: nil,
                scheduledAt: day(dayOffset),
                amPm: amPm,
                completedAt: nil,
                status: status,
                createdAt: day(dayOffset),
                updatedAt: nil,
                sessionType: sessionType
            ))
        }
        workouts = [
            row("v46-w-today", "Threshold Tuesday", .scheduled, 0),
            row("v46-w-3mt", "3MT test", .scheduled, 1, sessionType: "3mt"),
            row("v46-w-thu", "Sprint pyramid", .scheduled, 2),
            row("v46-w-next", "Aerobic base", .scheduled, 7),
            row("v46-w-done", "IM mixer", .complete, -3),
            row("v46-w-draft", "Saturday long", .draft, 4),
        ]
        selectedFilter = .all
        isLoading = false
        errorMessage = nil
    }
    #endif

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
    /// V0.45 (2026-08-18): session template tag (e.g. "3mt"). Nil
    /// for non-template rows — the row view checks for the literal
    /// "3mt" before rendering the badge so other future templates
    /// can opt in cleanly.
    let sessionType: String?

    init(from workout: Workout) {
        self.id = workout.id
        self.title = workout.title
        self.status = workout.status
        self.amPm = workout.amPm
        self.sessionType = workout.sessionType
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
    // V0.45 (2026-08-18): template entry point state. The "3MT test"
    // menu item creates a draft workout with sessionType="3mt" and
    // presents the builder pre-loaded so the coach can edit before
    // saving. The id is kept here (not the viewModel) because it's a
    // transient UI concern — the row doesn't refresh from the builder
    // unless the coach explicitly navigates back.
    @State private var templateWorkoutId: String?
    @State private var showTemplateBuilder: Bool = false

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
                    // V0.45 (2026-08-18): the "+ New" pill is now a
                    // Menu with two entries — "New workout" (plain
                    // builder) and "3MT test" (creates a draft tagged
                    // session_type="3mt" and opens the builder on it
                    // so the coach edits before saving). The pill
                    // styling stays identical to the previous version:
                    // accentAction background, black captionStrong text,
                    // 8pt corner radius.
                    Menu {
                        // Plain new builder — NavigationLink inside
                        // Menu pushes onto the enclosing NavigationStack,
                        // matching the toolbar's previous behavior.
                        NavigationLink(destination: WorkoutBuilderView(workoutId: nil)) {
                            Label("New workout", systemImage: "square.and.pencil")
                        }

                        Button {
                            Task { await create3MTTemplateWorkout() }
                        } label: {
                            Label("3MT test", systemImage: "stopwatch")
                        }
                    } label: {
                        Text("+ New")
                            .font(.captionStrong)
                            .foregroundColor(Color.textOnAccent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.accentAction)
                            .cornerRadius(8)
                    }
                }
            }
        }
        .task {
            viewModel.selectedFilter = .all
            #if DEBUG
            // V0.46 Slice 5: screenshot harness — seed the list; no
            // network in the demo path.
            if ProcessInfo.processInfo.arguments.contains("-v46-demo-workouts") {
                viewModel.seedV46DemoWorkouts()
                return
            }
            #endif
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
        // V0.45 (2026-08-18): present the builder as a sheet for the
        // 3MT template path. The builder wraps itself in its own
        // NavigationStack, so nesting under another NavigationStack
        // (the worklist's outer one) is fine — but a sheet avoids the
        // nested-NavigationStack churn entirely and matches how
        // WorkoutBuilderView already presents SetScheduleView.
        .sheet(isPresented: $showTemplateBuilder) {
            if let id = templateWorkoutId {
                WorkoutBuilderView(workoutId: id)
            }
        }
    }

    /// V0.45 (2026-08-18): create a draft workout tagged as the 3MT
    /// template, then open the builder on it so the coach edits before
    /// saving. Guarded by coachId (auth) and wrapped in Task — a
    /// failed create sets viewModel.errorMessage (same channel the
    /// list load uses) and never crashes the view.
    private func create3MTTemplateWorkout() async {
        guard let coachId = authManager.coachId else {
            viewModel.errorMessage = "Couldn't start 3MT test — no coach id."
            return
        }
        let service = WorkoutService()
        do {
            let created = try await service.createWorkout(
                coachId: coachId,
                title: "3MT — 3-minute all-out test",
                // FIX (2026-08-19): description maps to workout_text
                // (same column as workoutText) — passing both would
                // emit duplicate keys and the notes would clobber the
                // canonical parse text in the builder. The canonical
                // text is what must be parsed; the coach edits in the
                // builder. Notes have no column of their own.
                description: nil,
                workoutText: "3MT: 3 min all-out, 25m splits, Free",
                sessionType: "3mt"
            )
            // FIX (2026-08-20): persist the 3MT set immediately so the
            // draft is not empty. The template previously created only the
            // workouts row — no workout_sets row — so opening the draft from
            // the list showed "No sets in this workout" until the coach
            // manually Saved in the builder. Parse the canonical text and
            // write the set(s) now, exactly as the builder's save path does.
            // The coach can still edit in the builder; the set just exists
            // from the start.
            let parsed = WorkoutParser.parse("3MT: 3 min all-out, 25m splits, Free")
            if !parsed.sections.isEmpty {
                try await service.createSetsForWorkout(workoutId: created.id, from: parsed)
            }
            templateWorkoutId = created.id
            showTemplateBuilder = true
        } catch {
            print("[WorkoutsListView] 3MT template create failed: \(error)")
            viewModel.errorMessage = "Couldn't start 3MT test: \(error.localizedDescription)"
        }
    }

    private var filterPills: some View {
        // V0.52.6 (2026-09-26): de-chrome — swap the custom horizontal
        // pill bar for a native segmented Picker. The segmented control
        // is iOS-canonical, has its own selection state + animation,
        // respects Dynamic Type, and eliminates 40+ lines of bespoke
        // stroke/background chrome. The haptics.onChange fires after
        // the binding settles, matching the previous tactile feel.
        Picker("Filter workouts", selection: $viewModel.selectedFilter) {
            ForEach(WorkoutFilter.allCases, id: \.self) { filter in
                Text(filter.rawValue.capitalized)
                    .tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .onChange(of: viewModel.selectedFilter) { _, _ in
            Haptics.selection()
        }
    }

    private var workoutList: some View {
        List {
            // V0.55 (2026-09-12): signed in but AuthManager hasn't resolved
            // the coach row yet. Show the retry state instead of the
            // misleading "No workouts yet — plan a session." empty (which
            // is reserved for genuinely-empty rosters).
            if authManager.coachId == nil && !viewModel.isLoading {
                VStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark.fill")
                        .font(.system(size: 40))
                        .foregroundColor(Color.accentAmber)
                    Text("Couldn't load your account")
                        .font(.body)
                        .foregroundColor(Color.textMuted)
                    Button("Retry") {
                        Task { await authManager.retryResolveCoach() }
                    }
                    .font(.caption)
                    .foregroundColor(Color.textMuted)
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
                .listRowBackground(Color.bgBase)
            } else if viewModel.workouts.isEmpty && !viewModel.isLoading {
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
                        // V0.54 (2026-09-08): status-branched entry. Per
                        // decision 15, the Console is the entry for
                        // `.scheduled` / `.inProgress`; `.draft` and
                        // `.complete` keep `WorkoutDetailView` (the
                        // post-session review path). A draft has no
                        // timing yet; a complete one is read-only.
                        NavigationLink(destination: destinationView(for: workout)) {
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
                        // FIX (2026-08-19): the simultaneous TapGesture
                        // swallowed the link's activation — haptic fired,
                        // navigation didn't. The tap is the contract;
                        // the haptic is decoration. Removed.
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

    /// V0.54 (2026-09-08): status-branched destination. `.scheduled` and
    /// `.inProgress` open the Console (coach is going to time it);
    /// `.draft` and `.complete` open `WorkoutDetailView` (drafts need
    /// editing, completes are review-only). Spec decision 15.
    @ViewBuilder
    private func destinationView(for workout: WorkoutRowData) -> some View {
        switch workout.status {
        case .scheduled, .inProgress:
            SessionConsoleView(workoutId: workout.id)
        case .draft, .complete:
            WorkoutDetailView(workoutId: workout.id)
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

            // V0.45 (2026-08-18): 3MT session tag. Renders a small
            // "3MT" badge next to the title when the workout was
            // created from the template entry point (session_type =
            // "3mt" in the DB). Mono-styled to read as a label, not
            // body text; textMuted on bgInset keeps it a quiet data
            // badge that doesn't compete with the status dot/label
            // or the coral "+ New" CTA.
            if workout.sessionType == "3mt" {
                Text("3MT")
                    .font(.jetBrainsMono(size: 11, weight: .bold))
                    .foregroundColor(Color.textMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.bgInset)
                    .cornerRadius(4)
            }

            Spacer()
        }
        .padding(.vertical, 12)
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
        // label would have been incoherent). V0.46 Slice 4: coral is
        // CTA-only — status wayfinding reads: draft textFaint (not
        // yet active), scheduled textMuted, inProgress accentAmber
        // (live — amber is the live/warning family), complete
        // statusSuccess. Zero coral in status.
        switch workout.status {
        case .draft: return Color.textFaint
        case .scheduled: return Color.textMuted
        case .inProgress: return Color.accentAmber
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