import SwiftUI

/// SwimmersListView — roster tab with group sections, filter pills, and add/edit/archive actions.
/// Replaces the "Coming soon" placeholder from the initial scaffold.
struct SwimmersListView: View {
    @Environment(AuthManager.self) private var authManager
    @StateObject private var viewModel = SwimmersListViewModel()
    @State private var showAddSheet = false
    @State private var swimmerToEdit: Swimmer?
    @State private var showDeleteAlert = false
    @State private var swimmerToDelete: Swimmer?
    @State private var showArchiveAlert = false
    @State private var swimmerToArchive: Swimmer?
    @State private var newGroupName = ""
    @State private var showAddGroupRow = false

    private var coachId: String? {
        authManager.coachId
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "060e18").ignoresSafeArea()

                VStack(spacing: 0) {
                    filterPills
                    swimmersList
                }
            }
            .navigationTitle("SWIMMERS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Color(hex: "09d4ee"))
                    }
                }
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
                await viewModel.loadSwimmers(coachId: coachId)
            }
            .refreshable {
                await viewModel.loadSwimmers(coachId: coachId)
            }
        }
    }

    // Filter pills: Active / Archived
    private var filterPills: some View {
        HStack(spacing: 8) {
            ForEach(SwimmerFilter.allCases, id: \.self) { filter in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.selectedFilter = filter
                    }
                    Task { await viewModel.loadSwimmers(coachId: coachId) }
                } label: {
                    Text(filter.rawValue)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(
                            viewModel.selectedFilter == filter
                            ? Color(hex: "060e18")
                            : Color(hex: "7a9bb0")
                        )
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(
                            viewModel.selectedFilter == filter
                            ? Color(hex: "09d4ee")
                            : Color(hex: "1a2d42")
                        )
                        .cornerRadius(20)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var swimmersList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if viewModel.isLoading && viewModel.allSwimmers.isEmpty {
                    ProgressView()
                        .tint(Color(hex: "09d4ee"))
                        .padding(.top, 40)
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
                            groupHeader(name: "NO GROUP", count: viewModel.noGroupSwimmers.count, onDelete: nil)
                        }
                    }
                }
            }
            .padding(.bottom, 40)
        }
    }

    // Individual swimmer row with swipe and long-press
    private func swimmerRow(_ swimmer: Swimmer) -> some View {
        NavigationLink(destination: SwimmerDetailView(swimmerId: swimmer.id)) {
            SwimmerRow(swimmer: swimmer, onDelete: {}, onArchive: {})
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                swimmerToArchive = swimmer
                showArchiveAlert = true
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .tint(Color(hex: "f59e0b"))
        }
        // Long-press = delete
        .onLongPressGesture {
            swimmerToDelete = swimmer
            showDeleteAlert = true
        }
    }

    // Group header row: name + count + optional delete
    private func groupHeader(name: String, count: Int, onDelete: (() -> Void)?) -> some View {
        HStack {
            Text(name.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(hex: "4a6572"))
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(hex: "4a6572"))
            Spacer()
            if let onDelete = onDelete {
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "4a6572"))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(hex: "060e18"))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.fill")
                .font(.system(size: 48))
                .foregroundColor(Color(hex: "4a6572"))
            Text("No swimmers yet.")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(Color(hex: "7a9bb0"))
            Text("Tap + Add to add your first swimmer")
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "4a6572"))
        }
        .padding(.top, 80)
    }
}

#Preview {
    SwimmersListView()
        .environment(AuthManager())
}