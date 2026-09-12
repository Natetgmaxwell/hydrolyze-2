import SwiftUI

/// SquadManagementView — coach-side squad management screen.
/// Lists squads, lets the coach create/rename squads, and assign or
/// remove coaches and swimmers from each squad.
///
/// Navigated to from `SwimmersListView` via a toolbar button.
struct SquadManagementView: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = SquadManagementViewModel()

    @State private var showCreateSheet = false
    @State private var newSquadName = ""
    @State private var selectedSquad: CoachGroup? = nil
    @State private var renameText = ""
    @State private var showRenameAlert = false

    private var coachId: String? { authManager.coachId }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bgBase.ignoresSafeArea()
                squadsList
            }
            .navigationTitle("SQUADS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .foregroundColor(Color.textPrimary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.action()
                        showCreateSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Color.accentAction)
                    }
                }
            }
        }
        .task {
            if let coachId = coachId {
                await viewModel.load(coachId: coachId)
            }
        }
        .onChange(of: authManager.coachId) { _, newCoachId in
            guard let newCoachId = newCoachId else { return }
            Task { await viewModel.load(coachId: newCoachId) }
        }
        .sheet(isPresented: $showCreateSheet) {
            createSquadSheet
        }
        .sheet(item: $selectedSquad) { squad in
            SquadEditSheet(
                squad: squad,
                viewModel: viewModel,
                onRename: {
                    renameText = squad.name
                    showRenameAlert = true
                }
            )
        }
        .alert("Rename Squad", isPresented: $showRenameAlert) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let squad = selectedSquad {
                    Task {
                        let success = await viewModel.renameSquad(squad: squad, newName: renameText)
                        if success {
                            selectedSquad = viewModel.squads.first { $0.id == squad.id }
                        }
                    }
                }
            }
        } message: {
            Text("Enter a new name for \(selectedSquad?.name ?? "this squad").")
        }
    }

    private var squadsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if viewModel.isLoading && viewModel.squads.isEmpty {
                    ProgressView()
                        .tint(Color.textMuted)
                        .padding(.top, 40)
                } else if coachId == nil && !viewModel.isLoading {
                    // V0.55 (2026-09-12): signed in but AuthManager hasn't
                    // resolved the coach row yet. Surface as a retry state
                    // instead of the misleading "No squads yet." — that's
                    // reserved for genuinely-empty rosters.
                    UnresolvedCoachState(
                        message: "We couldn't load your account. Tap retry.",
                        onRetry: { Task { await authManager.retryResolveCoach() } }
                    )
                } else if viewModel.squads.isEmpty {
                    emptyState
                } else {
                    ForEach(viewModel.squads) { squad in
                        squadRow(squad)
                    }
                }
            }
            .padding(.bottom, 40)
        }
    }

    private func squadRow(_ squad: CoachGroup) -> some View {
        Button {
            Haptics.tap()
            selectedSquad = squad
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(squad.name)
                        .font(.bodyEmphasis)
                        .foregroundColor(Color.textPrimary)

                    HStack(spacing: 8) {
                        let coachCount = viewModel.coachAssignments[squad.id]?.count ?? 0
                        let swimmerCount = viewModel.swimmerAssignments[squad.id]?.count ?? 0
                        Label("\(coachCount)", systemImage: "person.2")
                            .font(.caption2)
                            .foregroundColor(Color.textMuted)
                        Label("\(swimmerCount)", systemImage: "figure.swim")
                            .font(.caption2)
                            .foregroundColor(Color.textMuted)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color.textFaint)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.bgRaised)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.divider, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var createSquadSheet: some View {
        NavigationStack {
            VStack(spacing: 24) {
                TextField("Squad name", text: $newSquadName)
                    .font(.system(size: 17))
                    .foregroundColor(Color.textPrimary)
                    .padding(12)
                    .background(Color.bgInset)
                    .cornerRadius(8)
                    .padding(.horizontal, 24)
                    .padding(.top, 24)

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(Color.statusError)
                        .padding(.horizontal, 24)
                }

                Spacer()
            }
            .background(Color.bgBase)
            .navigationTitle("New Squad")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        newSquadName = ""
                        showCreateSheet = false
                    }
                    .foregroundColor(Color.textPrimary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Create") {
                        Task {
                            if let coachId = coachId {
                                await viewModel.createSquad(coachId: coachId, name: newSquadName)
                                // Only dismiss on success (no error message set)
                                if viewModel.errorMessage == nil {
                                    newSquadName = ""
                                    showCreateSheet = false
                                }
                            } else {
                                viewModel.errorMessage = "Couldn't identify your coach account. Try signing out and back in."
                            }
                        }
                    }
                    .foregroundColor(newSquadName.isEmpty ? Color.textFaint : Color.accentAction)
                    .disabled(newSquadName.isEmpty || viewModel.isSaving)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 48))
                .foregroundColor(Color.textFaint)

            Text("No squads yet.")
                .font(.body)
                .foregroundColor(Color.textMuted)

            Text("Tap + to create your first squad.")
                .font(.caption)
                .foregroundColor(Color.textFaint)
        }
        .padding(.top, 80)
    }
}

