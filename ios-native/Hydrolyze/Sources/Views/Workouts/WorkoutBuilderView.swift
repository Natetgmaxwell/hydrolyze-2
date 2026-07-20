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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var syntaxHintsExpanded: Bool = false
    @State private var animateIn: Bool = false

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
            // Phase 2.7 performance: warm up the parse-workout Edge Function on
            // first appearance. The function has a ~574ms cold-start on first call
            // after idle; warming it here means the coach's first keystroke is
            // served from the warm path. Empty text is a no-op on the server side
            // but the round-trip still counts as warmup.
            Task.detached(priority: .background) {
                try? await viewModel.warmupParseWorkout()
            }
            if let id = workoutId {
                await viewModel.loadWorkout(id: id)
            }
        }
        .onChange(of: viewModel.workoutText) { _, newValue in
            viewModel.debouncedParse(newValue)
        }
        .onAppear { animateIn = true }
    }

    @ViewBuilder
    private var scrollableContent: some View {
        if horizontalSizeClass == .regular {
            HStack(spacing: 16) {
                inputColumn
                    .frame(maxWidth: .infinity)
                previewColumn
                    .frame(maxWidth: .infinity)
            }
            .padding(16)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    inputColumnContent
                    previewColumnContent
                }
                .padding(16)
            }
        }
    }

    /// iPad: input side is its own ScrollView so it can scroll independently
    /// of the preview. iPhone ignores this and uses `inputColumnContent`
    /// inline inside the outer ScrollView.
    private var inputColumn: some View {
        ScrollView {
            inputColumnContent
        }
    }

    /// iPad: preview side is its own ScrollView so it can scroll independently
    /// of the input. iPhone ignores this and uses `previewColumnContent`
    /// inline inside the outer ScrollView.
    private var previewColumn: some View {
        ScrollView {
            previewColumnContent
        }
    }

    /// Shared input-side VStack. Title, syntax hints, text editor, parse
    /// status. Reused on both iPad (wrapped in `inputColumn`'s ScrollView)
    /// and iPhone (inlined in the outer ScrollView's VStack).
    private var inputColumnContent: some View {
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

            syntaxHintsCard

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
                        Text("Write your practice...")
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
        }
    }

    /// Shared preview-side VStack. Loading spinner or WorkoutPreview.
    /// Reused on both iPad (wrapped in `previewColumn`'s ScrollView) and
    /// iPhone (inlined in the outer ScrollView's VStack).
    private var previewColumnContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if viewModel.isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                        .tint(Color.accentCyan)
                    Spacer()
                }
                .padding(.vertical, 20)
            } else {
                WorkoutPreview(
                    workout: viewModel.parsedWorkout ?? ParsedWorkout(title: nil, sections: []),
                    onRemoveRepGroup: { sectionIdx, namedSetIdx, rgIdx in
                        viewModel.removeRepGroup(
                            sectionIndex: sectionIdx,
                            namedSetIndex: namedSetIdx,
                            repGroupIndex: rgIdx
                        )
                    }
                )
            }
        }
    }

    /// Persistent "Workout Syntax" expandable card. Lives between the title
    /// field and the practice editor so coaches always know what shape the
    /// parser expects — the inline placeholder alone vanished on first
    /// keystroke and left new coaches without a reference.
    private var syntaxHintsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : Animations.springSoft) {
                    syntaxHintsExpanded.toggle()
                }
                Haptics.selection()
            } label: {
                HStack(spacing: 6) {
                    Text("WORKOUT SYNTAX")
                        .font(.eyebrow)
                        .foregroundColor(Color.textFaint)
                        .tracking(1.2)
                    Spacer()
                    Image(systemName: syntaxHintsExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color.textFaint)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if syntaxHintsExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    syntaxHintRow("Sets: 4×100 free @1:30")
                    syntaxHintRow("Intervals: @1:30  /  on 2:00  /  on 1:30 rest")
                    syntaxHintRow("Gear: paddles  /  pull buoy  /  fins  /  kickboard")
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    )
                )
            }
        }
        .background(Color.bgRaised)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.divider, lineWidth: 1)
        )
        .opacity(animateIn ? 1.0 : 0.0)
        .scaleEffect(animateIn ? 1.0 : 0.98)
        .animation(reduceMotion ? nil : Animations.springSoft, value: animateIn)
    }

    private func syntaxHintRow(_ text: String) -> some View {
        Text(text)
            .font(Font.jetBrainsMono(size: 13, weight: .medium))
            .foregroundColor(Color.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(Color.bgInset.opacity(0.4))
            .cornerRadius(6)
    }

    private var parseStatusLine: some View {
        Group {
            if let error = viewModel.parseError {
                Text("⚠ \(error)")
                    .font(.caption)
                    .foregroundColor(Color.accentAmber)
            } else if viewModel.isPendingParse && !viewModel.isLoading {
                // Tiny pulse to acknowledge the keystroke landed.
                Text("Parsing...")
                    .font(.caption)
                    .foregroundColor(Color.textMuted)
                    .phaseAnimator(
                        reduceMotion ? [1.0] : [1.0, 0.7, 1.0],
                        trigger: viewModel.isPendingParse
                    ) { content, alpha in
                        content.opacity(alpha)
                    } animation: { _ in
                        .easeInOut(duration: 0.8)
                    }
            } else if viewModel.isLoading && viewModel.parsedWorkout != nil {
                // Mid-debounce: parser is working, but the previous
                // successful parse is still on screen. Show a quiet
                // pulse so the coach knows their keystroke registered
                // and a re-parse is in flight.
                Text("Parsing...")
                    .font(.caption)
                    .foregroundColor(Color.textMuted)
                    .phaseAnimator(
                        reduceMotion ? [1.0] : [1.0, 0.6, 1.0],
                        trigger: viewModel.isLoading
                    ) { content, alpha in
                        content.opacity(alpha)
                    } animation: { _ in
                        .easeInOut(duration: 1.4)
                    }
            } else if viewModel.parsedWorkout != nil {
                let count = viewModel.parsedWorkout?.sections.flatMap { $0.namedSets }.flatMap { $0.repGroups }.count ?? 0
                Text("✓ \(count) sets parsed")
                    .font(.caption)
                    .foregroundColor(Color.statusSuccess)
            }
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            // Primary: save + open the schedule sheet in one tap. Captures
            // the 95% coach flow ("write it, send it to a day").
            Button {
                Task {
                    if await viewModel.saveWorkout(authManager: authManager) != nil {
                        showScheduleSheet = true
                    }
                }
            } label: {
                Text(viewModel.isEditMode ? "Update & Schedule" : "Save & Schedule")
                    .font(.titleSmall)
                    .foregroundColor(Color.textOnAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(Color.accentCyan)
                    .cornerRadius(12)
            }
            .disabled(!viewModel.canSave || viewModel.isSaving)
            .opacity(viewModel.canSave ? 1 : 0.5)

            // Secondary: save without scheduling. The 5% "I'll come back
            // to schedule this" case. Quiet, no chrome — just a tap target.
            Button {
                Task {
                    if await viewModel.saveWorkout(authManager: authManager) != nil {
                        dismiss()
                    }
                }
            } label: {
                Text("Save as Draft")
                    .font(.captionStrong)
                    .foregroundColor(Color.textMuted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .contentShape(Rectangle())
            }
            .disabled(!viewModel.canSave || viewModel.isSaving)
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
    @Published var isPendingParse: Bool = false

    var workoutId: String?
    var canSave: Bool { parsedWorkout?.sections.isEmpty == false }
    var isEditMode: Bool { workoutId != nil }
    var hasContent: Bool { !title.isEmpty || !workoutText.isEmpty }

    private let workoutService = WorkoutService()
    private var debounceTask: Task<Void, Never>?

    private struct CachedParse {
        let trimmedText: String
        let workout: ParsedWorkout
    }
    private var cache: [String: CachedParse] = [:]  // key: hash of trimmedText
    private var lastSentText: String = ""
    private let cacheLimit = 50

    private func cacheKey(for text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
    }

    func debouncedParse(_ text: String) {
        debounceTask?.cancel()
        guard !text.isEmpty else {
            parsedWorkout = nil
            parseError = nil
            parseSuccess = false
            isPendingParse = false
            return
        }

        let key = cacheKey(for: text)
        if let cached = cache[key] {
            parsedWorkout = cached.workout
            return
        }

        if lastSentText == text {
            return
        }

        let debounceNs: UInt64
        switch text.count {
        case ..<50:  debounceNs = 150_000_000
        case 50..<200: debounceNs = 300_000_000
        default: debounceNs = 500_000_000
        }
        isPendingParse = true
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: debounceNs - 50_000_000)
            guard !Task.isCancelled else { return }
            isPendingParse = false
            await parse(text)
        }
    }

    func parse(_ text: String) async {
        // 1. On-device parse first (1-10ms).
        let syncResult = workoutService.parseWorkoutSync(text)
        let syncCount = syncResult.sections.flatMap { $0.namedSets }.flatMap { $0.repGroups }.count
        await MainActor.run {
            parsedWorkout = syncResult
            parseError = nil
            isLoading = true  // keep showing the parsing indicator while we reconcile
        }

        // 2. Server reconciliation in the background (~200ms warm).
        do {
            let serverResult = try await workoutService.parseWorkout(text: text)
            let serverCount = serverResult.sections.flatMap { $0.namedSets }.flatMap { $0.repGroups }.count
            // Server is canonical — always prefer its output when it produced
            // anything. The on-device parser is a latency-hiding placeholder;
            // it can produce the same rep-group COUNT but with worse fields
            // (missing stroke, wrong interval, no note). Only fall back to
            // the sync result when the server returned nothing.
            if serverCount > 0 {
                await MainActor.run {
                    parsedWorkout = serverResult
                }
            }
            let key = cacheKey(for: text)
            cache[key] = CachedParse(trimmedText: text, workout: serverResult)
            lastSentText = text
            if cache.count > cacheLimit, let oldestKey = cache.keys.first {
                cache.removeValue(forKey: oldestKey)
            }
            await MainActor.run {
                parseSuccess = true
                isPendingParse = false
                isLoading = false
            }
        } catch {
            await MainActor.run {
                // Server failed; keep the sync result, clear isLoading.
                isPendingParse = false
                isLoading = false
            }
        }
    }

    func warmupParseWorkout() async {
        do {
            _ = try await workoutService.parseWorkout(text: "")
        } catch {
            // ignore — this is a warmup, errors don't matter
        }
    }

    /// Remove a single parsed rep group from the local parsedWorkout tree.
    /// Triggered by long-press → context menu in WorkoutPreview. Indices
    /// are into sections / namedSets / repGroups respectively. Drops
    /// empty named sets and sections to keep the tree minimal.
    /// The source `workoutText` is NOT rewritten — the next save will
    /// persist whatever the parser last produced (minus the removed row).
    /// The coach can still re-parse by editing the text if they want.
    func removeRepGroup(sectionIndex: Int, namedSetIndex: Int, repGroupIndex: Int) {
        guard var workout = parsedWorkout else { return }
        guard workout.sections.indices.contains(sectionIndex) else { return }

        var section = workout.sections[sectionIndex]
        guard section.namedSets.indices.contains(namedSetIndex) else { return }

        var namedSet = section.namedSets[namedSetIndex]
        guard namedSet.repGroups.indices.contains(repGroupIndex) else { return }

        namedSet.repGroups.remove(at: repGroupIndex)

        if namedSet.repGroups.isEmpty {
            section.namedSets.remove(at: namedSetIndex)
        } else {
            section.namedSets[namedSetIndex] = namedSet
        }

        if section.namedSets.isEmpty {
            workout.sections.remove(at: sectionIndex)
        } else {
            workout.sections[sectionIndex] = section
        }

        parsedWorkout = workout
        Haptics.warning()
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