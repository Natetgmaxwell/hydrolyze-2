import SwiftUI
import UniformTypeIdentifiers

// Lightweight identifier for drag-and-drop of swimmer chips.
struct WaveChipTransferable: Transferable, Codable {
    let id: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType.text)
    }
}

/// SessionStartView — two-step session launch: roster picker → wave preview.
/// Step 1: multi-select swimmers → "Lock Roster"
/// Step 2: drag-and-drop wave preview → "Start Session" → TimingView
struct SessionStartView: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool
    @StateObject private var viewModel = SessionStartViewModel()
    // ponytail (warmth-through-motion iter 6): on-appear reveal.
    // Same pattern as login reveal (d46c444), today reveal (0a90257),
    // workouts reveal (06c6823), swimmers reveal (61404f1, 1ffa02c),
    // and workouts+swimmers cohesion (19e0e9f). When SessionStartView
    // opens (sheet or fullScreenCover), the step content fades +
    // scales in over Animations.springSoft, gated by Reduce Motion
    // for a11y. Only applied to the OUTER content (the step switch)
    // — nested VStacks keep their own per-step motion.
    @State private var animateIn: Bool = false

    let sessionId: String
    let workoutSets: [WorkoutSet]
    // V0.49 Slice 1 (2026-08-22): optional Edit Attendees entry
    // point. When `isEditMode` is true the picker seeds from
    // `preselectedSwimmerIds` (the current roster) instead of
    // attendance-derived guesses, the button label switches to
    // "Done", and `lockRoster` re-upserts `session_roster` for
    // the threaded session id. Normal mode is unchanged.
    let isEditMode: Bool
    let preselectedSwimmerIds: Set<UUID>?
    // Phase 2.6 v1.6.1 fix: onComplete now also passes the selected
    // workoutSetId, so the caller can thread it into TimingView. The
    // set is the one the user picked in the wave preview (via
    // previewSetIndex) at the moment they tapped Start. The
    // SessionStartViewModel's lockRoster created wave_assignments for
    // this set, and the TimingView.save() needs to filter
    // wave_assignments by this set id to produce correct pairing
    // results. Dropping it at the navigation boundary is what caused
    // the "Session is missing its workout set" error from v1.6's
    // safety guard.
    let onComplete: (String, String) -> Void

    /// Convenience init for the normal (non-edit) call site — keeps
    /// every existing caller (the per-fragment timing launcher) free
    /// of the new params. `isEditMode = false`, no pre-selection.
    init(sessionId: String, workoutSets: [WorkoutSet], onComplete: @escaping (String, String) -> Void) {
        self.sessionId = sessionId
        self.workoutSets = workoutSets
        self.isEditMode = false
        self.preselectedSwimmerIds = nil
        self.onComplete = onComplete
    }

    /// Edit Attendees entry point — `isEditMode = true` with the
    /// current roster passed in as the initial selection.
    init(sessionId: String, workoutSets: [WorkoutSet], isEditMode: Bool, preselectedSwimmerIds: Set<UUID>?, onComplete: @escaping (String, String) -> Void) {
        self.sessionId = sessionId
        self.workoutSets = workoutSets
        self.isEditMode = isEditMode
        self.preselectedSwimmerIds = preselectedSwimmerIds
        self.onComplete = onComplete
    }

    private var coachId: String? {
        authManager.coachId
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bgBase.ignoresSafeArea()

                switch viewModel.step {
                case .rosterPicker:
                    RosterPickerView(viewModel: viewModel, coachId: coachId, sessionId: sessionId, workoutSets: workoutSets, isEditMode: isEditMode)
                case .wavePreview:
                    WavePreviewView(
                        viewModel: viewModel,
                        swimmerNames: viewModel.swimmerNamesById,
                        workoutSets: viewModel.workoutSets,
                        onStart: {
                            Task { @MainActor in
                                let ok = await viewModel.startSession()
                                if ok, let sid = viewModel.createdSessionId {
                                    // Phase 2.6 v1.6.1 fix: pass the
                                    // selected workoutSetId back to
                                    // the caller so it can thread into
                                    // TimingView. previewSetIndex is the
                                    // user's currently-displayed set; the
                                    // wave_assignments were created for
                                    // this set in lockRoster.
                                    let setId = workoutSets[safe: viewModel.previewSetIndex]?.id ?? ""
                                    dismiss()
                                    onComplete(sid, setId)
                                }
                            }
                        }
                    )
                }
            }
            // V0.49 Slice 1 (2026-08-22): in edit mode the
            // `lockRoster` upsert path completes inside the
            // roster picker step (we never advance to wave
            // preview). When the VM flips `didCompleteEdit`
            // true, dismiss the sheet and call `onComplete`
            // with the threaded session id + an empty set id
            // (Edit Attendees doesn't launch timing). Normal
            // mode never sets this flag (lockRoster advances
            // to wave preview there), so this branch is dead
            // code outside the edit path.
            .onChange(of: viewModel.didCompleteEdit) { _, didFinish in
                guard isEditMode, didFinish else { return }
                let sid = viewModel.createdSessionId ?? sessionId
                // Reset so a future Edit Attendees tap
                // doesn't re-fire on this stale value.
                viewModel.didCompleteEdit = false
                dismiss()
                onComplete(sid, "")
            }
            .navigationTitle(viewModel.step == .rosterPicker ? "Select Swimmers" : "Wave Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(Color.textPrimary)
                }
            }
        }
        // Disable swipe-down-to-dismiss while the roster picker is shown.
        // The drag-to-add gesture was being captured by the sheet's dismiss handler
        // when the user dragged in a gap between rows — closing the sheet
        // unintentionally. The Cancel button in the toolbar is the only
        // way out. The wave preview is also a tap-driven UI (no drag), so
        // it's safe to disable dismiss for the whole sheet.
        .interactiveDismissDisabled(true)
        .task {
            // v1.17 Slice 5: pass the workout so the picker seeds from
            // resolved attendance instead of selecting everyone.
            await viewModel.loadRoster(
                coachId: coachId,
                workoutId: workoutSets.first?.workoutId,
                // V0.49 Slice 1 (2026-08-22): Edit mode seeds from
                // the current roster snapshot (passed in via the
                // view's `preselectedSwimmerIds`), so the picker
                // shows exactly who's in. Normal mode keeps the
                // existing attendance-derived seed path intact.
                isEditMode: isEditMode,
                preselectedSwimmerIds: preselectedSwimmerIds
            )
        }
        // PHASE 2.8.6: same nil→non-nil race fix as SwimmersListView.
        // The .task fires once on appear; if coachId is still nil
        // because AuthManager hasn't resolved the coach row, the roster
        // silently stays empty. The .onChange re-triggers when
        // coachId becomes available.
        .onChange(of: coachId) { _, newCoachId in
            guard let newCoachId = newCoachId else { return }
            Task {
                await viewModel.loadRoster(
                    coachId: newCoachId,
                    workoutId: workoutSets.first?.workoutId,
                    isEditMode: isEditMode,
                    preselectedSwimmerIds: preselectedSwimmerIds
                )
            }
        }
        // ponytail: outer content fade-in on sheet/cover appear. Gating
        // by reduceMotion is the standard a11y pattern (matches d46c444,
        // 0a90257, 06c6823, 61404f1, 1ffa02c, 19e0e9f). Only on the
        // outer — nested VStacks own their own per-step motion.
        .opacity(animateIn ? 1.0 : 0.0)
        .scaleEffect(animateIn ? 1.0 : 0.98)
        .animation(reduceMotion ? nil : Animations.springSoft, value: animateIn)
        .onAppear { animateIn = true }
    }
}

