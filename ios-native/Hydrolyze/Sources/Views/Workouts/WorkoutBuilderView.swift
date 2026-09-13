import SwiftUI
import os.log
import Supabase

/// WorkoutBuilderView — natural language workout creation with live preview.
/// Uses debounced input to call the Edge Function parser and renders via
/// WorkoutStructureView (V0.55 S1) → WorkoutPreview. S1 routed the preview
/// through the shared render surface so the builder and the details page
/// cannot drift in their fragment-faithful projection.
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
            // V0.54 S3.3c (2026-09-10): standard iOS keyboard accessory
            // with a Done button. Coaches typing a practice hit "Done"
            // to dismiss the software keyboard, which exposes the
            // Save & Schedule / Save as Draft buttons in the pinned
            // CTA footer. Without this, after a multi-line paste the
            // only path to Save was "drag the ScrollView" — and the
            // coach on a phone in a busy pool deck doesn't know that.
            // ToolbarItemGroup(placement: .keyboard) attaches the
            // bar to whichever field (title or practice) is focused.
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        isTextFieldFocused = false
                    }
                    .fontWeight(.semibold)
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
            // RPE flywheel: load the coach's vocabulary mappings so the
            // preview can resolve ambiguous terms silently if they've
            // already been mapped.
            await VocabularyService.shared.loadVocabulary()

            #if DEBUG
            // V0.46 Slice 5: screenshot harness — seed a parsed practice.
            // The real parse is a server round-trip; the demo path keeps
            // it local so the harness has no network dependency.
            if ProcessInfo.processInfo.arguments.contains("-v46-demo-builder") {
                viewModel.seedV46DemoParsedWorkout()
                return
            }
            // V0.53.1 Design A screenshot harness: seed the jodie-09
            // Purposeful Threshold workout (including the
            // 4×50 @ 1:00 / 25 event rhythm / 25 easy composite that
            // Design A is built to render). Local seed, no network.
            if ProcessInfo.processInfo.arguments.contains("-v0531-design-a-builder") {
                viewModel.seedV0531DesignABuilder()
                return
            }
            // V0.53.2 mode-selection screenshot harnesses: isolated
            // seeds for each of the three rendering modes so the
            // visual reviewer can confirm the mode dispatch without
            // scanning the full jodie-09 Purposeful Threshold
            // workout. Mode 1 (track) is already exercised by
            // -v0531-design-a-builder; the new harnesses cover
            // Modes 2 (uniform) and 3 (per-rep progression) in
            // isolation.
            if ProcessInfo.processInfo.arguments.contains("-v0532-mode-uniform") {
                viewModel.seedV0532ModeUniform()
                return
            }
            if ProcessInfo.processInfo.arguments.contains("-v0532-mode-progression") {
                viewModel.seedV0532ModeProgression()
                return
            }
            // V0.54 details-tidy (2026-09-12): rich-renderer verification
            // harness. Seeds a fully-formed ParsedWorkout matching the
            // user-stated spec `4x25 free as 12.5 strong / 12.5 easy,
            // descend 1-4, race rhythm` so the details-page rich-renderer
            // can be verified without depending on the parser round-trip.
            // Unlike the v053* modes, this DOES NOT force preview-only —
            // the full builder with action buttons renders, so the
            // seeded workout can be saved as draft and then opened in
            // the WorkoutDetailView for details-page verification.
            if ProcessInfo.processInfo.arguments.contains("-rich-test") {
                viewModel.seedRichTestWorkout()
                return
            }
            #endif

            // Phase 2.7 performance: warm up the parse-workout Edge Function on
            // first appearance. The function has a ~574ms cold-start on first call
            // after idle; warming it here means the coach's first keystroke is
            // served from the warm path. Empty text is a no-op on the server side
            // but the round-trip still counts as warmup.
            Task.detached(priority: .background) {
                // warmupParseWorkout is non-throwing (catches internally) —
                // `try?` is invalid here under strict concurrency.
                await viewModel.warmupParseWorkout()
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
        // V0.53.1 Design A verification: when launched with the
        // screenshot-harness arg, render the preview column only.
        // The screenshot harness has no way to scroll the iPhone
        // ScrollView programmatically (simctl has no tap; CGEvent
        // posts don't reach the sim runtime); showing the input
        // column pushes the preview off-screen. Preview-only mode
        // captures the entire RepCard layout in one screenshot.
        // V0.53.2 (2026-09-08): extended to the new mode-isolation
        // harnesses (-v0532-mode-uniform, -v0532-mode-progression)
        // — same preview-only constraint, same screenshot strategy.
        // V0.54 details-tidy (2026-09-12): -rich-test gets the FULL
        // builder (with action buttons) so the seeded workout can be
        // saved as a draft and verified on the WorkoutDetailView
        // surface — the v053* modes are preview-only because they're
        // single-purpose screenshot harnesses, but -rich-test is an
        // end-to-end verification flow.
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-v0531-design-a-builder")
            || args.contains("-v0532-mode-uniform")
            || args.contains("-v0532-mode-progression") {
            previewColumnContent
                .padding(16)
        } else {
            scrollableContentBody
        }
        #else
        scrollableContentBody
        #endif
    }

    @ViewBuilder
    private var scrollableContentBody: some View {
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
            // V0.54 S3.3c (2026-09-10): dismissing the keyboard by
            // dragging the ScrollView is one of two standard iOS
            // affordances for "I'm done typing, I want to tap Save".
            // Without this, the software keyboard stays up and all
            // taps route to UIRemoteKeyboardWindow — the pinned CTA
            // footer in the parent VStack is unreachable on iPhone.
            // `.interactively` matches Notes / Mail / Messages feel.
            .scrollDismissesKeyboard(.interactively)
        }
    }

    /// iPad: input side is its own ScrollView so it can scroll independently
    /// of the preview. iPhone ignores this and uses `inputColumnContent`
    /// inline inside the outer ScrollView.
    private var inputColumn: some View {
        ScrollView {
            inputColumnContent
        }
        .scrollDismissesKeyboard(.interactively)
    }

    /// iPad: preview side is its own ScrollView so it can scroll independently
    /// of the input. iPhone ignores this and uses `previewColumnContent`
    /// inline inside the outer ScrollView.
    private var previewColumn: some View {
        ScrollView {
            previewColumnContent
        }
        .scrollDismissesKeyboard(.interactively)
    }

    /// Shared input-side VStack. Title, syntax hints, text editor, parse
    /// status. Reused on both iPad (wrapped in `inputColumn`'s ScrollView)
    /// and iPhone (inlined in the outer ScrollView's VStack).
    private var inputColumnContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Workout builder")
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
                // V0.54 S3.3c (2026-09-10): bind the title field to the same
                // FocusState as the practice TextEditor so a single keyboard
                // toolbar / Done button dismisses either input. Without this,
                // tapping the title keeps the keyboard up but `Done` only
                // sees the TextEditor's focus flag.
                .focused($isTextFieldFocused)

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
                        .stroke(viewModel.isFocused ? Color.textMuted : Color.divider, lineWidth: viewModel.isFocused ? 2 : 1)
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
            // FIX (2026-08-19): speed — the sync parse lands in ~10ms,
            // but this branch hid it behind a spinner for the whole
            // server round-trip (1-5s). The coach saw a blank preview
            // while data was already available. Spinner only when there
            // is NO preview at all yet.
            if viewModel.isLoading && viewModel.parsedWorkout == nil {
                HStack {
                    Spacer()
                    ProgressView()
                        .tint(Color.textMuted)
                    Spacer()
                }
                .padding(.vertical, 20)
            } else {
                // V0.55 S1: route through the shared
                // `WorkoutStructureView` render surface. Both the
                // builder preview and the details page now share
                // the same component; the builder feeds it a
                // pre-built `ParsedWorkout` (from the parser
                // pipeline) via the `parsedWorkout:` initializer,
                // the details page feeds it the DB-row
                // `Workout` + `[WorkoutSet]` shape via the
                // `workout:`/`sets:` initializer. One render
                // surface, two call sites — both go through the
                // same `WorkoutPreview` underneath. S2/S3/S4 build
                // on top of this without drift risk.
                WorkoutStructureView(
                    parsedWorkout: viewModel.parsedWorkout ?? ParsedWorkout(title: nil, sections: []),
                    onRemoveRepGroup: { sectionIdx, namedSetIdx, rgIdx in
                        viewModel.removeRepGroup(
                            sectionIndex: sectionIdx,
                            namedSetIndex: namedSetIdx,
                            repGroupIndex: rgIdx
                        )
                    },
                    degraded: viewModel.parsedWorkout?.degraded == true,
                    degradedReason: viewModel.parsedWorkout?.degradedReason,
                    onRetry: {
                        Task { await viewModel.parse(viewModel.workoutText) }
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
                    Text("Workout syntax")
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
                    syntaxHintRow("Dive: from a dive  /  off the blocks")
                    syntaxHintRow("Suit: in a suit  /  tech suit  /  racing suit")
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
                        // V0.44 Slice 3 (2026-08-18): tell 8 — micro-
                        // interaction gap. Save completion had no tactile
                        // resolution. Haptics.success() plays the
                        // "ding-ding-rise" pattern: the form-submission
                        // signal, matching the documented
                        // Haptics.success() use case ("form submission
                        // success, save complete").
                        Haptics.success()
                        showScheduleSheet = true
                    }
                }
            } label: {
                Text(viewModel.isEditMode ? "Update & Schedule" : "Save & Schedule")
                    .font(.titleSmall)
                    .foregroundColor(Color.textOnAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(Color.accentAction)
                    .cornerRadius(12)
            }
            .disabled(!viewModel.canSave || viewModel.isSaving)
            .opacity(viewModel.canSave ? 1 : 0.5)

            // Secondary: save without scheduling. The 5% "I'll come back
            // to schedule this" case. Quiet, no chrome — just a tap target.
            Button {
                Task {
                    if await viewModel.saveWorkout(authManager: authManager) != nil {
                        // V0.44 Slice 3 (2026-08-18): tell 8 — same
                        // save-success haptic as the primary button.
                        // Both call sites succeed via the same VM
                        // method; the haptic is the form-submission
                        // signal regardless of which next-step the
                        // coach chose (schedule-sheet or dismiss).
                        Haptics.success()
                        dismiss()
                    }
                }
            } label: {
                Text("Save as Draft")
                    .font(.captionStrong)
                    .foregroundColor(Color.textMuted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
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

    /// FIX (2026-08-19): hard timeout via task group — the URLSession
    /// timeoutInterval does not fire reliably on flaky cellular/QUIC
    /// paths (observed 180s hangs). Same pattern as
    /// TimingViewModel.withTimeout. The first task to complete wins;
    /// the loser is cancelled.
    private func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        label: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw NSError(domain: "WorkoutBuilder", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "\(label) timed out after \(Int(seconds))s"])
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

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
        // 1. On-device parse first (1-10ms) — only to keep the preview
        //    populated during the 500ms debounce + ~200ms server warm.
        let syncResult = workoutService.parseWorkoutSync(text)
        let syncSectionCount = syncResult.sections.count
        let syncSetCount = syncResult.sections.flatMap { $0.namedSets }.flatMap { $0.repGroups }.count
        await MainActor.run {
            parsedWorkout = syncResult
            parseError = nil
            isLoading = true  // keep showing the parsing indicator while we reconcile
        }
        NSLog("[PARSE] sync: \(syncSectionCount) sections, \(syncSetCount) sets")

        // 2. Server reconciliation. The server is canonical for both
        //    rep-group count AND section grouping (the on-device parser
        //  ……  flattens everything into a single unnamed section, so
        //    section dividers like "Pool warm-up — 1,000m" only appear
        //    when we adopt the server result). Always prefer the server
        //    output when the call succeeds, regardless of count —
        //    even an empty server result is better than the sync result,
        //    because empty server result means "I correctly parsed this
        //    and found nothing" while sync result means "I parsed this
        //    with the old single-section fallback". The fallback to sync
        //    only fires when the server call ITSELF throws (network error,
        //    auth failure, JSON decode error).
        do {
            // FIX (2026-08-19): hard timeout on the server call. The
            // URLSession timeoutInterval (30s) does NOT fire reliably on
            // flaky cellular/QUIC paths (observed: 180s hangs on device
            // and simulator). The task-group timeout is the real ceiling —
            // same pattern as TimingViewModel.withTimeout.
            let serverResult = try await withTimeout(30, label: "parse-workout") {
                try await self.workoutService.parseWorkout(text: text)
            }
            let serverSectionCount = serverResult.sections.count
            let serverSetCount = serverResult.sections.flatMap { $0.namedSets }.flatMap { $0.repGroups }.count
            NSLog("[PARSE] server: \(serverSectionCount) sections, \(serverSetCount) sets — adopting")
            await MainActor.run {
                parsedWorkout = serverResult
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
            NSLog("[PARSE] server FAILED: \(error.localizedDescription) — keeping sync result")
            // Server failed; surface the error and keep the sync result.
            await MainActor.run {
                parseError = "Server parse failed — using on-device fallback. \(error.localizedDescription)"
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
            // V0.54 S3.3d (2026-09-10): use the bounded-retry wrapper
            // so a wedged iOS URLSession connection (HTTP/3 QUIC) can't
            // hang the save path for 60s+ per attempt. S3.3c observed
            // 18 stacked ~121s GETs to /rest/v1/coaches ending in
            // cancel — the banner only showed the .single() decode
            // error, not the underlying transport failure.
            let resolvedCoachId = try await authManager.ensureCoachWithRetry()
            let id: String
            if let existingId = workoutId {
                _ = try await workoutService.updateWorkout(workoutId: existingId, updates: [
                    "title": title,
                    "workout_text": workoutText,
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
            // V0.54 S3.3c (2026-09-10): surface the underlying error
            // so on-device failures are diagnosable from the in-app
            // parseStatusLine (line ~345). The previous "Check your
            // connection" banner was the only on-device signal and
            // it told us nothing — one reproduction got a 121s hang
            // then a cancel with no further detail.
            os_log("[WorkoutBuilder] saveWorkout error: %{public}@", log: .default, type: .error, String(describing: error))
            // V0.54 S3.3d (2026-09-10): S3.3c's banner only printed
            // `error.localizedDescription` which is the wrapper text
            // (e.g. "Cannot coerce the result to a single JSON
            // object") — it hid the actual cause. Pattern-match
            // PostgrestError, URLError, TimeoutError, DecodingError,
            // AuthServiceError so the banner includes the underlying
            // code/message instead.
            parseError = Self.formatSaveError(error)
            isSaving = false
            return nil
        }
    }

    /// V0.54 S3.3d (2026-09-10): convert a save-path error into a
    /// user-facing string that includes the underlying PostgREST /
    /// URLSession / decode cause. See S3.3d commit note.
    private static func formatSaveError(_ error: Error) -> String {
        let nsError = error as NSError
        if let postgrest = error as? PostgrestError {
            let code = postgrest.code.map { " [PostgREST \($0)]" } ?? ""
            return "Couldn't save workout: \(postgrest.message)\(code)"
        }
        if let urlError = error as? URLError {
            return "Couldn't save workout (network): \(urlError.code.rawValue) \(urlError.localizedDescription)"
        }
        if let timeout = error as? TimeoutError {
            return "Couldn't save workout: \(timeout.localizedDescription). Check connection."
        }
        if let decoding = error as? DecodingError {
            return "Couldn't save workout (response decode failed): \(String(describing: decoding))"
        }
        if let authError = error as? AuthServiceError, let desc = authError.errorDescription {
            return "Couldn't save workout: \(desc)"
        }
        return "Couldn't save workout: \(nsError.domain) #\(nsError.code) — \(nsError.localizedDescription)"
    }

    func loadWorkout(id: String) async {
        isLoading = true
        do {
            let workout = try await workoutService.fetchWorkout(workoutId: id)
            title = workout.title ?? ""
            workoutId = id
            if let wt = workout.description {
                workoutText = wt
                // FIX (2026-08-19): route through debouncedParse instead
                // of parse() directly. The direct call raced the .onChange
                // debounced call — two concurrent server parses, and on a
                // flaky network the device froze with no timeout firing.
                // debouncedParse cancels the prior task and dedupes.
                debouncedParse(wt)
            }
        } catch {
            parseError = "Couldn't load workout: \(error)"
        }
        isLoading = false
    }

    #if DEBUG
    /// V0.53.1 Design A screenshot harness (2026-09-08): seeds the
    /// builder with the jodie-09 Purposeful Threshold workout —
    /// including the 4×50 @ 1:00 / 25 event rhythm / 25 easy
    /// composite that the user rejected for its "tag continuous
    /// onto the instructions" feel. This seed reproduces the same
    /// ParsedWorkout shape the live parse-workout edge function
    /// returns (live curl confirmed at V0.53: 4 reps, dist 50,
    /// interval 1:00, fragments=[{race_pace 25m}, {easy 25m}]),
    /// so Design A's RepCard layout renders the exact bar the
    /// user is approving.
    ///
    /// Triggered by `-v0531-design-a-builder`. Renders without
    /// a server round-trip — preview is fed directly into the
    /// parsedWorkout property and into the parse cache.
    func seedV0531DesignABuilder() {
        let text = """
        Purposeful Threshold

        Warm-Up — 1,200 m

        4 × 150 @ 2:20–2:30
        Each:
        50 @ 65%
        50 @ 70%
        50 @ 75%

        4 × 100 @ 1:35–1:40
        25 scull
        50 strong aerobic @ 75-80%
        25 easy

        4 × 50 @ 1:00
        Descend:
        1 = 70%
        2 = 75%
        3 = 80%
        4 = ~85%

        4 × 25 @ :40
        12.5 strong + 12.5 easy.

        100 easy

        Main Set

        50/100
        3 rounds
        4 × 100 @ 80–85%
        200 easy
        4 × 50 @ 1:00
        25 event rhythm / 25 easy
        """

        // Section 1 — Warm-Up
        let warmUp = ParsedSection(
            title: "Warm-Up",
            namedSets: [
                ParsedNamedSet(label: "Build", note: nil, repGroups: [
                    // 4 × 150 @ 2:20-2:30 — Each: 50@65% / 50@70% / 50@75%.
                    // V0.53.2 (2026-09-08): the live parser emits
                    // 3 fragments per rep for this set (one per
                    // Each-line), each with its own percent_range
                    // intensity. Three fragments × distinct
                    // intensity types per rep = within-rep intensity
                    // change → Mode 1 (segment track) renders.
                    // The previous seed had it as a single rg with
                    // the Each: lines collapsed into a note; the
                    // V0.53.2 mode-selection rules reclassified
                    // that as Mode 2 (uniform), which would suppress
                    // the track — wrong for this case. Now we ship
                    // the live-parse shape so the screenshot
                    // harness reflects the actual parser output.
                    ParsedRepGroup(reps: 4, distance: 150, stroke: "Free",
                                   interval: "2:20-2:30", intensity: nil,
                                   pacing: nil, pattern: [], patternType: nil,
                                   connectors: nil, note: "Each: 50 @ 65% / 50 @ 70% / 50 @ 75%",
                                   gear: nil, gearOptional: false, descend: nil,
                                   details: nil, dive: false, suit: false,
                                   ambiguousTerm: nil,
                                   fragments: [
                                       ParsedFragment(id: "frag-150-a", distance: 50, stroke: nil,
                                                      instruction: nil,
                                                      intensity: ParsedIntensity(type: .percent_range, label: "65%"),
                                                      intensityType: "percent_range", intensityLabel: "65%",
                                                      startType: nil, suit: nil, gear: nil,
                                                      descriptor: "65%", confidence: 1.0,
                                                      restAfter: nil),
                                       ParsedFragment(id: "frag-150-b", distance: 50, stroke: nil,
                                                      instruction: nil,
                                                      intensity: ParsedIntensity(type: .percent_range, label: "70%"),
                                                      intensityType: "percent_range", intensityLabel: "70%",
                                                      startType: nil, suit: nil, gear: nil,
                                                      descriptor: "70%", confidence: 1.0,
                                                      restAfter: nil),
                                       ParsedFragment(id: "frag-150-c", distance: 50, stroke: nil,
                                                      instruction: nil,
                                                      intensity: ParsedIntensity(type: .percent_range, label: "75%"),
                                                      intensityType: "percent_range", intensityLabel: "75%",
                                                      startType: nil, suit: nil, gear: nil,
                                                      descriptor: "75%", confidence: 1.0,
                                                      restAfter: nil),
                                   ],
                                   sourceLine: nil, zoneTerm: nil,
                                   perRepTargets: nil),
                    // 4 × 100 @ 1:35-1:40 with fragments (25 scull / 50 strong / 25 easy).
                    // Mirrors the live parse shape (live curl at V0.53.1):
                    // frag0 {dist:25, intensity:null, instruction:"scull"},
                    // frag1 {dist:50, intensity:{type:"percent_range", label:"75-80%"}, instruction:"strong aerobic @ 75-80%"},
                    // frag2 {dist:25, intensity:{type:"easy", label:"easy"}, instruction:"easy"}
                    ParsedRepGroup(reps: 4, distance: 100, stroke: nil,
                                   interval: "1:35-1:40", intensity: nil,
                                   pacing: nil, pattern: [], patternType: nil,
                                   connectors: nil, note: nil,
                                   gear: nil, gearOptional: false, descend: nil,
                                   details: nil, dive: false, suit: false,
                                   ambiguousTerm: nil,
                                   fragments: [
                                       ParsedFragment(id: "frag-100-a", distance: 25, stroke: nil,
                                                      instruction: "scull", intensity: nil,
                                                      intensityType: nil, intensityLabel: nil,
                                                      startType: nil, suit: nil, gear: nil,
                                                      descriptor: nil, confidence: 1.0,
                                                      restAfter: nil),
                                       ParsedFragment(id: "frag-100-b", distance: 50, stroke: nil,
                                                      instruction: "strong aerobic @ 75-80%",
                                                      intensity: ParsedIntensity(type: .percent_range, label: "75-80%"),
                                                      intensityType: "percent_range", intensityLabel: "75-80%",
                                                      startType: nil, suit: nil, gear: nil,
                                                      descriptor: nil, confidence: 1.0,
                                                      restAfter: nil),
                                       ParsedFragment(id: "frag-100-c", distance: 25, stroke: nil,
                                                      instruction: "easy",
                                                      intensity: ParsedIntensity(type: .easy, label: "easy"),
                                                      intensityType: "easy", intensityLabel: "easy",
                                                      startType: nil, suit: nil, gear: nil,
                                                      descriptor: nil, confidence: 1.0,
                                                      restAfter: nil),
                                   ],
                                   sourceLine: nil, zoneTerm: nil),
                    // 4 × 50 @ 1:00 — Descend ladder (4 fragments each rep, but for
                    // screenshot simplicity use a single non-composite repGroup
                    // with descend="1-4" so the V0.46-style render kicks in.
                    // V0.53.2 (2026-09-08): the live parser emits
                    // explicit per-rep targets for the Descend
                    // ladder ("70%", "75%", "80%", "~85%"). The
                    // harness now supplies them via perRepTargets
                    // so the Mode 3 render renders the per-card
                    // target badges + chevrons. The previous seed
                    // had only the note + descend="1-4" — that
                    // route synthesized targets from a percent-range
                    // intensity, but for "%" labeled ladders the
                    // harness can supply the labels verbatim.
                    ParsedRepGroup(reps: 4, distance: 50, stroke: nil,
                                   interval: "1:00", intensity: nil,
                                   pacing: nil, pattern: [], patternType: nil,
                                   connectors: nil,
                                   note: "Descend: 1 = 70% / 2 = 75% / 3 = 80% / 4 = ~85%",
                                   gear: nil, gearOptional: false,
                                   descend: "1-4", details: nil,
                                   dive: false, suit: false, ambiguousTerm: nil,
                                   fragments: nil, sourceLine: nil, zoneTerm: nil,
                                   perRepTargets: ["70%", "75%", "80%", "~85%"]),
                    // 4 × 25 @ :40 / 12.5 strong + 12.5 easy — composite with rest
                    ParsedRepGroup(reps: 4, distance: 25, stroke: nil,
                                   interval: "0:40", intensity: nil,
                                   pacing: nil, pattern: [], patternType: nil,
                                   connectors: nil,
                                   note: "12.5 strong + 12.5 easy",
                                   gear: nil, gearOptional: false, descend: nil,
                                   details: nil, dive: false, suit: false,
                                   ambiguousTerm: nil,
                                   fragments: [
                                       ParsedFragment(id: "frag-25-a", distance: 13, distanceLabel: "12.5",
                                                      stroke: nil,
                                                      instruction: "strong",
                                                      intensity: ParsedIntensity(type: .aerobic, label: "strong"),
                                                      intensityType: "aerobic", intensityLabel: "strong",
                                                      startType: nil, suit: nil, gear: nil,
                                                      descriptor: "strong", confidence: 1.0,
                                                      restAfter: nil),
                                       ParsedFragment(id: "frag-25-b", distance: 13, distanceLabel: "12.5",
                                                      stroke: nil,
                                                      instruction: "easy",
                                                      intensity: ParsedIntensity(type: .easy, label: "easy"),
                                                      intensityType: "easy", intensityLabel: "easy",
                                                      startType: nil, suit: nil, gear: nil,
                                                      descriptor: "easy", confidence: 1.0,
                                                      restAfter: nil),
                                   ],
                                   sourceLine: nil, zoneTerm: nil),
                    ParsedRepGroup(reps: 1, distance: 100, stroke: nil,
                                   interval: nil,
                                   intensity: ParsedIntensity(type: .easy, label: "easy"),
                                   pacing: nil, pattern: [], patternType: nil,
                                   connectors: nil, note: nil,
                                   gear: nil, gearOptional: false, descend: nil,
                                   details: nil, dive: false, suit: false,
                                   ambiguousTerm: nil, fragments: nil,
                                   sourceLine: nil, zoneTerm: "easy"),
                ])
            ]
        )

        // Section 2 — Main Set (this is where the user's 4 × 50 @ 1:00 / 25 event rhythm / 25 easy lives)
        let mainSet = ParsedSection(
            title: "Main Set",
            namedSets: [
                ParsedNamedSet(label: "Threshold", note: nil, repGroups: [
                    ParsedRepGroup(reps: 4, distance: 100, stroke: nil,
                                   interval: nil,
                                   intensity: ParsedIntensity(type: .threshold, label: "80–85%"),
                                   pacing: nil, pattern: [], patternType: nil,
                                   connectors: nil, note: nil,
                                   gear: nil, gearOptional: false, descend: nil,
                                   details: nil, dive: false, suit: false,
                                   ambiguousTerm: nil, fragments: nil,
                                   sourceLine: nil, zoneTerm: "threshold"),
                    ParsedRepGroup(reps: 1, distance: 200, stroke: nil,
                                   interval: nil,
                                   intensity: ParsedIntensity(type: .easy, label: "easy"),
                                   pacing: nil, pattern: [], patternType: nil,
                                   connectors: nil, note: nil,
                                   gear: nil, gearOptional: false, descend: nil,
                                   details: nil, dive: false, suit: false,
                                   ambiguousTerm: nil, fragments: nil,
                                   sourceLine: nil, zoneTerm: "easy"),
                    // THE composite that Design A is built to render.
                    // Live curl confirmed: reps=4, distance=50, interval='1:00',
                    // fragments=[{race_pace 25m}, {easy 25m}].
                    ParsedRepGroup(reps: 4, distance: 50, stroke: nil,
                                   interval: "1:00", intensity: nil,
                                   pacing: nil, pattern: [], patternType: nil,
                                   connectors: nil,
                                   note: "25 event rhythm / 25 easy",
                                   gear: nil, gearOptional: false, descend: nil,
                                   details: nil, dive: false, suit: false,
                                   ambiguousTerm: nil,
                                   fragments: [
                                       ParsedFragment(id: "frag-j09-a", distance: 25, stroke: nil,
                                                      instruction: nil,
                                                      intensity: ParsedIntensity(type: .race_pace, label: "event rhythm"),
                                                      intensityType: "race_pace", intensityLabel: "event rhythm",
                                                      startType: nil, suit: nil, gear: nil,
                                                      descriptor: "event rhythm", confidence: 1.0,
                                                      restAfter: nil),
                                       ParsedFragment(id: "frag-j09-b", distance: 25, stroke: nil,
                                                      instruction: nil,
                                                      intensity: ParsedIntensity(type: .easy, label: "easy"),
                                                      intensityType: "easy", intensityLabel: "easy",
                                                      startType: nil, suit: nil, gear: nil,
                                                      descriptor: "easy", confidence: 1.0,
                                                      restAfter: nil),
                                   ],
                                   sourceLine: nil, zoneTerm: nil),
                ])
            ]
        )

        let parsed = ParsedWorkout(title: "Purposeful Threshold",
                                   sections: [warmUp, mainSet],
                                   degraded: nil, degradedReason: nil)

        title = "Purposeful Threshold"
        workoutText = text
        parsedWorkout = parsed
        parseSuccess = true
        isPendingParse = false
        cache[cacheKey(for: text)] = CachedParse(trimmedText: text, workout: parsed)
        lastSentText = text
    }

    /// V0.53.2 (2026-09-08, jodie-09 user complaint on segment
    /// track rendering on uniform reps): isolated seed for Mode 2
    /// (uniform) screenshot capture. A clean 4 × 50 build set
    /// (single intensity across every rep, no fragments, no
    /// progression descriptor) so the visual reviewer can confirm
    /// the new render doesn't paint a segment track where the rep
    /// is genuinely one descriptor. Triggered by `-v0532-mode-uniform`.
    func seedV0532ModeUniform() {
        let text = """
        Uniform rep — Mode 2

        Warm-Up

        4 × 50 build @ 1:10
        """
        let warmUp = ParsedSection(
            title: "Warm-Up",
            namedSets: [
                ParsedNamedSet(label: "Build", note: nil, repGroups: [
                    // 4 × 50 build @ 1:10 — every rep is the same
                    // descriptor ("build") at the same intensity.
                    // No fragments (the rep is not split), no
                    // descend / build pacing on the rg, no
                    // per-rep targets. Mode 2 (uniform) — a
                    // plain rep card per rep, no track, no
                    // chevron. This is the case the user
                    // complained about: the previous build
                    // would have rendered an inappropriate
                    // segment track on this set.
                    ParsedRepGroup(reps: 4, distance: 50, stroke: "Free",
                                   interval: "1:10",
                                   intensity: ParsedIntensity(type: .aerobic, label: "build"),
                                   pacing: nil, pattern: [], patternType: nil,
                                   connectors: nil, note: nil,
                                   gear: nil, gearOptional: false, descend: nil,
                                   details: nil, dive: false, suit: false,
                                   ambiguousTerm: nil, fragments: nil,
                                   sourceLine: nil, zoneTerm: nil,
                                   perRepTargets: nil),
                    // 4 × 50 free easy — every rep easy, plain set.
                    // No fragments → Mode 2.
                    ParsedRepGroup(reps: 4, distance: 50, stroke: "Free",
                                   interval: nil,
                                   intensity: ParsedIntensity(type: .easy, label: "easy"),
                                   pacing: nil, pattern: [], patternType: nil,
                                   connectors: nil, note: nil,
                                   gear: nil, gearOptional: false, descend: nil,
                                   details: nil, dive: false, suit: false,
                                   ambiguousTerm: nil, fragments: nil,
                                   sourceLine: nil, zoneTerm: "easy",
                                   perRepTargets: nil),
                    // 8 × 50 free @ threshold on 1:30 — uniform
                    // single-intensity repGroup with reps > cap
                    // (8) so the ×N collapse affordance renders.
                    // Mode 2 + collapsed.
                    ParsedRepGroup(reps: 8, distance: 50, stroke: "Free",
                                   interval: "1:30",
                                   intensity: ParsedIntensity(type: .threshold, label: "threshold"),
                                   pacing: nil, pattern: [], patternType: nil,
                                   connectors: nil, note: nil,
                                   gear: nil, gearOptional: false, descend: nil,
                                   details: nil, dive: false, suit: false,
                                   ambiguousTerm: nil, fragments: nil,
                                   sourceLine: nil, zoneTerm: "threshold",
                                   perRepTargets: nil),
                ])
            ]
        )
        let parsed = ParsedWorkout(title: "Mode 2 — uniform",
                                   sections: [warmUp],
                                   degraded: nil, degradedReason: nil)
        title = "Mode 2 — uniform"
        workoutText = text
        parsedWorkout = parsed
        parseSuccess = true
        isPendingParse = false
        cache[cacheKey(for: text)] = CachedParse(trimmedText: text, workout: parsed)
        lastSentText = text
    }

    /// V0.53.2: isolated seed for Mode 3 (per-rep progression)
    /// screenshot capture. A clean Descend 4 × 50 set so the
    /// visual reviewer can confirm each card carries its own
    /// target ("70%", "75%", "80%", "~85%") with the chevron
    /// between them showing direction. Triggered by
    /// `-v0532-mode-progression`.
    func seedV0532ModeProgression() {
        let text = """
        Per-rep progression — Mode 3

        Main Set

        4 × 50 @ 1:00
        Descend:
        1 = 70%
        2 = 75%
        3 = 80%
        4 = ~85%

        4 × 100 build
        """
        let mainSet = ParsedSection(
            title: "Main Set",
            namedSets: [
                ParsedNamedSet(label: "Threshold", note: nil, repGroups: [
                    // 4 × 50 @ 1:00 — Descend ladder. Per-rep
                    // targets populated explicitly so the Mode 3
                    // render paints the badge per card.
                    ParsedRepGroup(reps: 4, distance: 50, stroke: "Free",
                                   interval: "1:00", intensity: nil,
                                   pacing: nil, pattern: [], patternType: nil,
                                   connectors: nil,
                                   note: "Descend: 1 = 70% / 2 = 75% / 3 = 80% / 4 = ~85%",
                                   gear: nil, gearOptional: false,
                                   descend: "1-4", details: nil,
                                   dive: false, suit: false, ambiguousTerm: nil,
                                   fragments: nil, sourceLine: nil, zoneTerm: nil,
                                   perRepTargets: ["70%", "75%", "80%", "~85%"]),
                    // 4 × 100 build — uniform intensity with
                    // pacing="build" → Mode 3 (per-rep build
                    // progression). No perRepTargets → chevron
                    // only (no numeric labels) — confirms the
                    // chevron-only path renders cleanly without
                    // synthesized labels.
                    ParsedRepGroup(reps: 4, distance: 100, stroke: "Free",
                                   interval: nil,
                                   intensity: ParsedIntensity(type: .aerobic, label: "build"),
                                   pacing: "build", pattern: [], patternType: nil,
                                   connectors: nil, note: nil,
                                   gear: nil, gearOptional: false, descend: nil,
                                   details: nil, dive: false, suit: false,
                                   ambiguousTerm: nil, fragments: nil,
                                   sourceLine: nil, zoneTerm: nil,
                                   perRepTargets: nil),
                ])
            ]
        )
        let parsed = ParsedWorkout(title: "Mode 3 — progression",
                                   sections: [mainSet],
                                   degraded: nil, degradedReason: nil)
        title = "Mode 3 — progression"
        workoutText = text
        parsedWorkout = parsed
        parseSuccess = true
        isPendingParse = false
        cache[cacheKey(for: text)] = CachedParse(trimmedText: text, workout: parsed)
        lastSentText = text
    }

    /// V0.46 Slice 5: screenshot-harness seed. Fills the title, the
    /// practice text, and a hand-built ParsedWorkout — the preview
    /// renders without a server round-trip. The text is also seeded
    /// into the parse cache so the .onChange debounce hits the cache
    /// instead of the Edge Function. Network is never touched.
    func seedV46DemoParsedWorkout() {
        let text = """
        400 free easy
        8×50 free @ steady
        6×100 free @ threshold on 1:30
        5×100 pull @ hard
        8×25 sprint on 45
        200 warm-down
        """
        let section = ParsedSection(
            title: nil,
            namedSets: [
                ParsedNamedSet(label: "Warm-up", note: nil, repGroups: [
                    ParsedRepGroup(reps: 1, distance: 400, stroke: "Free", interval: nil,
                                   intensity: ParsedIntensity(type: .easy, label: "easy"),
                                   zoneTerm: "easy"),
                ]),
                ParsedNamedSet(label: "Pre-set", note: nil, repGroups: [
                    ParsedRepGroup(reps: 8, distance: 50, stroke: "Free", interval: nil,
                                   intensity: ParsedIntensity(type: .aerobic, label: "steady"),
                                   zoneTerm: "steady"),
                ]),
                ParsedNamedSet(label: "Main", note: nil, repGroups: [
                    ParsedRepGroup(reps: 6, distance: 100, stroke: "Free", interval: "1:30",
                                   intensity: ParsedIntensity(type: .threshold, label: "threshold"),
                                   zoneTerm: "hard"),
                    ParsedRepGroup(reps: 5, distance: 100, stroke: nil, interval: nil,
                                   intensity: ParsedIntensity(type: .threshold, label: "hard"),
                                   zoneTerm: "hard"),
                ]),
                ParsedNamedSet(label: "Sprint", note: nil, repGroups: [
                    ParsedRepGroup(reps: 8, distance: 25, stroke: "Free", interval: "45",
                                   intensity: ParsedIntensity(type: .sprint, label: "sprint"),
                                   zoneTerm: "sprint"),
                ]),
                ParsedNamedSet(label: "Warm-down", note: nil, repGroups: [
                    ParsedRepGroup(reps: 1, distance: 200, stroke: "Free", interval: nil,
                                   intensity: ParsedIntensity(type: .easy, label: "easy"),
                                   zoneTerm: "easy"),
                ]),
            ]
        )
        let parsed = ParsedWorkout(title: nil, sections: [section], degraded: nil, degradedReason: nil)

        title = "Threshold Tuesday"
        workoutText = text
        parsedWorkout = parsed
        parseSuccess = true
        isPendingParse = false
        cache[cacheKey(for: text)] = CachedParse(trimmedText: text, workout: parsed)
        lastSentText = text
    }

    /// V0.54 details-tidy (2026-09-12): rich-renderer verification
    /// harness. Seeds the exact workout the user specified for the
    /// rich-renderer test:
    ///   `4x25 free as 12.5 strong / 12.5 easy, descend 1-4, race rhythm`
    ///
    /// The ParsedWorkout is built to exercise all four rich-renderer
    /// rules on the WorkoutDetailView:
    ///   1. fragment math visibly sums (25m parent = 12.5 + 12.5)
    ///   2. ×N exemplar shown on each fragment row
    ///   3. DESCEND shown as ladder (1-4 progression), not flattened %
    ///      range
    ///   4. coach verbatim words ("race rhythm") preserved
    ///
    /// NOT preview-only (see scrollableContent): the full builder
    /// renders with Save buttons, so the seeded workout can be saved
    /// as a draft and then opened in the WorkoutDetailView for the
    /// actual verification surface.
    func seedRichTestWorkout() {
        let text = """
        4x25 free as 12.5 strong / 12.5 easy, descend 1-4, race rhythm
        """
        // Build the fragment tree the parser would have emitted.
        // 4 reps × 2 fragments = 8 timed leaves. Each fragment is one
        // addressed timing slot.
        let fragment0 = ParsedFragment(
            id: "frag_rich_0",
            distance: 13,            // V0.53.3 server rounds 12.5 → 13 for the wire
            distanceLabel: "12.5",   // verbatim source-text for display
            stroke: "Free",
            instruction: nil,
            intensity: ParsedIntensity(type: .build, label: "strong"),
            intensityType: "build",
            intensityLabel: "strong",
            startType: "wall",
            suit: nil,
            gear: nil,
            descriptor: "strong",
            confidence: 1.0,
            restAfter: nil
        )
        let fragment1 = ParsedFragment(
            id: "frag_rich_1",
            distance: 13,
            distanceLabel: "12.5",
            stroke: "Free",
            instruction: nil,
            intensity: ParsedIntensity(type: .easy, label: "easy"),
            intensityType: "easy",
            intensityLabel: "race rhythm",  // verbatim word from coach text
            startType: "wall",
            suit: nil,
            gear: nil,
            descriptor: "race rhythm",
            confidence: 1.0,
            restAfter: nil
        )
        // Mode 3 (per-rep progression) — Descend ladder with explicit
        // per-rep targets so the ProgressionRepGroupRow renders the
        // chevron + numeric label per card, NOT a flattened range.
        let richSet = ParsedRepGroup(
            reps: 4,
            distance: 25,
            stroke: "Free",
            interval: nil,
            intensity: nil,            // ladder-driven, no flat intensity
            pacing: nil,
            pattern: [],
            patternType: nil,
            connectors: nil,
            note: "Descend: 1 = race rhythm / 2 = race rhythm / 3 = race rhythm / 4 = race rhythm",
            gear: nil,
            gearOptional: false,
            descend: "1-4",
            details: nil,
            dive: false,
            suit: false,
            ambiguousTerm: nil,
            fragments: [fragment0, fragment1],
            sourceLine: nil,
            zoneTerm: "firm",
            perRepTargets: ["race rhythm", "race rhythm", "race rhythm", "race rhythm"]
        )
        let section = ParsedSection(
            title: nil,
            namedSets: [
                ParsedNamedSet(label: nil, note: nil, repGroups: [richSet])
            ]
        )
        let parsed = ParsedWorkout(title: nil, sections: [section], degraded: nil, degradedReason: nil)

        title = "Rich Test"
        workoutText = text
        parsedWorkout = parsed
        parseSuccess = true
        isPendingParse = false
        cache[cacheKey(for: text)] = CachedParse(trimmedText: text, workout: parsed)
        lastSentText = text
    }
    #endif
}

#Preview {
    WorkoutBuilderView(workoutId: nil)
        .environment(AuthManager())
}
