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
    @StateObject private var viewModel = SessionStartViewModel()

    let sessionId: String
    let workoutSets: [WorkoutSet]
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

    private var coachId: String? {
        authManager.coachId
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "060e18").ignoresSafeArea()

                switch viewModel.step {
                case .rosterPicker:
                    RosterPickerView(viewModel: viewModel, coachId: coachId, sessionId: sessionId, workoutSets: workoutSets)
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
            .navigationTitle(viewModel.step == .rosterPicker ? "Select Swimmers" : "Wave Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(Color(hex: "09d4ee"))
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
            await viewModel.loadRoster(coachId: coachId)
        }
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

    /// Captured frame of each row in the `rosterScroll` coordinate space.
    /// Updated as rows scroll into view; consumed by the drag gesture to find
    /// which row is under the user's finger.
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
            swimmersList
            errorMessageView
            lockRosterButton
        }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(Color(hex: "4a6572"))
            TextField("Search swimmers", text: $viewModel.searchQuery)
                .foregroundColor(Color(hex: "e2f4fa"))
        }
        .padding(12)
        .background(Color(hex: "0d1f33"))
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
                        }
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
    private func addRowUnderPointToSelection(point: CGPoint) {
        for (id, frame) in rowFrames {
            guard frame.contains(point) else { continue }
            // Same row as last time — already added, nothing to do
            if id == lastAddedRowId { return }
            lastAddedRowId = id
            if !viewModel.selectedSwimmerIds.contains(id) {
                withAnimation(.easeInOut(duration: 0.12)) {
                    viewModel.toggleSwimmer(id)
                }
            }
            return  // one row per frame
        }
    }

    private var errorMessageView: some View {
        Group {
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.system(size: 14))
                    .foregroundColor(.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var lockRosterButton: some View {
        VStack(spacing: 8) {
            Button {
                Task {
                    await viewModel.lockRoster(sessionId: sessionId, workoutSets: workoutSets)
                }
            } label: {
                HStack {
                    if viewModel.isLoading {
                        ProgressView()
                            .tint(.white)
                            .padding(.trailing, 8)
                    }
                    Text("Lock Roster")
                        .font(.system(size: 17, weight: .semibold))
                    Text("(\(viewModel.selectedSwimmerIds.count))")
                        .font(.system(size: 15))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(viewModel.selectedSwimmerIds.isEmpty ? Color(hex: "1a3050") : Color(hex: "09d4ee"))
                .foregroundColor(viewModel.selectedSwimmerIds.isEmpty ? Color(hex: "4a6572") : Color(hex: "060e18"))
                .cornerRadius(12)
            }
            // Disabled if nothing selected OR if lockRoster is in-flight
            // (prevents double-tap creating duplicate session rows)
            .disabled(viewModel.selectedSwimmerIds.isEmpty || viewModel.isLoading)
        }
        .padding(16)
        .background(Color(hex: "0d1f33"))
    }
}

// MARK: - Swimmer Row

struct SwimmerRowView: View {
    let swimmer: Swimmer
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundColor(isSelected ? Color(hex: "09d4ee") : Color(hex: "4a6572"))
                VStack(alignment: .leading, spacing: 2) {
                    Text(swimmer.fullName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(Color(hex: "e2f4fa"))
                    if !swimmer.groups.isEmpty {
                        Text(swimmer.groups.map { $0.name }.joined(separator: ", "))
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "4a6572"))
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(isSelected ? Color(hex: "0d2847") : Color.clear)
        }
        .buttonStyle(.plain)
        // Smooth the checkmark + background transition on select/deselect.
        // Without this, the icon swap and the background fade were instant,
        // which felt choppy during drag-to-add (the gesture adds 5+ rows in
        // a second, each transition visible to the eye). With a spring, the
        // same transitions feel like a natural tap response.
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isSelected)
    }
}

// MARK: - Wave Preview

struct WavePreviewView: View {
    @ObservedObject var viewModel: SessionStartViewModel
    let swimmerNames: [UUID: String]
    let workoutSets: [WorkoutSet]
    let onStart: () -> Void

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

