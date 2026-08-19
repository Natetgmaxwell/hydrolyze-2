import SwiftUI

/// SwimmersListView — roster tab with group sections, filter pills, and add/edit/archive actions.
/// Replaces the "Coming soon" placeholder from the initial scaffold.
struct SwimmersListView: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool
    @StateObject private var viewModel = SwimmersListViewModel()
    @State private var showAddSheet = false
    @State private var swimmerToEdit: Swimmer?
    @State private var showDeleteAlert = false
    @State private var swimmerToDelete: Swimmer?
    @State private var showArchiveAlert = false
    @State private var swimmerToArchive: Swimmer?
    @State private var newGroupName = ""
    @State private var showAddGroupRow = false
    @State private var showSquadManagement = false
    @State private var swimmerToMove: Swimmer? = nil
    @State private var showMovePicker = false
    // ponytail (warmth-through-motion iter 5): on-appear reveal.
    // Same pattern as login reveal (d46c444), today reveal (0a90257),
    // workouts reveal (06c6823), and swimmers migration (61404f1).
    // When the Swimmers tab is selected, the inner VStack fades +
    // scales in over Animations.springSoft, gated by Reduce Motion
    // for a11y.
    @State private var animateIn: Bool = false

    private var coachId: String? {
        authManager.coachId
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bgBase.ignoresSafeArea()

                VStack(spacing: 0) {
                    filterPills
                    swimmersList
                }
                // ponytail: swimmers fade-in on tab appear. Gating by
                // reduceMotion is the standard a11y pattern (matches
                // d46c444, 0a90257, 06c6823, 61404f1).
                .opacity(animateIn ? 1.0 : 0.0)
                .scaleEffect(animateIn ? 1.0 : 0.98)
                .animation(reduceMotion ? nil : Animations.springSoft, value: animateIn)
                .onAppear { animateIn = true }
            }
            .navigationTitle("SWIMMERS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.action()
                        showSquadManagement = true
                    } label: {
                        Image(systemName: "person.2.crop.square.stack")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Color.textMuted)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.action()
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Color.accentAction)
                    }
                }
            }
            .sheet(isPresented: $showSquadManagement) {
                SquadManagementView()
            }
            .sheet(isPresented: $showAddSheet) {
                SwimmerSheetView(swimmerId: nil, onSave: {
                    Task { await viewModel.loadSwimmers(coachId: coachId) }
                })
            }
            .sheet(item: $swimmerToEdit) { swimmer in
                SwimmerSheetView(swimmerId: swimmer.id, onSave: {
                    Task { await viewModel.loadSwimmers(coachId: coachId) }
                })
            }
            .alert("Delete Swimmer?", isPresented: $showDeleteAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    if let s = swimmerToDelete {
                        Task {
                            await viewModel.deleteSwimmer(id: s.id)
                        }
                    }
                }
            } message: {
                Text("This will permanently delete \(swimmerToDelete?.fullName ?? "this swimmer") and all their recorded times. This cannot be undone.")
            }
            .alert("Archive Swimmer?", isPresented: $showArchiveAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Archive", role: .destructive) {
                    if let s = swimmerToArchive {
                        Task {
                            await viewModel.archiveSwimmer(id: s.id)
                        }
                    }
                }
            } message: {
                Text("\(swimmerToArchive?.fullName ?? "This swimmer") will be hidden from the active roster but can be restored from Archived.")
            }
            .task {
                #if DEBUG
                // V0.46 Slice 5: screenshot harness — seed the roster;
                // no network in the demo path.
                if ProcessInfo.processInfo.arguments.contains("-v46-demo-swimmers") {
                    viewModel.seedV46DemoRoster()
                    return
                }
                #endif
                await viewModel.loadSwimmers(coachId: coachId)
            }
            // PHASE 2.8.6: re-trigger loadSwimmers when authManager.coachId
            // transitions from nil → non-nil. Without this, the .task
            // above fires once when the view appears, captures coachId
            // = nil (because AuthManager.checkExistingSession hasn't
            // finished resolving yet), loadSwimmers early-returns
            // silently, and the roster stays empty even after sign-in
            // completes. The pull-to-refresh at L82-84 only "fixes" it
            // by manually re-running the load with a fresh coachId.
            .onChange(of: authManager.coachId) { _, newCoachId in
                guard let newCoachId = newCoachId else { return }
                Task { await viewModel.loadSwimmers(coachId: newCoachId) }
            }
            .refreshable {
                await viewModel.loadSwimmers(coachId: coachId)
            }
            // V0.46 Slice 4: pull-to-refresh reads fog — teal-family
            // chrome, coral reserved for CTAs.
            .tint(Color.textMuted)
        }
        .sheet(item: $swimmerToMove) { swimmer in
            MoveSwimmerSheet(swimmer: swimmer, viewModel: viewModel)
        }
    }

    /// Sheet for moving a swimmer between squads.
    private var filterPills: some View {
        HStack(spacing: 8) {
            ForEach(SwimmerFilter.allCases, id: \.self) { filter in
                Button {
                    // Micro-interaction: selection haptic on filter
                    // change. Pairs with the .animation on the
                    // pill's foreground/background so the swap
                    // has a consistent tactile + visual feel.
                    Haptics.selection()
                    viewModel.selectedFilter = filter
                    Task { await viewModel.loadSwimmers(coachId: coachId) }
                } label: {
                    Text(filter.rawValue)
                        .font(.captionStrong)
                        .foregroundColor(
                            viewModel.selectedFilter == filter
                            ? Color.textPrimary
                            : Color.textMuted
                        )
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            viewModel.selectedFilter == filter
                            ? Color.bgSelected
                            : Color.bgInset
                        )
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(
                                    viewModel.selectedFilter == filter ? Color.textMuted : Color.divider,
                                    lineWidth: 1
                                )
                        )
                        // Animate the foreground + background swap
                        // when the selected filter changes, so the
                        // pill "morphs" into the selected state
                        // instead of jumping.
                        .animation(Animations.snap, value: viewModel.selectedFilter)
                }
                .buttonStyle(PressFeedbackStyle(scale: 0.95, dim: 0.85))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var swimmersList: some View {
        ScrollView {
            // V0.44 Slice 3 (2026-08-18): tell 8 — row enter/exit.
            // Animate the row count so inserts (initial load, refresh,
            // filter change) and removes (archive swipe) settle in
            // with Animations.springSoft — "settle without bounce"
            // matches the spec table's "section expand = springSoft"
            // feel. Swimmer is Codable + Identifiable but not
            // Equatable, so we drive the .animation(value:) off a
            // stable scalar: filteredSwimmers.count. This covers all
            // three triggers above (load → 0→N, filter → N→M,
            // archive → M→M-1). Gated by reduceMotion per the
            // standard a11y pattern.
            LazyVStack(spacing: 0) {
                if viewModel.isLoading && viewModel.allSwimmers.isEmpty {
                    ProgressView()
                        .tint(Color.textMuted)
                        .padding(.top, 40)
                } else if viewModel.allSwimmers.isEmpty, let errorMessage = viewModel.errorMessage {
                    errorState(errorMessage)
                } else if viewModel.filteredSwimmers.isEmpty {
                    emptyState
                } else {
                    // Grouped sections
                    ForEach(viewModel.groupsWithSwimmers, id: \.group.id) { item in
                        Section {
                            ForEach(item.swimmers) { swimmer in
                                swimmerRow(swimmer)
                            }
                        } header: {
                            groupHeader(name: item.group.name, count: item.swimmers.count, onDelete: {
                                Task { await viewModel.deleteGroup(groupId: item.group.id) }
                            })
                        }
                    }
                    // "No Group" section — always last
                    if !viewModel.noGroupSwimmers.isEmpty {
                        Section {
                            ForEach(viewModel.noGroupSwimmers) { swimmer in
                                swimmerRow(swimmer)
                            }
                        } header: {
                            // V0.44 Slice 1 (2026-08-18): the "No
                            // group" fallback is a system label, not
                            // a coach-named group — render in sentence
                            // case (skip groupHeader's .uppercased()).
                            groupHeader(name: "No group", count: viewModel.noGroupSwimmers.count, onDelete: nil, uppercased: false)
                        }
                    }
                }
            }
            .padding(.bottom, 40)
            .animation(reduceMotion ? nil : Animations.springSoft, value: viewModel.filteredSwimmers.count)
        }
    }

    // Individual swimmer row with swipe and long-press
    private func swimmerRow(_ swimmer: Swimmer) -> some View {
        NavigationLink(destination: SwimmerDetailView(swimmerId: swimmer.id)) {
            SwimmerRow(swimmer: swimmer, onDelete: {}, onArchive: {})
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .contextMenu {
            Button {
                Haptics.tap()
                swimmerToMove = swimmer
                showMovePicker = true
            } label: {
                Label("Move to squad", systemImage: "arrow.right.square")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                Haptics.heavy()
                swimmerToArchive = swimmer
                showArchiveAlert = true
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .tint(Color.accentAmber)
        }
        // Long-press = delete. Haptics.heavy() for destructive
        // symmetry with the swipe action.
        .onLongPressGesture {
            Haptics.heavy()
            swimmerToDelete = swimmer
            showDeleteAlert = true
        }
    }

    // Group header row: name + count + optional delete.
    // V0.44 Slice 1 (2026-08-18): added `uppercased:` flag so the
    // "No group" system-label fallback can render in sentence case
    // instead of going through `.uppercased()`. Coach-named groups
    // (data) stay uppercase by default — this just lets the one
    // system-label call site opt out.
    private func groupHeader(name: String, count: Int, onDelete: (() -> Void)?, uppercased: Bool = true) -> some View {
        HStack {
            Text(uppercased ? name.uppercased() : name)
                .font(.eyebrow)
                .foregroundColor(Color.textMuted)
            Text("\(count)")
                .font(.eyebrow)
                .foregroundColor(Color.textMuted)
            Spacer()
            if let onDelete = onDelete {
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(Color.textFaint)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.bgBase)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            // V0.46 Slice 4: static icon — breathing is idle-CTA-only
            // (an empty state carries no state; motion here was
            // ornamental). See [[concepts/warmth-through-motion]].
            Image(systemName: "person.fill")
                .font(.system(size: 48))
                .foregroundColor(Color.textFaint)

            Text("The roster's empty.")
                .font(.body)
                .foregroundColor(Color.textMuted)

            Text("Tap + to add your first swimmer.")
                .font(.caption)
                .foregroundColor(Color.textFaint)
        }
        .padding(.top, 80)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundColor(Color.accentAmber)

            Text("Couldn't load swimmers")
                .font(.body)
                .foregroundColor(Color.textMuted)

            Text(message)
                .font(.caption)
                .foregroundColor(Color.textFaint)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button("Retry") {
                Task { await viewModel.loadSwimmers(coachId: coachId) }
            }
            .font(.caption)
            .foregroundColor(Color.textMuted)
            .padding(.top, 8)
        }
        .padding(.top, 80)
    }
}

// MARK: - MoveSwimmerSheet

/// Sheet for moving a swimmer to a different squad.
private struct MoveSwimmerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let swimmer: Swimmer
    @ObservedObject var viewModel: SwimmersListViewModel

    @State private var selectedGroupId: String? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bgBase.ignoresSafeArea()
                List {
                    Section {
                        Button {
                            selectedGroupId = nil
                        } label: {
                            HStack {
                                Text("No Squad")
                                    .foregroundColor(Color.textPrimary)
                                Spacer()
                                if selectedGroupId == nil {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(Color.textPrimary)
                                }
                            }
                        }

                        ForEach(viewModel.groups) { group in
                            Button {
                                selectedGroupId = group.id
                            } label: {
                                HStack {
                                    Text(group.name)
                                        .foregroundColor(Color.textPrimary)
                                    Spacer()
                                    if selectedGroupId == group.id {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(Color.textPrimary)
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .background(Color.bgBase)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Move to Squad")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(Color.textPrimary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Move") {
                        Task {
                            await viewModel.moveSwimmer(swimmerId: swimmer.id, toGroupId: selectedGroupId)
                            dismiss()
                        }
                    }
                    .foregroundColor(Color.textPrimary)
                }
            }
            .task {
                // Pre-select the swimmer's current group (single-squad model).
                selectedGroupId = viewModel.groupsWithSwimmers
                    .first { $0.swimmers.contains(where: { $0.id == swimmer.id }) }?
                    .group.id
            }
        }
    }
}

#Preview {
    SwimmersListView()
        .environment(AuthManager())
}
