import SwiftUI
import Foundation

/// SquadManagementViewModel — drives the coach-side squad management UI.
/// Handles listing squads, creating/renaming, and assigning/removing
/// coaches and swimmers to each squad.
///
/// Note: the `coach_squads` table may not be migrated yet. The service
/// methods that touch it are written to compile against the existing
/// Supabase Swift client and will fail at runtime until the migration is
/// applied, which is the expected state per the task brief.
@MainActor
final class SquadManagementViewModel: ObservableObject {
    @Published var squads: [CoachGroup] = []
    @Published var allCoaches: [Coach] = []
    @Published var allSwimmers: [Swimmer] = []
    @Published var coachAssignments: [String: [CoachSquadAssignment]] = [:]
    @Published var swimmerAssignments: [String: [String]] = [:]
    @Published var isLoading: Bool = false
    @Published var isSaving: Bool = false
    @Published var errorMessage: String?

    private let swimmerService = SwimmerService()

    /// Load all squads, coaches, swimmers, and assignments for this coach.
    func load(coachId: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            async let squadsTask: [CoachGroup] = swimmerService.fetchSquadsForCoach(coachId: coachId)
            async let coachesTask: [Coach] = swimmerService.fetchCoachesForSquadManagement(coachId: coachId)
            async let swimmersTask: [Swimmer] = swimmerService.fetchSwimmers(coachId: coachId)

            let (squadsResult, coachesResult, swimmersResult) = try await (squadsTask, coachesTask, swimmersTask)
            self.squads = squadsResult.sorted { $0.name < $1.name }
            self.allCoaches = coachesResult
            self.allSwimmers = swimmersResult.sorted { $0.fullName < $1.fullName }

            // Load squad membership data.
            await loadAssignments()
        } catch {
            print("[SquadManagementViewModel] load error: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    /// Reload coach and swimmer assignments for every squad.
    func loadAssignments() async {
        var coachMap: [String: [CoachSquadAssignment]] = [:]
        var swimmerMap: [String: [String]] = [:]

        for squad in squads {
            do {
                let coaches = try await swimmerService.fetchCoachesForSquad(groupId: squad.id)
                coachMap[squad.id] = coaches
            } catch {
                // coach_squads may not exist yet; leave empty.
                print("[SquadManagementViewModel] coach assignments error for \(squad.id): \(error)")
            }

            do {
                let swimmers = try await swimmerService.fetchSwimmersInGroup(groupId: squad.id)
                swimmerMap[squad.id] = swimmers.map { $0.id }
            } catch {
                print("[SquadManagementViewModel] swimmer assignments error for \(squad.id): \(error)")
            }
        }

        self.coachAssignments = coachMap
        self.swimmerAssignments = swimmerMap
    }

    /// Create a new squad and refresh the list.
    func createSquad(coachId: String, name: String) async {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let squad = try await swimmerService.createSquad(coachId: coachId, name: name)
            squads.append(squad)
            squads.sort { $0.name < $1.name }
        } catch {
            print("[SquadManagementViewModel] createSquad error: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    /// Rename an existing squad.
    func renameSquad(squad: CoachGroup, newName: String) async -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != squad.name else { return true }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let updated = try await swimmerService.renameSquad(groupId: squad.id, name: trimmed)
            if let idx = squads.firstIndex(where: { $0.id == squad.id }) {
                squads[idx] = updated
                squads.sort { $0.name < $1.name }
            }
            return true
        } catch {
            print("[SquadManagementViewModel] renameSquad error: \(error)")
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Assign a coach to a squad with the default role "assistant".
    func assignCoach(coachId: String, toSquad groupId: String, role: String = "assistant") async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            try await swimmerService.addCoachToSquad(coachId: coachId, groupId: groupId, role: role)
            await refreshCoachAssignments(for: groupId)
        } catch {
            print("[SquadManagementViewModel] assignCoach error: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    /// Remove a coach from a squad.
    func removeCoach(coachId: String, fromSquad groupId: String) async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            try await swimmerService.removeCoachFromSquad(coachId: coachId, groupId: groupId)
            await refreshCoachAssignments(for: groupId)
        } catch {
            print("[SquadManagementViewModel] removeCoach error: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    /// Assign a swimmer to a squad.
    func assignSwimmer(swimmerId: String, toSquad groupId: String) async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            try await swimmerService.assignSwimmerToGroup(swimmerId: swimmerId, groupId: groupId)
            await refreshSwimmerAssignments(for: groupId)
        } catch {
            print("[SquadManagementViewModel] assignSwimmer error: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    /// Remove a swimmer from a squad.
    func removeSwimmer(swimmerId: String, fromSquad groupId: String) async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            try await swimmerService.removeSwimmerFromGroup(swimmerId: swimmerId, groupId: groupId)
            await refreshSwimmerAssignments(for: groupId)
        } catch {
            print("[SquadManagementViewModel] removeSwimmer error: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    /// Move a swimmer's full group membership to a single squad.
    /// Used by drag-and-drop or picker-based reassignment.
    func moveSwimmer(swimmerId: String, toSquad groupId: String?) async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let groupIds = groupId.map { [$0] } ?? []
            try await swimmerService.setSwimmerGroups(swimmerId: swimmerId, groupIds: groupIds)
            await loadAssignments()
        } catch {
            print("[SquadManagementViewModel] moveSwimmer error: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    private func refreshCoachAssignments(for groupId: String) async {
        do {
            let coaches = try await swimmerService.fetchCoachesForSquad(groupId: groupId)
            coachAssignments[groupId] = coaches
        } catch {
            coachAssignments[groupId] = []
        }
    }

    private func refreshSwimmerAssignments(for groupId: String) async {
        do {
            let swimmers = try await swimmerService.fetchSwimmersInGroup(groupId: groupId)
            swimmerAssignments[groupId] = swimmers.map { $0.id }
        } catch {
            swimmerAssignments[groupId] = []
        }
    }

    /// Convenience: coaches currently assigned to a squad.
    func assignedCoachIds(for groupId: String) -> Set<String> {
        Set(coachAssignments[groupId]?.map { $0.coachId } ?? [])
    }

    /// Convenience: swimmers currently assigned to a squad.
    func assignedSwimmerIds(for groupId: String) -> Set<String> {
        Set(swimmerAssignments[groupId] ?? [])
    }

    /// Convenience: swimmers not yet in any squad.
    var unassignedSwimmers: [Swimmer] {
        let assigned = Set(swimmerAssignments.values.flatMap { $0 })
        return allSwimmers.filter { !assigned.contains($0.id) }
    }
}

/// CoachSquadAssignment — mirrors the `coach_squads` join row.
/// This model is local to the squad management feature until the
/// schema migration lands; it decodes from the expected row shape.
struct CoachSquadAssignment: Codable, Identifiable, Sendable {
    let id: String
    let coachId: String
    let groupId: String
    let role: String?

    enum CodingKeys: String, CodingKey {
        case id
        case coachId = "coach_id"
        case groupId = "group_id"
        case role
    }
}
