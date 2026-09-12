import SwiftUI

/// SwimmerSheetViewModel — drives add/edit sheet for swimmers.
/// Pre-fills from swimmerId param via .task (fetch on appear if editing).
@MainActor
final class SwimmerSheetViewModel: ObservableObject {
    @Published var firstName: String = ""
    @Published var lastName: String = ""
    @Published var birthdate: Date = Date()
    @Published var hasBirthdate: Bool = false
    @Published var gender: String = "X"
    @Published var mainStroke: String = "Free"
    @Published var formStroke: String = "Form"
    @Published var notes: String = ""
    @Published var selectedGroupIds: Set<String> = []
    @Published var availableGroups: [CoachGroup] = []
    @Published var isLoading: Bool = false
    @Published var isSaving: Bool = false
    @Published var errorMessage: String?
    @Published var isDirty: Bool = false

    var isEdit: Bool { swimmerId != nil }
    var swimmerId: String?
    var onSave: (() -> Void)?

    private let swimmerService = SwimmerService()

    func load(swimmerId: String?, coachId: String?) async {
        self.swimmerId = swimmerId
        if let coachId = coachId {
            do {
                availableGroups = try await swimmerService.fetchGroups(coachId: coachId)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        guard let swimmerId = swimmerId else { return }
        isLoading = true
        do {
            let swimmer = try await swimmerService.fetchSwimmer(swimmerId: swimmerId)
            firstName = swimmer.firstName
            lastName = swimmer.lastName ?? ""
            if let bd = swimmer.birthdate {
                birthdate = ISO8601DateFormatter().date(from: bd + "T00:00:00") ?? Date()
                hasBirthdate = true
            }
            if let g = swimmer.gender, ["M", "F", "X"].contains(g) { gender = g }
            if let ms = swimmer.mainStroke, Swimmer.mainStrokeOptions.contains(ms) {
                mainStroke = ms
            }
            if let fs = swimmer.formStroke, Swimmer.formStrokeOptions.contains(fs) {
                formStroke = fs
            }
            notes = swimmer.notes ?? ""
            selectedGroupIds = Set(swimmer.groups.map { $0.id })
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    var canSave: Bool { !firstName.trimmingCharacters(in: .whitespaces).isEmpty }

    func save(coachId: String?) async -> Bool {
        guard let coachId = coachId else { return false }
        guard canSave else { return false }
        isSaving = true
        errorMessage = nil
        do {
            if let swimmerId = swimmerId {
                var updates: [String: String] = [
                    "first_name": firstName.trimmingCharacters(in: .whitespaces),
                ]
                if !lastName.isEmpty { updates["last_name"] = lastName.trimmingCharacters(in: .whitespaces) }
                else { updates["last_name"] = "" }
                if hasBirthdate {
                    updates["birthdate"] = ISO8601DateFormatter().string(from: birthdate).prefix(10).description
                }
                updates["gender"] = gender == "X" ? "" : gender
                updates["main_stroke"] = mainStroke
                updates["form_stroke"] = formStroke
                if !notes.isEmpty { updates["notes"] = notes }
                _ = try await swimmerService.updateSwimmer(swimmerId: swimmerId, updates: updates)
                try await swimmerService.setSwimmerGroups(swimmerId: swimmerId, groupIds: Array(selectedGroupIds))
            } else {
                let newSwimmer = try await swimmerService.createSwimmer(
                    coachId: coachId,
                    firstName: firstName.trimmingCharacters(in: .whitespaces),
                    lastName: lastName.isEmpty ? nil : lastName.trimmingCharacters(in: .whitespaces),
                    birthdate: hasBirthdate ? ISO8601DateFormatter().string(from: birthdate).prefix(10).description : nil,
                    gender: gender == "X" ? nil : gender
                )
                // After creating, set strokes via update
                _ = try await swimmerService.updateSwimmer(swimmerId: newSwimmer.id, updates: [
                    "main_stroke": mainStroke,
                    "form_stroke": formStroke,
                ])
                try await swimmerService.setSwimmerGroups(swimmerId: newSwimmer.id, groupIds: Array(selectedGroupIds))
            }
            onSave?()
            return true
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
            return false
        }
    }

    func toggleGroup(_ groupId: String) {
        isDirty = true
        if selectedGroupIds.contains(groupId) { selectedGroupIds.remove(groupId) }
        else { selectedGroupIds.insert(groupId) }
    }
}