// MARK: - Roster Picker (Phase 2.5-c: drag-to-add multi-select)

/// File-private PreferenceKey used to capture each row's frame in the
/// `rosterScroll` coordinate space. The drag gesture uses these frames to
/// determine which row is currently under the user's finger.
fileprivate struct SwimmerRowFrameKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct RosterPickerView: View {
    @ObservedObject var viewModel: SessionStartViewModel
    let coachId: String?
    let sessionId: String
    let workoutSets: [WorkoutSet]
    // V0.49 Slice 1 (2026-08-22): Edit Attendees mode propagates
    // through here so the Lock Roster / Done button label and the
    // `lockRoster` call can branch on it. Plain picker view
    // stays unchanged (false).
    let isEditMode: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    /// Captured frame of each row in the `rosterScroll` coordinate space.
    /// Updated as rows scroll into view; consumed by the drag gesture to find
    /// which row is currently under the user's finger.
    @State private var rowFrames: [UUID: CGRect] = [:]

    /// Set while a drag is in progress. Used to suppress the per-row tap
    /// behavior while the user is dragging (so taps don't fire mid-drag).
    @State private var isDragging: Bool = false

    /// Most recent row added to the selection during the current drag. Used to
    /// short-circuit the per-frame onChanged calls (60+/sec) so we only call
    /// `toggleSwimmer` when the finger actually crosses into a NEW row. Without
    /// this, the gesture re-fires for the same row many times per second, churning
    /// the SwiftUI re-render and making the selection animation look choppy.
    @State private var lastAddedRowId: UUID? = nil

    private let coordinateSpaceName = "rosterScroll"

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            rosterSeedCaption
            swimmersList
            errorMessageView
            lockRosterButton
        }
    }

    /// v1.17 Slice 5: one line telling the coach why this roster is
    /// pre-filled the way it is. Silent in the normal attendance case —
    /// the per-chip captions already say it, and a 20-year coach doesn't
    /// need the app narrating itself. Speaks up only when the selection is
    /// a fallback rather than real attendance, because that is the case
    /// where "everyone is selected" would otherwise be misread as
    /// "everyone is coming".
    @ViewBuilder
    private var rosterSeedCaption: some View {
        switch viewModel.rosterSeed {
        case .attendance:
            EmptyView()
        case .noSignalFallback:
            captionRow("No one's marked their attendance yet — everyone's selected.")
        case .unavailable:
            captionRow("Attendance isn't available for this workout — everyone's selected.")
        }
    }

    private func captionRow(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(Color.textFaint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 8)
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(Color.textFaint)
            TextField("Search swimmers", text: $viewModel.searchQuery)
                .foregroundColor(Color.textPrimary)
        }
        .padding(12)
        .background(Color.bgDeep)
        .cornerRadius(10)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var swimmersList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(viewModel.filteredSwimmers) { swimmer in
                    let swimmerUUID = UUID(uuidString: swimmer.id) ?? UUID()
                    SwimmerRowView(
                        swimmer: swimmer,
                        isSelected: viewModel.selectedSwimmerIds.contains(swimmerUUID),
                        onToggle: {
                            if let id = UUID(uuidString: swimmer.id) {
                                viewModel.toggleSwimmer(id)
                            }
                        },
                        attendanceReason: viewModel.attendanceReasons[swimmer.id]
                    )
                    // Capture each row's frame in the shared coordinate space.
                    // GeometryReader is cheap inside a LazyVStack because only
                    // visible rows are evaluated.
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .preference(
                                    key: SwimmerRowFrameKey.self,
                                    value: [swimmerUUID: geo.frame(in: .named(coordinateSpaceName))]
                                )
                        }
                    )
                    // Drag-to-add: the gesture is on EACH ROW (not the ScrollView).
                    // When the drag starts on a row, this row's gesture claims the
                    // touch (not simultaneousGesture, so the ScrollView's scroll is
                    // blocked for this drag). When the drag starts in a gap between
                    // rows, no row's gesture fires and the ScrollView scrolls normally.
                    // value.location is in the rosterScroll coordinate space, so the
                    // parent can find the row under the current finger as the drag
                    // moves between rows.
                    .gesture(
                        DragGesture(minimumDistance: 5, coordinateSpace: .named(coordinateSpaceName))
                            .onChanged { value in
                                isDragging = true
                                addRowUnderPointToSelection(point: value.location)
                            }
                            .onEnded { _ in
                                isDragging = false
                                lastAddedRowId = nil  // reset for next drag
                            }
                    )
                }
            }
        }
        .coordinateSpace(name: coordinateSpaceName)
        .onPreferenceChange(SwimmerRowFrameKey.self) { frames in
            rowFrames = frames
        }
    }

    /// Find the row whose frame contains the given point in the shared
    /// coordinate space. If found and not already selected, add it to the
    /// selection. (Per the locked design: drag-to-ADD, no deselect on drag.)
    ///
    /// The `lastAddedRowId` memoization skips calls when the finger is still
    /// over the same row it already added (the gesture fires onChanged many
    /// times per second per finger position). The `withAnimation` wrapper makes
    /// the resulting state change animate explicitly, so the checkmark + row
    /// background fade in instead of snapping.
    /// ponytail (warmth-through-motion iter 6): gated by Reduce Motion so
    /// users with motion sensitivity get instant row selection during drag.
    /// Matches d46c444, 0a90257, 06c6823, 61404f1, 1ffa02c, 19e0e9f.
    private func addRowUnderPointToSelection(point: CGPoint) {
        for (id, frame) in rowFrames {
            guard frame.contains(point) else { continue }
            // Same row as last time — already added, nothing to do
            if id == lastAddedRowId { return }
            lastAddedRowId = id
            if !viewModel.selectedSwimmerIds.contains(id) {
                if reduceMotion {
                    viewModel.toggleSwimmer(id)
                } else {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        viewModel.toggleSwimmer(id)
                    }
                }
            }
            return  // one row per frame
        }
    }

    private var errorMessageView: some View {
        Group {
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(Color.statusError)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var lockRosterButton: some View {
        VStack(spacing: 8) {
            // V0.49 Slice 1 (2026-08-22): in edit mode the button
            // label flips to "Done" — the existing `lockRoster`
            // upsert path runs AS IS (it already upserts
            // session_roster + wave_assignments for every set),
            // so tapping Done re-persists the (possibly edited)
            // roster against the threaded session id. Same action,
            // different copy.
            Button {
                Task {
                    // V0.49 Slice 1 (2026-08-22): thread the view's
                    // `isEditMode` through to the VM so the upsert
                    // branches correctly. Edit mode skips the
                    // session-row upsert and the wave-preview step
                    // transition; the VM sets `didCompleteEdit` to
                    // dismiss the sheet via the view's `.onChange`.
                    await viewModel.lockRoster(
                        sessionId: sessionId,
                        workoutSets: workoutSets,
                        isEditMode: isEditMode
                    )
                }
            } label: {
                HStack {
                    if viewModel.isLoading {
                        ProgressView()
                            .tint(Color.textOnAccent)
                            .padding(.trailing, 8)
                    }
                    Text(isEditMode ? "Done" : "Lock Roster")
                        .font(.titleSmall)
                    Text("(\(viewModel.selectedSwimmerIds.count))")
                        .font(.body)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(viewModel.selectedSwimmerIds.isEmpty ? Color.bgInset : Color.accentAction)
                .foregroundColor(viewModel.selectedSwimmerIds.isEmpty ? Color.textFaint : Color.bgBase)
                .cornerRadius(12)
            }
            // Disabled if nothing selected OR if lockRoster is in-flight
            // (prevents double-tap creating duplicate session rows)
            .disabled(viewModel.selectedSwimmerIds.isEmpty || viewModel.isLoading)
        }
        .padding(16)
        .background(Color.bgDeep)
    }
}

// MARK: - Swimmer Row

struct SwimmerRowView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool
    let swimmer: Swimmer
    let isSelected: Bool
    let onToggle: () -> Void
    /// v1.17 Slice 5: why this swimmer is (or isn't) pre-selected. nil when
    /// the roster wasn't seeded from attendance — then no caption shows and
    /// the row looks exactly as it did before the feature existed.
    var attendanceReason: AttendanceResolver.Reason? = nil

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.titleSmall)
                    .foregroundColor(isSelected ? Color.textPrimary : Color.textFaint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(swimmer.fullName)
                        .font(.bodyEmphasis)
                        .foregroundColor(Color.textPrimary)
                    // Provenance beats squad name here: "said they're in" vs
                    // "usual session" is what the coach needs when deciding
                    // whether to override. Squad name falls back through.
                    if let caption = attendanceCaption {
                        Text(caption)
                            .font(.caption)
                            .foregroundColor(captionColor)
                    } else if !swimmer.groups.isEmpty {
                        Text(swimmer.groups.map { $0.name }.joined(separator: ", "))
                            .font(.caption)
                            .foregroundColor(Color.textFaint)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(isSelected ? Color.bgSelected : Color.clear)
        }
        .buttonStyle(.plain)
        // Smooth the checkmark + background transition on select/deselect.
        // Without this, the icon swap and the background fade were instant,
        // which felt choppy during drag-to-add (the gesture adds 5+ rows in
        // a second, each transition visible to the eye). With a spring, the
        // same transitions feel like a natural tap response.
        // ponytail (warmth-through-motion iter 6): gated by Reduce Motion
        // so users with motion sensitivity get instant transitions. Matches
        // d46c444, 0a90257, 06c6823, 61404f1, 1ffa02c, 19e0e9f.
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.75), value: isSelected)
    }

    /// Coach vocabulary, not system vocabulary. No "intent", no "resolved".
    private var attendanceCaption: String? {
        switch attendanceReason {
        case .explicitIn?:   return "said they're in"
        case .explicitOut?:  return "can't make it"
        case .standingSlot?: return "usual session"
        case .noSignal?:     return "not marked"
        case nil:            return nil
        }
    }

    /// A declined swimmer reads differently from one who simply hasn't
    /// marked — the coach should be able to tell those apart at a glance
    /// without reading the words.
    private var captionColor: Color {
        switch attendanceReason {
        case .explicitIn?:   return Color.statusSuccess
        case .standingSlot?: return Color.textMuted
        case .explicitOut?:  return Color.textFaint
        default:             return Color.textFaint
        }
    }
}