            // Lane picker (Phase 2.5-c / 2.6): coach-configurable 1-10 lanes.
            // Re-allocates waves on change using the existing predictions
            // (no DB roundtrip — predictions were built once in lockRoster).
            lanePicker

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
                            // PHASE 1 (T9.5, 2026-06-20): the current set
                            // + the calibration are threaded down to the
                            // chip for the calibration badge. The set is
                            // the one at `previewSetIndex`; the calibration
                            // is the SessionStartViewModel's instance
                            // (populated by `lockRoster` via T3.5).
                            set: workoutSets[safe: viewModel.previewSetIndex],
                            calibration: viewModel.calibration,
                            onMove: { fromId, toLane, toPos in
                                if let from = visibleAssignments.first(where: { $0.id == fromId }) {
                                    viewModel.moveSwimmer(from: from, toLane: toLane, toPosition: toPos)
                                }
                            }
                        )
                    }
                }
                .padding(.vertical, 16)
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.system(size: 14))
                    .foregroundColor(.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .multilineTextAlignment(.center)
            }

            resetButton
            startButton
        }
    }

    /// Per-wave close-finish banner. One row per wave that has any cross-lane
    /// collisions within `closeFinishThresholdMs`. Surfaces the problem before the
    /// coach starts the stopwatch — that's the whole point of the wave preview.
    private var closeFinishBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Color(hex: "f5a623"))
                Text("CLOSE FINISHES — coach can't LAP < 0.5s")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.8)
                    .foregroundColor(Color(hex: "f5a623"))
            }
            ForEach(waveCollisions.keys.sorted(), id: \.self) { wave in
                if let pairs = waveCollisions[wave] {
                    HStack(spacing: 6) {
                        Text("Wave \(wave + 1)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(hex: "e2f4fa"))
                        Text("·")
                            .foregroundColor(Color(hex: "4a6572"))
                        Text(pairs.map { "Lane \($0.laneA) ↔ Lane \($0.laneB) (gap \($0.gapMs)ms)" }
                            .joined(separator: "  •  "))
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "7a9bb0"))
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "3d2a00"))
        .cornerRadius(8)
        .padding(.horizontal, 16)
        .padding(.top, 8)
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
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(viewModel.previewSetIndex == 0 ? Color(hex: "4a6572") : Color(hex: "09d4ee"))
            }
            .disabled(viewModel.previewSetIndex == 0)

            VStack(spacing: 2) {
                Text("SET \(viewModel.previewSetIndex + 1) OF \(workoutSets.count)")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.0)
                    .foregroundColor(Color(hex: "4a6572"))
                if let currentSet = workoutSets[safe: viewModel.previewSetIndex] {
                    Text("\(currentSet.reps ?? 0) × \(currentSet.distance ?? 0)m \(currentSet.stroke ?? "")")
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "7a9bb0"))
                }
            }
            .frame(minWidth: 160)

            Button {
                viewModel.previewSetIndex = min(workoutSets.count - 1, viewModel.previewSetIndex + 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(viewModel.previewSetIndex >= workoutSets.count - 1 ? Color(hex: "4a6572") : Color(hex: "09d4ee"))
            }
            .disabled(viewModel.previewSetIndex >= workoutSets.count - 1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(hex: "0d1f33"))
    }

    // MARK: - Phase 2.5-c / 2.6 lane picker (coach-configurable 1-10 lanes)

    private var lanePicker: some View {
        VStack(spacing: 4) {
            HStack {
                Text("LANES")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.0)
                    .foregroundColor(Color(hex: "4a6572"))
                Spacer()
                Text("\(viewModel.poolConfig.laneCount)")
                    .font(.jetBrainsMono(size: 14, weight: .bold))
                    .foregroundColor(Color(hex: "09d4ee"))
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
            .tint(Color(hex: "09d4ee"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(hex: "0d1f33"))
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
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "09d4ee"))
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
                        .tint(.black)
                        .padding(.trailing, 8)
                }
                Text("Start Session")
                    .font(.system(size: 17, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color(hex: "09d4ee"))
            .foregroundColor(Color(hex: "060e18"))
            .cornerRadius(12)
        }
        .disabled(viewModel.isLoading)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
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
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Color(hex: "4a6572"))
                    .tracking(1.0)

                if hasTightGap {
                    Text("⚠ Tight Gap")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(hex: "f5a623"))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(hex: "3d2a00"))
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
                .stroke(Color(hex: "2a3f52"), style: StrokeStyle(lineWidth: 1.5, dash: [4]))
                .background(Color.clear)
                .frame(width: 60, height: 44)
                
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(Color(hex: "4a6572"))
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
            case .calibrating: return Color(hex: "f59e0b")
            case .calibrated:  return Color(hex: "10b981")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(swimmerName)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(Color(hex: "e2f4fa"))
                .lineLimit(1)

            Text(formattedTouch)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(hex: "09d4ee"))

            // Maturity badge — Phase 2.6 maturity tiers. Shows the coach
            // where the prediction came from: "PB" (curve), "N swims"
            // (historical with N recorded_times), or hidden for cold-start
            // (seed) since we have no data to show.
            if let label = prediction?.badgeLabel {
                Text(label)
                    .font(.system(size: 9, weight: .medium))
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
                    .font(.system(size: 9, weight: .medium))
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
        .background(Color(hex: "0d2847"))
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
        case .excellent, .reliable: return Color(hex: "10b981")
        case .learning:            return Color(hex: "f59e0b")
        default:                   return Color(hex: "4a6572")
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
