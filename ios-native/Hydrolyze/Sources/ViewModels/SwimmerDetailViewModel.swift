import SwiftUI

/// SwimmerDetailViewModel — view model for swimmer profile screen.
/// Loads swimmer data, groups, PBs, and progression; drives archive/delete/
/// form-stroke-picker/group-toggle actions.
@MainActor
final class SwimmerDetailViewModel: ObservableObject {
    @Published var swimmer: Swimmer?
    @Published var allGroups: [CoachGroup] = []
    @Published var swimmerGroupIds: Set<String> = []
    @Published var personalBests: [SwimmerPB] = []
    @Published var progressionTimes: [RecordedTime] = []
    @Published var isLoading: Bool = true
    @Published var errorMessage: String?

    var swimmerId: String

    private let swimmerService = SwimmerService()
    private let chartDataService = ChartDataService()

    init(swimmerId: String) {
        self.swimmerId = swimmerId
    }

    var initials: String {
        guard let swimmer = swimmer else { return "??" }
        let first = swimmer.firstName.prefix(1)
        let last = (swimmer.lastName ?? "").prefix(1)
        if last.isEmpty { return String(swimmer.firstName.prefix(2)).uppercased() }
        return "\(first)\(last)".uppercased()
    }

    var ageText: String? {
        guard let swimmer = swimmer, let bd = swimmer.birthdate else { return nil }
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: bd + "T00:00:00") else { return nil }
        let ageComponents = Calendar.current.dateComponents([.year], from: date, to: Date())
        guard let years = ageComponents.year, years > 0 else { return nil }
        let dobStr = DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)
        return "DOB: \(dobStr)  ·  \(years) years"
    }

    /// Best (lowest) timeMs in the current progression window, for the rule mark.
    var bestProgressionTimeMs: Int? {
        progressionTimes.map { $0.timeMs }.min()
    }

    func load(coachId: String?) async {
        guard let coachId = coachId else { return }
        isLoading = true
        do {
            let swimmer = try await swimmerService.fetchSwimmer(swimmerId: swimmerId)
            self.swimmer = swimmer
            let groupIds = try await swimmerService.fetchSwimmerGroupIds(swimmerId: swimmerId)
            swimmerGroupIds = Set(groupIds)
            allGroups = try await swimmerService.fetchGroups(coachId: coachId)
            personalBests = try await swimmerService.fetchPersonalBests(swimmerId: swimmerId)
            await loadProgression()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Fetch the swimmer's recorded times for the last 30 days.
    /// Used by the ProgressionChart in the swimmer detail view.
    func loadProgression() async {
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        do {
            // If the swimmer has a PB, use that distance. Otherwise show all.
            let distance = personalBests.first?.distance
            let allTimes = try await chartDataService.fetchSpeedCurveData(
                swimmerId: swimmerId, since: thirtyDaysAgo
            )
            if let distance = distance {
                progressionTimes = allTimes.filter { $0.paceDistance == distance || $0.paceDistance == nil }
            } else {
                progressionTimes = allTimes
            }
        } catch {
            progressionTimes = []
        }
    }

    func updateFormStroke(_ stroke: String) async {
        guard let swimmer = swimmer else { return }
        do {
            _ = try await swimmerService.updateSwimmer(swimmerId: swimmer.id, updates: ["form_stroke": stroke])
            self.swimmer?.formStroke = stroke
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateMainStroke(_ stroke: String) async {
        guard let swimmer = swimmer else { return }
        do {
            _ = try await swimmerService.updateSwimmer(swimmerId: swimmer.id, updates: ["main_stroke": stroke])
            self.swimmer?.mainStroke = stroke
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleGroup(_ groupId: String) async {
        if swimmerGroupIds.contains(groupId) {
            do {
                try await swimmerService.removeSwimmerFromGroup(swimmerId: swimmerId, groupId: groupId)
                swimmerGroupIds.remove(groupId)
            } catch {
                errorMessage = error.localizedDescription
            }
        } else {
            do {
                try await swimmerService.assignSwimmerToGroup(swimmerId: swimmerId, groupId: groupId)
                swimmerGroupIds.insert(groupId)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func archiveSwimmer() async {
        do {
            _ = try await swimmerService.archiveSwimmer(swimmerId: swimmerId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSwimmer() async {
        do {
            try await swimmerService.deleteSwimmer(swimmerId: swimmerId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deletePB(_ pb: SwimmerPB) async {
        do {
            try await swimmerService.deletePersonalBest(pbId: pb.id)
            personalBests.removeAll { $0.id == pb.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addPB(distance: Int, stroke: String, timeMs: Int) async {
        do {
            let newPB = try await swimmerService.upsertPersonalBest(swimmerId: swimmerId, distance: distance, stroke: stroke, timeMs: timeMs, gear: nil)
            if let idx = personalBests.firstIndex(where: { $0.distance == distance && $0.stroke == stroke }) {
                personalBests[idx] = newPB
            } else {
                personalBests.append(newPB)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