// MARK: - Wave Preview

/// V0.52 Slice 1 (2026-09-06): the WavePreviewView now hosts TWO
/// presentations — a read-only deck-brief sheet (the new default) and
/// the existing drag-to-edit editor (reached only via the ⚠ Close
/// Finish banner tap or the explicit "Adjust" affordance on the
/// sheet). The split mirrors the spec: "Coach's job at session start
/// becomes ASSENT, not data entry." The sheet shows wave + lane +
/// predicted time in SEND-OFF ORDER (Wave 1 "on the zero", Wave 2
/// "+10s", etc.) — the order the coach reads the lineup aloud. The
/// editor view stays structurally unchanged below the switch.
///
/// `showingEditor` toggles between the two. Default is `false` (the
/// sheet). Banner tap + Adjust both flip it true. A `Done` button on
/// the editor flips it back. SessionStartViewModel.startSession and
/// the wave-assignment persistence path are unchanged — this is a
/// pure UI slice.
struct WavePreviewView: View {
    @ObservedObject var viewModel: SessionStartViewModel
    let swimmerNames: [UUID: String]
    let workoutSets: [WorkoutSet]
    let onStart: () -> Void

    // V0.52 Slice 1: false = deck-brief sheet (default), true = editor.
    // The sheet is the green path; the editor is the yellow path (⚠
    // Close Finish banner tap or explicit "Adjust" affordance).
    @State private var showingEditor: Bool = false

    /// Lane count is pool-specific (6, 8, 10 — varies by facility). Read from the
    /// session's `poolConfig` instead of hardcoding. Phase 2.5-b: removes the old
    /// `private let laneCount = 6` which would have silently broken for 8-lane pools.
    private var laneCount: Int { viewModel.poolConfig.laneCount }

    /// Cross-lane close-finish collision threshold (ms). Matches the coach's ergonomic
    /// constraint: pressing LAP twice in <0.5s adds error. Pairs of swimmers in the
    /// same wave finishing within this gap AND in different lanes are flagged.
    private let closeFinishThresholdMs: Int = 500

    /// One close-finish collision between two swimmers in the same wave.
    struct CloseFinishPair: Identifiable, Hashable {
        let id: String
        let laneA: Int
        let laneB: Int
        let gapMs: Int
    }

    /// Wave assignments for the currently selected set only.
    /// The WaveAllocator generates one wave assignment per (swimmer, set) pair,
    /// so the preview must be filtered to a single set to avoid showing each
    /// swimmer twice (once per set).
    private var visibleAssignments: [WaveAssignment] {
        guard let setId = workoutSets[safe: viewModel.previewSetIndex]?.id else {
            return []
        }
        return viewModel.waveAssignments.filter { $0.workoutSetId == setId }
    }

