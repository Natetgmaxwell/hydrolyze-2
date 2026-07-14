import SwiftUI

/// WorkoutBuilderView — natural language workout creation with live preview.
/// Uses debounced input to call the Edge Function parser and renders via WorkoutPreview.
struct WorkoutBuilderView: View {
    var workoutId: String?
    @Environment(AuthManager.self) private var authManager
    @StateObject private var viewModel = WorkoutBuilderViewModel()
    @State private var showScheduleSheet = false
    @State private var showCancelAlert = false
    @FocusState private var isTextFieldFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bgBase.ignoresSafeArea()

                VStack(spacing: 0) {
                    scrollableContent
                    actionButtons
                }
            }
            .navigationTitle("Workouts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        if viewModel.hasContent {
                            showCancelAlert = true
                        } else {
                            dismiss()
                        }
                    }
                    .foregroundColor(Color.statusError)
                }
            }
        }
        .alert("Discard changes?", isPresented: $showCancelAlert) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) { }
        } message: {
            Text("Your workout won't be saved.")
        }
        .sheet(isPresented: $showScheduleSheet) {
            SetScheduleView(
                workoutId: viewModel.savedWorkoutId,
                onSaved: { dismiss() },
                onSaveDraft: { dismiss() }
            )
        }
        .task {
            if let id = workoutId {
                await viewModel.loadWorkout(id: id)
            }
        }
        .onChange(of: viewModel.workoutText) { _, newValue in
            viewModel.debouncedParse(newValue)
        }
    }

    private var scrollableContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("WORKOUT BUILDER")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color.textFaint)
                    .tracking(1.5)

                TextField("Workout title (optional)", text: $viewModel.title)
                    .font(.system(size: 17))
                    .foregroundColor(Color.textPrimary)
                    .padding(12)
                    .background(Color.bgSunken)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.divider, lineWidth: 1)
                    )

                TextEditor(text: $viewModel.workoutText)
                    .font(.system(size: 16))
                    .foregroundColor(Color.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 180)
                    .padding(12)
                    .background(Color.bgSunken)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(viewModel.isFocused ? Color.accentCyan : Color.divider, lineWidth: viewModel.isFocused ? 2 : 1)
                    )
                    .overlay(alignment: .topLeading) {
                        if viewModel.workoutText.isEmpty {
                            Text("4×100 free @1:30, 4×50 kick fins @1:00, 200 easy\n\nTip: separate sets with commas...")
                                .font(.system(size: 16))
                                .foregroundColor(Color.textFaint)
                                .padding(16)
                                .opacity(viewModel.workoutText.isEmpty ? 1 : 0)
                                .allowsHitTesting(false)
                        }
                    }
                    .focused($isTextFieldFocused)
                    .onChange(of: isTextFieldFocused) { _, newValue in
                        viewModel.isFocused = newValue
                    }

                parseStatusLine

                if viewModel.isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                            .tint(Color.accentCyan)
                        Spacer()
                    }
                    .padding(.vertical, 20)
                } else {
                    WorkoutPreview(workout: viewModel.parsedWorkout ?? ParsedWorkout(title: nil, sections: []))
                }
            }
            .padding(16)
        }
    }

    private var parseStatusLine: some View {
        Group {
            if let error = viewModel.parseError {
                Text("⚠ \(error)")
                    .font(.caption)
                    .foregroundColor(Color.accentAmber)
            } else if viewModel.parsedWorkout != nil {
                let count = viewModel.parsedWorkout?.sections.flatMap { $0.namedSets }.flatMap { $0.repGroups }.count ?? 0
                Text("✓ \(count) sets parsed")
                    .font(.caption)
                    .foregroundColor(Color.statusSuccess)
            }
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            PrimaryButton(
                title: viewModel.isEditMode ? "Update Workout" : "Save Workout",
                isLoading: viewModel.isSaving
            ) {
                Task {
                    if await viewModel.saveWorkout(authManager: authManager) != nil {
                        dismiss()
                    }
                }
            }
            .disabled(!viewModel.canSave)

            Button("Schedule →") {
                Task {
                    if await viewModel.saveWorkout(authManager: authManager) != nil {
                        showScheduleSheet = true
                    }
                }
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(Color.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(Color.bgSunken)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.divider, lineWidth: 1)
            )
            .disabled(!viewModel.canSave)
            .opacity(viewModel.canSave ? 1 : 0.5)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }
}

@MainActor
final class WorkoutBuilderViewModel: ObservableObject {
    @Published var title: String = ""
    @Published var workoutText: String = ""
    @Published var parsedWorkout: ParsedWorkout?
    @Published var isLoading: Bool = false
    @Published var isSaving: Bool = false
    @Published var parseError: String?
    @Published var parseSuccess: Bool = false
    @Published var savedWorkoutId: String?
    @Published var isFocused: Bool = false

    var workoutId: String?
    var canSave: Bool { parsedWorkout?.sections.isEmpty == false }
    var isEditMode: Bool { workoutId != nil }
    var hasContent: Bool { !title.isEmpty || !workoutText.isEmpty }

    private let workoutService = WorkoutService()
    private var debounceTask: Task<Void, Never>?

    func debouncedParse(_ text: String) {
        debounceTask?.cancel()
        guard !text.isEmpty else {
            parsedWorkout = nil
            parseError = nil
            parseSuccess = false
            return
        }
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await parse(text)
        }
    }

    func parse(_ text: String) async {
        isLoading = true
        parseError = nil
        do {
            parsedWorkout = try await workoutService.parseWorkout(text: text)
            parseSuccess = true
        } catch {
            parseError = "Couldn't parse — check your formatting"
            parseSuccess = false
        }
        isLoading = false
    }

    func saveWorkout(authManager: AuthManager) async -> String? {
        isSaving = true
        do {
            let resolvedCoachId = try await authManager.ensureCoach()
            let id: String
            if let existingId = workoutId {
                _ = try await workoutService.updateWorkout(workoutId: existingId, updates: [
                    "title": title,
                    "description": workoutText,
                    "status": "draft"
                ])
                if let parsed = parsedWorkout, !parsed.sections.isEmpty {
                    try await workoutService.replaceSetsForWorkout(workoutId: existingId, parsed: parsed)
                }
                id = existingId
            } else {
                let workout = try await workoutService.createWorkout(
                    coachId: resolvedCoachId,
                    title: title.isEmpty ? nil : title,
                    description: nil,
                    scheduledAt: nil,
                    workoutText: workoutText
                )
                if let parsed = parsedWorkout, !parsed.sections.isEmpty {
                    try await workoutService.createSetsForWorkout(workoutId: workout.id, from: parsed)
                }
                id = workout.id
            }
            savedWorkoutId = id
            isSaving = false
            return id
        } catch {
            print("[WorkoutBuilderView] saveWorkout error: \(error)")
            parseError = "Couldn't save workout. Check your connection and try again."
            isSaving = false
            return nil
        }
    }

    func loadWorkout(id: String) async {
        isLoading = true
        do {
            let workout = try await workoutService.fetchWorkout(workoutId: id)
            title = workout.title ?? ""
            workoutId = id
            if let wt = workout.description {
                workoutText = wt
                await parse(wt)
            }
        } catch {
            parseError = "Couldn't load workout: \(error)"
        }
        isLoading = false
    }
}

#Preview {
    WorkoutBuilderView(workoutId: nil)
        .environment(AuthManager())
}