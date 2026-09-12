import SwiftUI

enum AmPm: String, CaseIterable {
    case am = "AM"
    case pm = "PM"
}

/// SetScheduleView — sheet for scheduling a workout to a squad session.
///
/// Flow: coach picks a squad → the app fetches that squad's active session
/// slots (from `squad_session_slot`) → the date picker constrains to days
/// the squad trains → only the AM/PM slots the squad offers on the selected
/// weekday are selectable. The workout is saved with `group_id` so the
/// swimmers in that squad see it in their upcoming sessions.
struct SetScheduleView: View {
    var workoutId: String?
    var onSaved: () -> Void
    var onSaveDraft: () -> Void

    @Environment(AuthManager.self) private var authManager
    @StateObject private var viewModel = SetScheduleViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bgBase.ignoresSafeArea()

                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            // Step 1: Squad picker
                            Text("Squad")
                                .font(.eyebrow)
                                .foregroundColor(Color.textFaint)
                                .tracking(1.5)

                            squadPicker

                            if viewModel.selectedSquad != nil {
                                // Step 2: Date (constrained to squad's active weekdays)
                                Text("Date")
                                    .font(.eyebrow)
                                    .foregroundColor(Color.textFaint)
                                    .tracking(1.5)

                                DatePicker(
                                    "Select date",
                                    selection: $viewModel.selectedDate,
                                    in: viewModel.allowedDateRange,
                                    displayedComponents: .date
                                )
                                .datePickerStyle(.graphical)
                                .background(Color.bgSunken)
                                .cornerRadius(12)
                                .tint(Color.accentAction)
                                .onChange(of: viewModel.selectedDate) { _, _ in
                                    viewModel.updateAvailableSlots()
                                }

                                // Step 3: Session (only slots the squad offers on this day)
                                if !viewModel.availableSlots.isEmpty {
                                    Text("Session")
                                        .font(.eyebrow)
                                        .foregroundColor(Color.textFaint)
                                        .tracking(1.5)

                                    HStack(spacing: 12) {
                                        ForEach(viewModel.availableSlots, id: \.self) { slotOption in
                                            Button {
                                                viewModel.amPm = slotOption
                                            } label: {
                                                VStack(spacing: 2) {
                                                    Text(slotOption.rawValue)
                                                        .font(.system(size: 15, weight: .semibold))
                                                    if let label = viewModel.slotLabel(for: slotOption) {
                                                        Text(label)
                                                            .font(.caption2)
                                                    }
                                                }
                                                .frame(maxWidth: .infinity)
                                                .frame(height: 52)
                                                .background(viewModel.amPm == slotOption ? Color.accentAction : Color.bgSunken)
                                                .foregroundColor(viewModel.amPm == slotOption ? Color.textOnAccent : Color.textMuted)
                                                .cornerRadius(8)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 8)
                                                        .stroke(Color.divider, lineWidth: 1)
                                                )
                                            }
                                        }
                                    }
                                } else {
                                    Text("This squad doesn't train on \(viewModel.selectedWeekday.shortLabel). Pick another day or configure sessions for this squad.")
                                        .font(.caption)
                                        .foregroundColor(Color.accentAmber)
                                        .padding(.vertical, 8)
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 24)
                    }

                    // Buttons pinned at the bottom, always visible
                    VStack(spacing: 12) {
                        PrimaryButton(
                            title: "Confirm Schedule",
                            isLoading: viewModel.isSaving
                        ) {
                            Task {
                                if await viewModel.saveAndSchedule(workoutId: workoutId, authManager: authManager) != nil {
                                    onSaved()
                                }
                            }
                        }
                        .disabled(!viewModel.canConfirm)

                        Button("Save as Draft") {
                            Task {
                                if await viewModel.saveDraft(workoutId: workoutId, authManager: authManager) != nil {
                                    onSaveDraft()
                                }
                            }
                        }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color.textMuted)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                    .padding(.top, 12)
                    .background(Color.bgBase)
                }
            }
            .navigationTitle("Schedule Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(Color.statusError)
                }
            }
        }
        .presentationDetents([.large])
        .task {
            await viewModel.loadSquads(coachId: authManager.coachId)
        }
        .onChange(of: authManager.coachId) { _, newCoachId in
            guard let newCoachId = newCoachId else { return }
            Task { await viewModel.loadSquads(coachId: newCoachId) }
        }
    }

    private var squadPicker: some View {
        VStack(spacing: 0) {
            if viewModel.isLoadingSquads {
                ProgressView()
                    .tint(Color.accentAction)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else if viewModel.squads.isEmpty {
                Text("No squads yet. Create a squad first, then schedule workouts to it.")
                    .font(.caption)
                    .foregroundColor(Color.accentAmber)
                    .padding(.vertical, 12)
            } else {
                ForEach(viewModel.squads) { squad in
                    Button {
                        Haptics.selection()
                        Task { await viewModel.selectSquad(squad) }
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(squad.name)
                                    .font(.body)
                                    .foregroundColor(Color.textPrimary)
                                Text("\(viewModel.slotCount(for: squad.id)) sessions/week")
                                    .font(.caption2)
                                    .foregroundColor(Color.textFaint)
                            }
                            Spacer()
                            if viewModel.selectedSquad?.id == squad.id {
                                Image(systemName: "checkmark")
                                    .foregroundColor(Color.accentAction)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .background(
                            viewModel.selectedSquad?.id == squad.id
                                ? Color.accentAction.opacity(0.1)
                                : Color.bgRaised
                        )
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(
                                    viewModel.selectedSquad?.id == squad.id ? Color.accentAction : Color.divider,
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

@MainActor
final class SetScheduleViewModel: ObservableObject {
    @Published var squads: [CoachGroup] = []
    @Published var selectedSquad: CoachGroup?
    @Published var squadSlots: [SquadSessionSlot] = []
    @Published var availableSlots: [AmPm] = []
    @Published var selectedDate: Date = Date()
    @Published var amPm: AmPm = .am
    @Published var isSaving: Bool = false
    @Published var isLoadingSquads: Bool = false

    private let workoutService = WorkoutService()
    private let scheduleService = ScheduleService()
    private let swimmerService = SwimmerService()

    var canConfirm: Bool {
        selectedSquad != nil && !availableSlots.isEmpty
    }

    /// The selected date's weekday.
    var selectedWeekday: Weekday {
        Weekday(date: selectedDate)
    }

    /// Date range: today through 90 days out. The upper bound is generous;
    /// the real constraint is the weekday filter via `availableSlots`.
    var allowedDateRange: ClosedRange<Date> {
        let cal = Calendar.current
        let now = cal.startOfDay(for: Date())
        let max = cal.date(byAdding: .day, value: 90, to: now) ?? now
        return now...max
    }

    /// Weekdays the selected squad actively trains.
    private var activeWeekdays: Set<Weekday> {
        Set(squadSlots.filter { $0.active }.map { $0.day })
    }

    func loadSquads(coachId: String?) async {
        guard let coachId = coachId else { return }
        isLoadingSquads = true
        defer { isLoadingSquads = false }
        do {
            squads = try await swimmerService.fetchSquadsForCoach(coachId: coachId)
                .sorted { $0.name < $1.name }
            // Auto-select if there's only one squad
            if squads.count == 1 {
                await selectSquad(squads[0])
            }
        } catch {
            squads = []
        }
    }

    func selectSquad(_ squad: CoachGroup) async {
        selectedSquad = squad
        do {
            squadSlots = try await scheduleService.fetchAllSquadSlots(groupId: squad.id)
        } catch {
            squadSlots = []
        }
        updateAvailableSlots()
    }

    /// Recompute which AM/PM options are valid for the selected date's weekday.
    func updateAvailableSlots() {
        let weekday = selectedWeekday
        let daySlots = squadSlots.filter { $0.day == weekday && $0.active }
        let amActive = daySlots.contains { $0.slot == .am }
        let pmActive = daySlots.contains { $0.slot == .pm }
        var slots: [AmPm] = []
        if amActive { slots.append(.am) }
        if pmActive { slots.append(.pm) }
        availableSlots = slots
        // If the current selection is no longer valid, snap to the first available
        if !slots.contains(amPm), let first = slots.first {
            amPm = first
        }
    }

    /// Human-readable label for a slot on the selected day (e.g. "Distance").
    func slotLabel(for slot: AmPm) -> String? {
        let weekday = selectedWeekday
        let match = squadSlots.first { $0.day == weekday && $0.active && $0.slot == .am && slot == .am }
            ?? squadSlots.first { $0.day == weekday && $0.active && $0.slot == .pm && slot == .pm }
        return match?.label
    }

    /// Count of active slots for a squad (for the picker row subtitle).
    func slotCount(for squadId: String) -> Int {
        guard squadId == selectedSquad?.id else { return 0 }
        return squadSlots.filter { $0.active }.count
    }

    func saveAndSchedule(workoutId: String?, authManager: AuthManager) async -> String? {
        isSaving = true
        defer { isSaving = false }

        do {
            let resolvedCoachId = try await authManager.ensureCoach()
            let formatter = ISO8601DateFormatter()
            let dateStr = String(formatter.string(from: selectedDate).prefix(10))
            if let existingId = workoutId {
                _ = try await workoutService.updateWorkout(workoutId: existingId, updates: [
                    "scheduled_at": dateStr,
                    "am_pm": amPm.rawValue,
                    "status": "scheduled",
                    "group_id": selectedSquad?.id ?? ""
                ])
                return existingId
            } else {
                let workout = try await workoutService.createWorkout(
                    coachId: resolvedCoachId,
                    title: nil,
                    description: nil,
                    scheduledAt: dateStr,
                    groupId: selectedSquad?.id
                )
                return workout.id
            }
        } catch {
            return nil
        }
    }

    func saveDraft(workoutId: String?, authManager: AuthManager) async -> String? {
        isSaving = true
        defer { isSaving = false }

        do {
            let resolvedCoachId = try await authManager.ensureCoach()
            if let existingId = workoutId {
                _ = try await workoutService.updateWorkout(workoutId: existingId, updates: ["status": "draft"])
                return existingId
            } else {
                let workout = try await workoutService.createWorkout(
                    coachId: resolvedCoachId,
                    title: nil,
                    description: nil,
                    scheduledAt: nil
                )
                return workout.id
            }
        } catch {
            return nil
        }
    }
}

#Preview {
    SetScheduleView(
        workoutId: nil,
        onSaved: {},
        onSaveDraft: {}
    )
    .environment(AuthManager())
}