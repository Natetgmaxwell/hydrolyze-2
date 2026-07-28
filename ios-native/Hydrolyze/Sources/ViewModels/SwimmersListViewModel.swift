import SwiftUI
import Foundation

/// SwimmerFilter — Active / Archived toggle for the swimmers list.
enum SwimmerFilter: String, CaseIterable {
    case active = "Active"
    case archived = "Archived"
}

/// SwimmersListViewModel — view model for the swimmers roster screen.
/// Drives SwimmersListView with group sections, filter pills, and add/edit/archive actions.
@MainActor
final class SwimmersListViewModel: ObservableObject {
    @Published var allSwimmers: [Swimmer] = []
    @Published var groups: [CoachGroup] = []
    @Published var selectedFilter: SwimmerFilter = .active
    @Published var isLoading: Bool = false
    @Published var showAddGroupRow: Bool = false
    @Published var errorMessage: String?

    private let swimmerService = SwimmerService()
    private let authManager = AuthManager()

    /// Swimmers filtered by the current active/archived pill.
    var filteredSwimmers: [Swimmer] {
        allSwimmers.filter { swimmer in
            if selectedFilter == .active {
                return swimmer.archivedAt == nil
            } else {
                return swimmer.archivedAt != nil
            }
        }
    }

    /// GroupWithSwimmers pairs — same shape as RN's GroupWithSwimmers.
    var groupsWithSwimmers: [(group: CoachGroup, swimmers: [Swimmer])] {
        let active = filteredSwimmers
        let sortedGroups = groups.sorted { $0.name < $1.name }
        var result: [(group: CoachGroup, swimmers: [Swimmer])] = []
        for group in sortedGroups {
            let members = active.filter { swimmer in
                swimmerGroupIds[swimmer.id]?.contains(group.id) ?? false
            }
            if !members.isEmpty {
                result.append((group: group, swimmers: members))
            }
        }
        return result
    }

    /// Swimmers not in any group — always last.
    var noGroupSwimmers: [Swimmer] {
        let active = filteredSwimmers
        let groupedIds = Set(allSwimmerGroupIds)
        return active.filter { !groupedIds.contains($0.id) }
    }

    // Internal: swimmerId → [groupId] lookup built from all swimmer group memberships.
    private var swimmerGroupIds: [String: Set<String>] = [:]
    private var allSwimmerGroupIds: Set<String> = []

    func loadSwimmers(coachId: String?) async {
        print("[SwimmersListViewModel] loadSwimmers coachId=\(String(describing: coachId)) filter=\(selectedFilter.rawValue)")
        guard let coachId = coachId else { return }
        isLoading = true
        errorMessage = nil
        do {
            let (swimmerList, groupList) = try await swimmerService.fetchSwimmersWithGroups(coachId: coachId, includeArchived: selectedFilter == .archived)
            print("[SwimmersListViewModel] loadSwimmers got \(swimmerList.count) swimmers, \(groupList.count) groups")
            allSwimmers = swimmerList
            groups = groupList
            rebuildGroupMap()
        } catch {
            print("[SwimmersListViewModel] loadSwimmers error: \(error)")
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func rebuildGroupMap() {
        var map: [String: Set<String>] = [:]
        var all: Set<String> = []
        for swimmer in allSwimmers {
            let ids = Set(swimmer.groups.map { $0.id })
            if !ids.isEmpty {
                map[swimmer.id] = ids
                all.formUnion(ids)
            }
        }
        self.swimmerGroupIds = map
        self.allSwimmerGroupIds = all
    }

    func createGroup(coachId: String?, name: String) async {
        guard let coachId = coachId else { return }
        do {
            let newGroup = try await swimmerService.createGroup(coachId: coachId, name: name)
            groups.append(newGroup)
            groups.sort { $0.name < $1.name }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteGroup(groupId: String) async {
        do {
            try await swimmerService.deleteGroup(groupId: groupId)
            groups.removeAll { $0.id == groupId }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func archiveSwimmer(id: String) async {
        do {
            _ = try await swimmerService.archiveSwimmer(swimmerId: id)
            if let idx = allSwimmers.firstIndex(where: { $0.id == id }) {
                allSwimmers[idx].archivedAt = ISO8601DateFormatter().string(from: Date())
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unarchiveSwimmer(id: String) async {
        do {
            _ = try await swimmerService.unarchiveSwimmer(swimmerId: id)
            if let idx = allSwimmers.firstIndex(where: { $0.id == id }) {
                allSwimmers[idx].archivedAt = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSwimmer(id: String) async {
        do {
            try await swimmerService.deleteSwimmer(swimmerId: id)
            allSwimmers.removeAll { $0.id == id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Move a swimmer to a single squad (or remove from all squads).
    func moveSwimmer(swimmerId: String, toGroupId groupId: String?) async {
        do {
            let groupIds = groupId.map { [$0] } ?? []
            try await swimmerService.setSwimmerGroups(swimmerId: swimmerId, groupIds: groupIds)
            await loadSwimmers(coachId: authManager.coachId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
extension SwimmerService {
    func fetchSwimmersWithGroups(coachId: String, includeArchived: Bool) async throws -> ([Swimmer], [CoachGroup]) {
        let swimmers: [Swimmer]
        if includeArchived {
            swimmers = try await fetchArchivedSwimmers(coachId: coachId)
        } else {
            swimmers = try await fetchSwimmers(coachId: coachId)
        }
        let groups = try await fetchGroups(coachId: coachId)

        let swimmerIds = swimmers.map { $0.id }
        let memberships = try await self.fetchSwimmerGroupMemberships(swimmerIds: swimmerIds)

        var groupMap: [String: [CoachGroup]] = [:]
        for m in memberships {
            if groupMap[m.swimmerId] == nil { groupMap[m.swimmerId] = [] }
            if let g = groups.first(where: { $0.id == m.groupId }) {
                groupMap[m.swimmerId]?.append(g)
            }
        }

        let swimmersWithGroups = swimmers.map { swimmer in
            var s = swimmer
            s.groups = groupMap[swimmer.id] ?? []
            return s
        }

        return (swimmersWithGroups, groups)
    }
}