    /// Per-wave list of cross-lane close-finish collisions, for the currently visible
    /// set. Empty wave entries are omitted. Computed lazily from `visibleAssignments`
    /// — sorted by predicted touch time within each wave, adjacent pairs in DIFFERENT
    /// lanes that finish within `closeFinishThresholdMs` are flagged.
    private var waveCollisions: [Int: [CloseFinishPair]] {
        let byWave: [Int: [WaveAssignment]] = Dictionary(grouping: visibleAssignments) { $0.waveNumber }
        var result: [Int: [CloseFinishPair]] = [:]
        for (wave, assignments) in byWave {
            let timed = assignments
                .filter { $0.predictedTouchMs > 0 }
                .sorted { $0.predictedTouchMs < $1.predictedTouchMs }
            guard timed.count >= 2 else { continue }
            var pairs: [CloseFinishPair] = []
            for i in 0..<(timed.count - 1) {
                let a = timed[i]
                let b = timed[i + 1]
                let gap = b.predictedTouchMs - a.predictedTouchMs
                if gap > 0 && gap < closeFinishThresholdMs && a.lane != b.lane {
                    pairs.append(CloseFinishPair(
                        id: "\(wave)-\(a.id)-\(b.id)",
                        laneA: a.lane,
                        laneB: b.lane,
                        gapMs: gap
                    ))
                }
            }
            if !pairs.isEmpty {
                result[wave] = pairs
            }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            if workoutSets.count > 1 {
                setSelector
            }

            // V0.52 Slice 1: editor mode shows the existing
            // lane-picker + drag-to-edit ScrollView. Sheet mode
            // (default) shows the read-only deck-brief sheet.
            // The toggle is the ⚠ Close Finish banner tap or the
            // explicit "Adjust" affordance on the sheet.
            if showingEditor {
                lanePicker
                editorContent
            } else {
                // V0.52 Slice 1: read-only deck brief. No
                // lane-picker in this mode (lane count stays
                // visible in the close-finish banner copy when
                // collisions exist — matches the locked
                // constraint "no lane buttons" by hiding the
                // slider entirely in the green path).
                WaveSheetView(
                    viewModel: viewModel,
                    swimmerNames: swimmerNames,
                    workoutSets: workoutSets,
                    waveCollisions: waveCollisions,
                    closeFinishThresholdMs: closeFinishThresholdMs,
                    // V0.52 Slice 3: chip wires to Edit Attendees
                    // on tap. Slice 1 leaves it as a no-op stub —
                    // Slice 3 will thread the showEditAttendees
                    // callback through here.
                    onAdjustTapped: { showingEditor = true },
                    onStartTapped: onStart
                )
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(Color.statusError)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .multilineTextAlignment(.center)
            }

            // V0.52 Slice 1: editor mode keeps the existing
            // reset + start buttons (bottom of the editor); the
            // sheet mode renders its own start button at the
            // bottom of the sheet (one tap, accent CTA).
            if showingEditor {
                resetButton
                startButton
                doneButton  // V0.52 Slice 1: editor exit affordance
            }
        }
    }

    // V0.52 Slice 1: editor body extracted from the old
    // `body` so we can gate it on `showingEditor`. The
    // contents are unchanged — lane columns, drag-to-move,
    // close-finish banner, all preserved.
    private var editorContent: some View {
        Group {
            if !waveCollisions.isEmpty {
                closeFinishBanner
            }

            ScrollView {
                VStack(spacing: 20) {
                    ForEach(0..<laneCount, id: \.self) { lane in
                        LaneColumn(
                            lane: lane + 1,
                            assignments: visibleAssignments.filter { $0.lane == lane + 1 },
                            swimmerNames: swimmerNames,
                            // Phase 2.6: pass the per-(current set, swimmer)
                            // predictions dict down to LaneColumn so the
                            // PositionCell/SwimmerChip can render maturity
                            // badges. Computed once in WavePreviewView, not
                            // per-cell, to avoid redundant lookups.
                            predictionsForSet: predictionsForSet,
                            hasTightGap: hasTightGap(inLane: lane + 1),
                            onMove: { fromId, toLane, toPos in
                                if let from = visibleAssignments.first(where: { $0.id == fromId }) {
                                    viewModel.moveSwimmer(from: from, toLane: toLane, toPosition: toPos)
                                }
                            },
                            // PHASE 1 (T9.5, 2026-06-20): the current set
                            // + the calibration are threaded down to the
                            // chip for the calibration badge. The set is
                            // the one at `previewSetIndex`; the calibration
                            // is the SessionStartViewModel's instance
                            // (populated by `lockRoster` via T3.5).
                            // PHASE 1 (T9.5.1, 2026-06-22): these two
                            // arguments must come AFTER `onMove:` to match
                            // the LaneColumn struct's parameter order.
                            // The struct's stored-property order is
                            // hasTightGap → onMove → set → calibration;
                            // Swift requires memberwise-initializer
                            // calls to use that order. Reordering here
                            // because the T9.5 wiring originally
                            // placed these between hasTightGap and
                            // onMove, which compiles only when the
                            // call uses explicit argument labels (it
                            // does, but Swift still enforces order).
                            set: workoutSets[safe: viewModel.previewSetIndex],
                            calibration: viewModel.calibration
                        )
                    }
                }
                .padding(.vertical, 16)
            }
        }
    }

