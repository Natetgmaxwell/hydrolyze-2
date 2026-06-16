import SwiftUI

enum AmPm: String, CaseIterable {
    case am = "AM"
    case pm = "PM"
}

/// SetScheduleView — sheet for scheduling a workout date + AM/PM.
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
                Color(hex: "060e18").ignoresSafeArea()

                VStack(alignment: .leading, spacing: 24) {
                    Text("DATE")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(hex: "4a6572"))
                        .tracking(1.5)

                    DatePicker(
                        "Select date",
                        selection: $viewModel.selectedDate,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                    .background(Color(hex: "0d1b2a"))
                    .cornerRadius(12)
                    .tint(Color(hex: "09d4ee"))

                    Text("SESSION")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(hex: "4a6572"))
                        .tracking(1.5)

                    HStack(spacing: 12) {
                        ForEach(AmPm.allCases, id: \.self) { option in
                            Button {
                                viewModel.amPm = option
                            } label: {
                                Text(option.rawValue)
                                    .font(.system(size: 15, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 48)
                                    .background(viewModel.amPm == option ? Color(hex: "09d4ee") : Color(hex: "0d1b2a"))
                                    .foregroundColor(viewModel.amPm == option ? .black : Color(hex: "7a9bb0"))
                                    .cornerRadius(8)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color(hex: "2d3e50"), lineWidth: 1)
                                    )
                            }
                        }
                    }

                    Spacer()

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
                        .foregroundColor(Color(hex: "7a9bb0"))
                    }
                }
                .padding(24)
            }
            .navigationTitle("Schedule Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(Color(hex: "ef4444"))
                }
            }
        }
        .presentationDetents([.large])
    }
}

@MainActor
final class SetScheduleViewModel: ObservableObject {
    @Published var selectedDate: Date = Date()
    @Published var amPm: AmPm = .am
    @Published var isSaving: Bool = false

    private let workoutService = WorkoutService()

    var canConfirm: Bool { true }

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
                    "status": "scheduled"
                ])
                return existingId
            } else {
                let workout = try await workoutService.createWorkout(
                    coachId: resolvedCoachId,
                    title: nil,
                    description: nil,
                    scheduledAt: dateStr
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