// MARK: - SquadEditSheet

/// SquadEditSheet — inline editor for a single squad: rename control,
/// coach assignment list, and swimmer assignment list.
private struct SquadEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let squad: CoachGroup
    @ObservedObject var viewModel: SquadManagementViewModel
    let onRename: () -> Void

    @State private var showAddCoach = false
    @State private var showAddSwimmer = false
    @State private var showSessionsEditor = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bgBase.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        headerSection
                        sessionsSection
                        coachesSection
                        swimmersSection

                        if let errorMessage = viewModel.errorMessage {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundColor(Color.statusError)
                                .padding(.horizontal, 16)
                        }
                    }
                    .padding(.vertical, 16)
                }
            }
            .navigationTitle(squad.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .foregroundColor(Color.textPrimary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.tap()
                        onRename()
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Color.textMuted)
                    }
                }
            }
            .sheet(isPresented: $showAddCoach) {
                CoachAssignmentSheet(squad: squad, viewModel: viewModel)
            }
            .sheet(isPresented: $showAddSwimmer) {
                SwimmerAssignmentSheet(squad: squad, viewModel: viewModel)
            }
            .sheet(isPresented: $showSessionsEditor) {
                SquadSessionsEditor(group: squad)
            }
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(squad.name)
                .font(.titleSmall)
                .foregroundColor(Color.textPrimary)
            Text("Manage coaches and swimmers for this squad.")
                .font(.caption)
                .foregroundColor(Color.textMuted)
        }
        .padding(.horizontal, 16)
    }

    /// Sessions section — opens SquadSessionsEditor where the coach
    /// adds/removes/pauses the squad's weekly AM/PM slots.
    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Sessions")
                    .font(.eyebrow)
                    .foregroundColor(Color.textMuted)
                Spacer()
            }
            Button {
                Haptics.tap()
                showSessionsEditor = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 18))
                        .foregroundColor(Color.textMuted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Weekly sessions")
                            .font(.body)
                            .foregroundColor(Color.textPrimary)
                        Text("Set which AM/PM slots this squad trains")
                            .font(.caption2)
                            .foregroundColor(Color.textFaint)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color.textFaint)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .background(Color.bgRaised)
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.divider, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
        }
    }

    private var coachesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("COACHES", count: viewModel.coachAssignments[squad.id]?.count ?? 0) {
                showAddCoach = true
            }

            let assignments = viewModel.coachAssignments[squad.id] ?? []
            if assignments.isEmpty {
                Text("No coaches assigned.")
                    .font(.caption)
                    .foregroundColor(Color.textFaint)
                    .padding(.horizontal, 16)
            } else {
                VStack(spacing: 8) {
                    ForEach(assignments) { assignment in
                        if let coach = viewModel.allCoaches.first(where: { $0.id == assignment.coachId }) {
                            memberRow(label: coach.name ?? "Unknown coach", detail: assignment.role ?? "coach") {
                                Task {
                                    await viewModel.removeCoach(coachId: assignment.coachId, fromSquad: squad.id)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var swimmersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("SWIMMERS", count: viewModel.swimmerAssignments[squad.id]?.count ?? 0) {
                showAddSwimmer = true
            }

            let swimmerIds = viewModel.swimmerAssignments[squad.id] ?? []
            if swimmerIds.isEmpty {
                Text("No swimmers assigned.")
                    .font(.caption)
                    .foregroundColor(Color.textFaint)
                    .padding(.horizontal, 16)
            } else {
                VStack(spacing: 8) {
                    ForEach(swimmerIds, id: \.self) { swimmerId in
                        if let swimmer = viewModel.allSwimmers.first(where: { $0.id == swimmerId }) {
                            memberRow(label: swimmer.fullName, detail: nil) {
                                Task {
                                    await viewModel.removeSwimmer(swimmerId: swimmer.id, fromSquad: squad.id)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int, onAdd: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .font(.eyebrow)
                .foregroundColor(Color.textMuted)
            Text("\(count)")
                .font(.eyebrow)
                .foregroundColor(Color.textFaint)
            Spacer()
            Button {
                Haptics.tap()
                onAdd()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color.textMuted)
            }
        }
        .padding(.horizontal, 16)
    }

    private func memberRow(label: String, detail: String?, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.body)
                    .foregroundColor(Color.textPrimary)
                if let detail = detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundColor(Color.textFaint)
                }
            }
            Spacer()
            Button {
                Haptics.heavy()
                onRemove()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color.statusError)
                    .frame(width: 28, height: 28)
                    .background(Color.bgInset)
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.bgRaised)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.divider, lineWidth: 1)
        )
    }
}

// MARK: - CoachAssignmentSheet

private struct CoachAssignmentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let squad: CoachGroup
    @ObservedObject var viewModel: SquadManagementViewModel

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bgBase.ignoresSafeArea()
                List {
                    ForEach(viewModel.allCoaches) { coach in
                        let isAssigned = viewModel.assignedCoachIds(for: squad.id).contains(coach.id)
                        Button {
                            Haptics.tap()
                            Task {
                                if isAssigned {
                                    await viewModel.removeCoach(coachId: coach.id, fromSquad: squad.id)
                                } else {
                                    await viewModel.assignCoach(coachId: coach.id, toSquad: squad.id)
                                }
                            }
                        } label: {
                            HStack {
                                Text(coach.name ?? "Unnamed coach")
                                    .foregroundColor(Color.textPrimary)
                                Spacer()
                                if isAssigned {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(Color.textPrimary)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .background(Color.bgBase)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Assign Coaches")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundColor(Color.textPrimary)
                }
            }
        }
    }
}

// MARK: - SwimmerAssignmentSheet

private struct SwimmerAssignmentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let squad: CoachGroup
    @ObservedObject var viewModel: SquadManagementViewModel

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bgBase.ignoresSafeArea()
                List {
                    ForEach(viewModel.allSwimmers) { swimmer in
                        let isAssigned = viewModel.assignedSwimmerIds(for: squad.id).contains(swimmer.id)
                        Button {
                            Haptics.tap()
                            Task {
                                if isAssigned {
                                    await viewModel.removeSwimmer(swimmerId: swimmer.id, fromSquad: squad.id)
                                } else {
                                    await viewModel.assignSwimmer(swimmerId: swimmer.id, toSquad: squad.id)
                                }
                            }
                        } label: {
                            HStack {
                                Text(swimmer.fullName)
                                    .foregroundColor(Color.textPrimary)
                                Spacer()
                                if isAssigned {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(Color.textPrimary)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .background(Color.bgBase)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Assign Swimmers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundColor(Color.textPrimary)
                }
            }
        }
    }
}

#Preview {
    SquadManagementView()
        .environment(AuthManager())
}