    /// Per-wave close-finish banner. One row per wave that has any cross-lane
    /// collisions within `closeFinishThresholdMs`. Surfaces the problem before the
    /// coach starts the stopwatch — that's the whole point of the wave preview.
    ///
    /// V0.52 Slice 1: tap-to-adjust. The banner is the primary entry point
    /// to the editor view per the spec ("Interaction appears ONLY on
    /// exceptions: the existing ⚠ Close Finish banner expands to the
    /// drag-to-fix view"). The whole banner row is tappable; tapping
    /// flips `showingEditor = true`. Editor mode also re-renders the
    /// banner above the lane columns for continuity.
    private var closeFinishBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.eyebrow)
                    .foregroundColor(Color.accentAmber)
                Text("CLOSE FINISHES — coach can't LAP < 0.5s")
                    .font(.eyebrow)
                    .tracking(0.8)
                    .foregroundColor(Color.accentAmber)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.captionStrong)
                    .foregroundColor(Color.accentAmber)
            }
            ForEach(waveCollisions.keys.sorted(), id: \.self) { wave in
                if let pairs = waveCollisions[wave] {
                    HStack(spacing: 6) {
                        Text("Wave \(wave + 1)")
                            .font(.captionStrong)
                            .foregroundColor(Color.textPrimary)
                        Text("·")
                            .foregroundColor(Color.textFaint)
                        Text(pairs.map { "Lane \($0.laneA) ↔ Lane \($0.laneB) (gap \($0.gapMs)ms)" }
                            .joined(separator: "  •  "))
                            .font(.caption)
                            .foregroundColor(Color.textMuted)
                            .lineLimit(2)
                    }
                }
            }
            // V0.52 Slice 1: explicit "tap to adjust" caption —
            // surface the affordance in the read copy so the coach
            // doesn't have to guess the gesture. Quiet in editor
            // mode (the editor is already open).
            if !showingEditor {
                Text("tap to adjust")
                    .font(.caption)
                    .foregroundColor(Color.textMuted)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentAmber.opacity(0.15))
        .cornerRadius(8)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        // V0.52 Slice 1: whole banner is the tap target. Only
        // tap-active in sheet mode (showingEditor = false); in
        // editor mode the banner is informational.
        .contentShape(Rectangle())
        .onTapGesture {
            if !showingEditor {
                showingEditor = true
            }
        }
    }

    /// V0.52 Slice 1: exit affordance on the editor view. The
    /// spec mandates the editor is reachable only from the ⚠
    /// banner or the "Adjust" link on the sheet; an exit path is
    /// implied (the coach goes back to the sheet to start the
    /// session). "Done" matches the existing Edit Attendees
    /// pattern (same word, same intent).
    private var doneButton: some View {
        Button {
            showingEditor = false
        } label: {
            Text("Done")
                .font(.caption)
                .foregroundColor(Color.accentAction)
        }
        .padding(.bottom, 4)
    }

    private func hasTightGap(inLane lane: Int) -> Bool {
        let laneAssignments = visibleAssignments
            .filter { $0.lane == lane && $0.predictedTouchMs > 0 }
            .sorted { $0.positionInLane < $1.positionInLane }

        guard laneAssignments.count >= 2 else { return false }

        for i in 0..<(laneAssignments.count - 1) {
            let delta = laneAssignments[i + 1].predictedTouchMs - laneAssignments[i].predictedTouchMs
            if delta > 0 && delta < 1000 {
                return true
            }
        }
        return false
    }

    // MARK: - Phase 2.5-c set selector (per-set wave re-evaluation)

    private var setSelector: some View {
        HStack(spacing: 16) {
            Button {
                viewModel.previewSetIndex = max(0, viewModel.previewSetIndex - 1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.captionStrong)
                    .foregroundColor(viewModel.previewSetIndex == 0 ? Color.textFaint : Color.textMuted)
            }
            .disabled(viewModel.previewSetIndex == 0)

            VStack(spacing: 2) {
                Text("SET \(viewModel.previewSetIndex + 1) OF \(workoutSets.count)")
                    .font(.eyebrow)
                    .tracking(1.0)
                    .foregroundColor(Color.textFaint)
                if let currentSet = workoutSets[safe: viewModel.previewSetIndex] {
                    Text("\(currentSet.reps ?? 0) × \(currentSet.distance ?? 0)m \(currentSet.stroke ?? "")")
                        .font(.caption)
                        .foregroundColor(Color.textMuted)
                }
            }
            .frame(minWidth: 160)

            Button {
                viewModel.previewSetIndex = min(workoutSets.count - 1, viewModel.previewSetIndex + 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.captionStrong)
                    .foregroundColor(viewModel.previewSetIndex >= workoutSets.count - 1 ? Color.textFaint : Color.textMuted)
            }
            .disabled(viewModel.previewSetIndex >= workoutSets.count - 1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.bgDeep)
    }

    // MARK: - Phase 2.5-c / 2.6 lane picker (coach-configurable 1-10 lanes)

    private var lanePicker: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Lanes")
                    .font(.eyebrow)
                    .tracking(1.0)
                    .foregroundColor(Color.textFaint)
                Spacer()
                Text("\(viewModel.poolConfig.laneCount)")
                    .font(.eyebrow)
                    .foregroundColor(Color.textPrimary)
                    .frame(minWidth: 28)
            }
            Slider(
                value: Binding(
                    get: { Double(viewModel.poolConfig.laneCount) },
                    set: { viewModel.setLaneCount(Int($0.rounded())) }
                ),
                in: 1...10,
                step: 1
            )
            .tint(Color.textMuted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.bgDeep)
    }

    // MARK: - Phase 2.6 maturity badge helper

    /// Per-(currently selected set, swimmer) predictions. Computed once
    /// per body re-render and passed down to each LaneColumn, which
    /// passes it to PositionCell/SwimmerChip for the maturity badge.
    /// Returns an empty dict for cold-start (no set index) or no
    /// predictions yet (still building them in lockRoster).
    private var predictionsForSet: [String: Prediction] {
        guard let setId = workoutSets[safe: viewModel.previewSetIndex]?.id else {
            return [:]
        }
        return viewModel.predictionsBySwimmerBySet[setId] ?? [:]
    }

    private var resetButton: some View {
        Button {
            viewModel.resetToSuggested()
        } label: {
            Text("Reset to Suggested")
                .font(.caption)
                .foregroundColor(Color.textMuted)
        }
        .padding(.bottom, 8)
    }

    private var startButton: some View {
        Button {
            onStart()
        } label: {
            HStack {
                if viewModel.isLoading {
                    ProgressView()
                        .tint(Color.textOnAccent)
                        .padding(.trailing, 8)
                }
                Text("Start Session")
                    .font(.titleSmall)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color.accentAction)
            .foregroundColor(Color.textOnAccent)
            .cornerRadius(12)
        }
        .disabled(viewModel.isLoading)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }
}

// MARK: - Wave Sheet (V0.52 Slice 1: read-only deck brief)

/// V0.52 Slice 1 (2026-09-06): WaveSheetView — the read-only deck
/// brief that replaces the drag-to-edit wave preview as the DEFAULT
/// view after `lockRoster`. The spec describes it as "the coach's
/// job becomes ASSENT, not data entry." Reads like a pool-deck
/// announcement: each wave listed in SEND-OFF ORDER (Wave 1 "on the
/// zero", Wave 2 "+10s", etc.), each swimmer with lane + predicted
/// time.
///
/// The sheet has one primary action — Start Session — and one
/// secondary affordance — Adjust (or the ⚠ Close Finish banner if
/// collisions exist). The drag-to-edit editor is NEVER reached in
/// the green path.
///
/// Visuals match the existing Theme tokens (no new color/font
/// vocabulary): eyebrow labels via `Font.eyebrow`, predictions in
/// mono via `Font.numeric`, surface backgrounds via `Color.bgDeep`
/// / `Color.bgSelected`, amber for the warning banner.
///
/// Slice 3 (2026-09-06) adds the "Same squad" chip; Slice 1
/// leaves the chip as a stub slot (no-op) so the layout is stable
/// across both slices.
struct WaveSheetView: View {
    @ObservedObject var viewModel: SessionStartViewModel
    let swimmerNames: [UUID: String]
    let workoutSets: [WorkoutSet]
    let waveCollisions: [Int: [WavePreviewView.CloseFinishPair]]
    let closeFinishThresholdMs: Int
    /// V0.52 Slice 1: tap → switch to the drag-to-edit editor.
    /// The sheet binds this; the parent `WavePreviewView` flips
    /// `showingEditor = true` when invoked.
    let onAdjustTapped: () -> Void
    /// V0.52 Slice 1: tap → call `viewModel.startSession()` →
    /// write `wave_assignments` + dismiss the sheet + open
    /// TimingView. Wired by the parent (`onStart` closure).
    let onStartTapped: () -> Void

    // V0.52 Slice 3: stub for the "same squad" chip. Slice 3
    // threads the Edit Attendees presenter through here. Slice 1
    // leaves the chip rendered but disabled so the layout is
    // stable. The chip is wrapped below in a `sameSquadChip`
    // private view so the Slice 3 patch is a one-line change.
    let onSameSquadTapped: (() -> Void)?

    init(
        viewModel: SessionStartViewModel,
        swimmerNames: [UUID: String],
        workoutSets: [WorkoutSet],
        waveCollisions: [Int: [WavePreviewView.CloseFinishPair]],
        closeFinishThresholdMs: Int,
        onAdjustTapped: @escaping () -> Void,
        onStartTapped: @escaping () -> Void,
        onSameSquadTapped: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.swimmerNames = swimmerNames
        self.workoutSets = workoutSets
        self.waveCollisions = waveCollisions
        self.closeFinishThresholdMs = closeFinishThresholdMs
        self.onAdjustTapped = onAdjustTapped
        self.onStartTapped = onStartTapped
        self.onSameSquadTapped = onSameSquadTapped
    }

    /// Per-(set, swimmer) filtered to the currently-previewed set,
    /// sorted send-off-first: Wave 1 (offset 0), Wave 2 (offset
    /// sendOffIntervalMs), etc. Within each wave, swimmers sort by
    /// lane (left → right) so the coach reads the lineup across
    /// the pool, top-to-bottom.
    private var sheetAssignments: [SheetWave] {
        guard let setId = workoutSets[safe: viewModel.previewSetIndex]?.id else {
            return []
        }
        let forSet = viewModel.waveAssignments.filter { $0.workoutSetId == setId }
        let sendOffIntervalMs = viewModel.poolConfig.sendOffIntervalMs
        let grouped = Dictionary(grouping: forSet) { $0.waveNumber }
        let sortedWaves = grouped.keys.sorted()
        return sortedWaves.map { waveNum in
            // Within a wave, sort by lane ascending (left to right
            // matches how the coach reads the lineup); tie-break
            // by positionInLane to keep the order deterministic
            // when lane indices collide (synthesized rows from V0.51).
            let lanes = (grouped[waveNum] ?? []).sorted { lhs, rhs in
                if lhs.lane != rhs.lane { return lhs.lane < rhs.lane }
                return lhs.positionInLane < rhs.positionInLane
            }
            return SheetWave(
                waveNumber: waveNum,
                sendOffOffsetMs: waveNum * sendOffIntervalMs,
                sendOffIntervalMs: sendOffIntervalMs,
                lanes: lanes.map { assignment in
                    SheetLane(
                        lane: assignment.lane,
                        swimmerName: name(for: assignment),
                        predictedMs: assignment.predictedTouchMs
                    )
                }
            )
        }
    }

    private func name(for assignment: WaveAssignment) -> String {
        guard let uuid = UUID(uuidString: assignment.swimmerId) else {
            return assignment.swimmerId
        }
        return swimmerNames[uuid] ?? assignment.swimmerId
    }

    /// Set description for the sheet header. Mirrors the
    /// `setSelector` formatting in the editor so the coach sees
    /// the same wording regardless of mode.
    private var currentSetLabel: String {
        guard let currentSet = workoutSets[safe: viewModel.previewSetIndex] else {
            return ""
        }
        let reps = currentSet.reps ?? 0
        let distance = currentSet.distance ?? 0
        let stroke = currentSet.stroke ?? ""
        return "\(reps) × \(distance)m \(stroke)"
    }

    var body: some View {
        VStack(spacing: 0) {
            // V0.52 Slice 1: the close-finish banner stays the
            // primary tap-to-adjust entry point. Render it FIRST
            // when collisions exist so the coach sees the warning
            // + the lineup in one read.
            if !waveCollisions.isEmpty {
                closeFinishBanner
            }
            sheetScroll
            // V0.52 Slice 1: secondary affordance + start CTA.
            // The "same squad" chip (Slice 3) sits adjacent to the
            // start button; Slice 1 renders a placeholder so the
            // layout is stable.
            sameSquadChip
            startButton
        }
    }

    /// Scrollable read-only list of waves. Sends off in numeric
    /// order. Lines wrap with a 2-column layout adapted to width
    /// (text shows "L1 Name ~30.5s").
    private var sheetScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if sheetAssignments.isEmpty {
                    // Cold-start / no allocations yet — show the
                    // current set label + a quiet spinner so the
                    // coach doesn't think the sheet is broken.
                    HStack {
                        Spacer()
                        if viewModel.isLoading {
                            ProgressView().tint(Color.textPrimary)
                        } else {
                            Text(currentSetLabel)
                                .font(.caption)
                                .foregroundColor(Color.textMuted)
                        }
                        Spacer()
                    }
                    .padding(.top, 32)
                } else {
                    ForEach(sheetAssignments) { wave in
                        sheetWaveBlock(wave)
                    }
                }
                // V0.52 Slice 1: quiet "Adjust" affordance. Lives
                // BELOW the read-only sheet (not above) so it
                // doesn't compete with the START CTA — the spec
                // calls for "a quiet 'Adjust' affordance".
                adjustLink
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
    }

    private func sheetWaveBlock(_ wave: SheetWave) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Wave header — eyebrow + send-off chip. "Wave 1 — on
            // the zero" / "Wave 2 — +10s" reads aloud exactly like
            // a 20-year coach would say it.
            HStack(spacing: 8) {
                Text("WAVE \(wave.waveNumber + 1)")
                    .font(.eyebrow)
                    .tracking(1.0)
                    .foregroundColor(Color.textFaint)
                Text("—")
                    .font(.eyebrow)
                    .foregroundColor(Color.textFaint)
                Text(wave.sendOffLabel)
                    .font(.eyebrow)
                    .tracking(0.8)
                    .foregroundColor(Color.textMuted)
                Spacer()
            }
            // 2-column lane grid. Falls through to a single
            // column on narrow widths via `LazyVGrid` with
            // `adaptive` columns.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: 6)],
                alignment: .leading,
                spacing: 6
            ) {
                ForEach(wave.lanes) { line in
                    HStack(spacing: 6) {
                        Text("L\(line.lane)")
                            .font(.numericSmall)
                            .foregroundColor(Color.textFaint)
                        Text(line.swimmerName)
                            .font(.bodyEmphasis)
                            .foregroundColor(Color.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(line.predictedLabel)
                            .font(.numeric)
                            .foregroundColor(Color.textMuted)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.bgDeep)
                    .cornerRadius(8)
                }
            }
        }
        .padding(12)
        .background(Color.bgRaised)
        .cornerRadius(12)
    }

    /// Quiet "Adjust" link. Lives at the BOTTOM of the sheet (not
    /// in the header) so it never competes with the START CTA.
    /// Per spec: "an explicit quiet 'Adjust' affordance — never
    /// forced in the green path."
    private var adjustLink: some View {
        HStack {
            Spacer()
            Button(action: onAdjustTapped) {
                Text("Adjust waves & lanes")
                    .font(.caption)
                    .foregroundColor(Color.textMuted)
            }
            Spacer()
        }
        .padding(.top, 4)
    }

    /// Per-wave close-finish banner (V0.52 Slice 1). Reuses the
    /// parent's WavePreviewView.closeFinishBanner by being
    /// identical in copy + tap target. The parent
    /// WavePreviewView already wires the tap → onAdjustTapped,
    /// so this view does NOT need its own gesture — when the
    /// parent's banner is shown (because `waveCollisions` is
    /// non-empty), tapping it opens the editor. To keep the
    /// single source of truth, the sheet view embeds a banner
    /// that mirrors the parent's logic.
    private var closeFinishBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.eyebrow)
                    .foregroundColor(Color.accentAmber)
                Text("CLOSE FINISHES — coach can't LAP < 0.5s")
                    .font(.eyebrow)
                    .tracking(0.8)
                    .foregroundColor(Color.accentAmber)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.captionStrong)
                    .foregroundColor(Color.accentAmber)
            }
            ForEach(waveCollisions.keys.sorted(), id: \.self) { wave in
                if let pairs = waveCollisions[wave] {
                    HStack(spacing: 6) {
                        Text("Wave \(wave + 1)")
                            .font(.captionStrong)
                            .foregroundColor(Color.textPrimary)
                        Text("·")
                            .foregroundColor(Color.textFaint)
                        Text(pairs.map { "Lane \($0.laneA) ↔ Lane \($0.laneB) (gap \($0.gapMs)ms)" }
                            .joined(separator: "  •  "))
                            .font(.caption)
                            .foregroundColor(Color.textMuted)
                            .lineLimit(2)
                    }
                }
            }
            Text("tap to adjust")
                .font(.caption)
                .foregroundColor(Color.textMuted)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentAmber.opacity(0.15))
        .cornerRadius(8)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .contentShape(Rectangle())
        .onTapGesture { onAdjustTapped() }
    }

    /// V0.52 Slice 3 placeholder: "same squad" chip. Slice 1
    /// renders a quiet informational chip showing the current
    /// roster size + the chip stroke. Slice 3 wires the tap
    /// gesture to the Edit Attendees sheet via the
    /// `onSameSquadTapped` closure. Always renders so the
    /// layout is stable across slices.
    private var sameSquadChip: some View {
        HStack {
            Spacer()
            if let onTap = onSameSquadTapped {
                Button(action: onTap) {
                    HStack(spacing: 6) {
                        Image(systemName: "person.2.fill")
                            .font(.captionStrong)
                        Text("Same squad (\(viewModel.selectedSwimmerIds.count))")
                            .font(.captionStrong)
                        Image(systemName: "chevron.right")
                            .font(.captionStrong)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.bgDeep)
                    .foregroundColor(Color.textPrimary)
                    .cornerRadius(8)
                }
            } else {
                // V0.52 Slice 1: chip is present but inert. Shows
                // the squad size so the coach sees who's in, but
                // doesn't open anything. Slice 3 wires the gesture.
                HStack(spacing: 6) {
                    Image(systemName: "person.2.fill")
                        .font(.captionStrong)
                    Text("\(viewModel.selectedSwimmerIds.count) swimmers")
                        .font(.captionStrong)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.bgDeep)
                .foregroundColor(Color.textMuted)
                .cornerRadius(8)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    /// Primary CTA — "Start Session". Matches the existing
    /// editor mode's start button styling (accent fill, full
    /// width). One tap → `viewModel.startSession()` → write
    /// wave_assignments → dismiss → open TimingView.
    private var startButton: some View {
        Button {
            onStartTapped()
        } label: {
            HStack {
                if viewModel.isLoading {
                    ProgressView()
                        .tint(Color.textOnAccent)
                        .padding(.trailing, 8)
                }
                Text("Start Session")
                    .font(.titleSmall)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color.accentAction)
            .foregroundColor(Color.textOnAccent)
            .cornerRadius(12)
        }
        .disabled(viewModel.isLoading)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }
}

/// V0.52 Slice 1: one wave's read-only presentation. waveNumber is
/// 0-indexed to match the WaveAllocator output (so the display
/// label is `waveNumber + 1`). sendOffOffsetMs is the absolute
/// offset from session start; the label converts it to "+10s" /
/// "+20s" / "on the zero".
struct SheetWave: Identifiable {
    let waveNumber: Int
    let sendOffOffsetMs: Int
    let sendOffIntervalMs: Int
    let lanes: [SheetLane]

    var id: Int { waveNumber }

    /// Pool-deck wording: wave 0 = "on the zero", wave 1 = "+10s",
    /// wave 2 = "+20s", etc. Matches the spec's example layout.
    var sendOffLabel: String {
        if sendOffOffsetMs <= 0 { return "on the zero" }
        let seconds = sendOffOffsetMs / 1000
        return "+\(seconds)s"
    }
}

/// V0.52 Slice 1: one swimmer's lane line. predictedMs carries the
/// absolute predicted touch from session start (matches
/// `WaveAssignment.predictedTouchMs`); the label formats as ~M:SS.s
/// for sub-minute and ~SS.S for the rest.
struct SheetLane: Identifiable {
    let lane: Int
    let swimmerName: String
    let predictedMs: Int

    var id: Int { lane }

    /// Pool-deck formatted predicted time. Sub-minute reads as
    /// `~M:SS.s` (e.g. `~0:30.5`), the rest as `~SS.S` (e.g.
    /// `~92.4s`). The "~" prefix marks the value as predicted so
    /// the coach never confuses it with a recorded time.
    var predictedLabel: String {
        guard predictedMs > 0 else { return "—" }
        let seconds = Double(predictedMs) / 1000.0
        if seconds < 60 {
            let mins = Int(seconds) / 60
            let rest = seconds - Double(mins * 60)
            return String(format: "~%d:%04.1f", mins, rest)
        }
        return String(format: "~%.1fs", seconds)
    }
}

// MARK: - Lane Column

struct LaneColumn: View {
    let lane: Int
    let assignments: [WaveAssignment]
    let swimmerNames: [UUID: String]
    let predictionsForSet: [String: Prediction]   // Phase 2.6: per-swimmer maturity lookup
    let hasTightGap: Bool
    let onMove: (String, Int, Int) -> Void
    /// PHASE 1 (T9.5, 2026-06-20): the current set (for distance
    /// + stroke) and the calibration factors. Threaded down to
    /// PositionCell so the SwimmerChip can render the calibration
    /// badge. Both are optional; the chip hides the badge when
    /// either is nil.
    let set: WorkoutSet?
    let calibration: CalibrationFactors?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("LANE \(lane)")
                    .font(.eyebrow)
                    .foregroundColor(Color.textFaint)
                    .tracking(1.0)

                if hasTightGap {
                    Text("⚠ Tight Gap")
                        .font(.monoChipBold)
                        .foregroundColor(Color.accentAmber)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentAmber.opacity(0.15))
                        .cornerRadius(4)
                }
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    let sortedAssignments = assignments.sorted { $0.positionInLane < $1.positionInLane }

                    ForEach(Array(sortedAssignments.enumerated()), id: \.element.id) { index, assignment in
                        PositionCell(
                            position: assignment.positionInLane,
                            assignment: assignment,
                            swimmerNames: swimmerNames,
                            // Phase 2.6: thread the per-(set, swimmer) Prediction
                            // through so SwimmerChip can render the maturity
                            // badge ("PB" / "N swims" / hidden for cold-start).
                            // Direct dictionary lookup — LaneColumn doesn't have
                            // access to viewModel, so the predictions dict is
                            // passed in from WavePreviewView (which DOES have
                            // viewModel). See the 237427d fix in
                            // SessionStartViewModel for the matching change.
                            prediction: predictionsForSet[assignment.swimmerId],
                            // PHASE 1 (T9.5, 2026-06-20): the set +
                            // calibration are threaded through for the
                            // SwimmerChip's calibration badge. Both are
                            // optional; the chip hides the badge when
                            // either is nil.
                            set: set,
                            calibration: calibration,
                            onDrop: { chipId in
                                onMove(chipId, lane, assignment.positionInLane)
                            }
                        )
                    }
                    
                    let nextPos = (sortedAssignments.last?.positionInLane ?? 0) + 1
                    EmptyDropZone(
                        position: nextPos,
                        onDrop: { chipId in
                            onMove(chipId, lane, nextPos)
                        }
                    )
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            }
        }
    }
}

// MARK: - Position Cell

struct PositionCell: View {
    let position: Int
    let assignment: WaveAssignment
    let swimmerNames: [UUID: String]
    let prediction: Prediction?
    /// PHASE 1 (T9.5, 2026-06-20): the current set and the
    /// calibration factors. Used to compute the SwimmerChip's
    /// calibration state (calibrating / calibrated). Both are
    /// optional; the state is nil (no badge) when either is nil.
    let set: WorkoutSet?
    let calibration: CalibrationFactors?
    let onDrop: (String) -> Void

    var body: some View {
        SwimmerChip(
            waveAssignment: assignment,
            swimmerNames: swimmerNames,
            prediction: prediction,
            // PHASE 1 (T9.5, 2026-06-20): compute the calibration
            // state for this (swimmer, distance, stroke) bucket.
            // The helper returns nil for the multiplier if the
            // table has 0 or 1 rows (no pair → "calibrating");
            // non-nil if the table has ≥ 2 rows ("calibrated").
            calibrationState: computeCalibrationState()
        )
            .draggable(WaveChipTransferable(id: assignment.id))
            .dropDestination(for: WaveChipTransferable.self) { items, _ in
                guard let item = items.first else { return false }
                onDrop(item.id)
                return true
            }
    }

    /// PHASE 1 (T9.5, 2026-06-20): the calibration state for the
    /// chip. nil if either the set or the calibration is missing.
    /// Otherwise: `.calibrated` if the suit helper returns a
    /// multiplier (i.e. ≥ 2 rows for the (swimmer, distance, stroke)
    /// key under different suit values); `.calibrating` if the
    /// helper returns nil (0 or 1 rows).
    private func computeCalibrationState() -> SwimmerChip.CalibrationState? {
        guard let set = set,
              let cal = calibration,
              let distance = set.distance,
              let stroke = set.stroke
        else { return nil }
        // The suitMultiplier helper returns nil for "no pair" and
        // a value for "pair exists." This is the canonical "is the
        // calibration calibrated?" check.
        let swimmerId = assignment.swimmerId
        let suitMult = cal.suitMultiplier(
            swimmerId: swimmerId,
            distance: distance,
            stroke: stroke,
            setSuit: true
        )
        return suitMult == nil ? .calibrating : .calibrated
    }
}

struct EmptyDropZone: View {
    let position: Int
    let onDrop: (String) -> Void
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.divider, style: StrokeStyle(lineWidth: 1.5, dash: [4]))
                .background(Color.clear)
                .frame(width: 60, height: 44)
                
            Image(systemName: "plus")
                .font(.captionStrong)
                .foregroundColor(Color.textFaint)
        }
        .dropDestination(for: WaveChipTransferable.self) { items, _ in
            guard let item = items.first else { return false }
            onDrop(item.id)
            return true
        }
    }
}

// MARK: - Swimmer Chip (Phase 2.6: includes maturity badge from 3-layer predictor)

struct SwimmerChip: View {
    let waveAssignment: WaveAssignment
    let swimmerNames: [UUID: String]
    let prediction: Prediction?
    /// PHASE 1 (T9, 2026-06-20): the calibration state for this
    /// swimmer at this set's (distance, stroke). nil = no badge
    /// (no calibration data, or the caller hasn't computed the
    /// state yet). The state is computed by the caller (the parent
    /// view) from the calibration table; the chip just renders
    /// the badge.
    let calibrationState: CalibrationState?

    /// PHASE 1 (T9, 2026-06-20): calibration state for the
    /// swimmer-at-(distance, stroke) calibration bucket. Driven by
    /// whether the calibration table has ≥ 2 rows for the
    /// (swimmer, X, distance, stroke) key under different X values
    /// (i.e. enough data to compute a meaningful pair-wise ratio).
    enum CalibrationState {
        /// Insufficient data for a meaningful calibration (table has
        /// 0 or 1 rows for the key). Show a "calibrating" badge so
        /// the coach knows the calibration is in-progress but not
        /// yet trustworthy.
        case calibrating
        /// Sufficient data (≥ 2 rows). The calibration is being
        /// applied to the prediction (see T8). Show a "calibrated"
        /// badge to signal trust.
        case calibrated

        /// Short human-readable label for the calibration pill.
        var badgeText: String {
            switch self {
            case .calibrating: return "calibrating"
            case .calibrated:  return "calibrated"
            }
        }

        /// Pill color. Yellow (amber) for calibrating, green for
        /// calibrated. Matches the existing maturity badge color
        /// convention in `badgeColor` below.
        var badgeColor: Color {
            switch self {
            case .calibrating: return Color.accentAmber
            case .calibrated:  return Color.statusSuccess
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(swimmerName)
                .font(.captionStrong)
                .foregroundColor(Color.textPrimary)
                .lineLimit(1)

            Text(formattedTouch)
                .font(.captionStrong)
                .foregroundColor(Color.textPrimary)

            // Maturity badge — Phase 2.6 maturity tiers. Shows the coach
            // where the prediction came from: "PB" (curve), "N swims"
            // (historical with N recorded_times), or hidden for cold-start
            // (seed) since we have no data to show.
            if let label = prediction?.badgeLabel {
                Text(label)
                    .font(.numericSmall)
                    .foregroundColor(badgeColor)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(badgeColor.opacity(0.15))
                    .cornerRadius(3)
            }

            // PHASE 1 (T9, 2026-06-20): calibration badge. Small pill
            // next to the maturity badge, same visual style. Hidden
            // when `calibrationState` is nil (no calibration data
            // computed yet — the caller passes nil today; wiring
            // the actual lookup is a follow-up).
            if let state = calibrationState {
                Text(state.badgeText)
                    .font(.numericSmall)
                    .foregroundColor(state.badgeColor)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(state.badgeColor.opacity(0.15))
                    .cornerRadius(3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minWidth: 90, minHeight: 44, alignment: .leading)
        .background(Color.bgSelected)
        .cornerRadius(8)
    }

    private var swimmerName: String {
        guard let uuid = UUID(uuidString: waveAssignment.swimmerId) else {
            return waveAssignment.swimmerId
        }
        return swimmerNames[uuid] ?? waveAssignment.swimmerId
    }

    private var formattedTouch: String {
        guard waveAssignment.predictedTouchMs > 0 else { return "—" }
        let seconds = Double(waveAssignment.predictedTouchMs) / 1000.0
        return String(format: "%.1fs", seconds)
    }

    /// Badge color follows the maturity tier:
    ///   .none / .curve → gray (low confidence)
    ///   .learning    → yellow (still learning the swimmer)
    ///   .reliable / .excellent → green (trustworthy)
    private var badgeColor: Color {
        switch prediction?.maturity {
        case .excellent, .reliable: return Color.statusSuccess
        case .learning:            return Color.accentAmber
        default:                   return Color.textFaint
        }
    }
}

#Preview {
    SessionStartView(
        sessionId: UUID().uuidString,
        workoutSets: [],
        onComplete: { _, _ in }
    )
    .environment(AuthManager())
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
