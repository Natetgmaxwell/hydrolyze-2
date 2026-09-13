import SwiftUI

@MainActor
final class WorkoutDetailViewModel: ObservableObject {
    @Published var workout: Workout?
    @Published var sets: [WorkoutSet] = []
    @Published var isLoading: Bool = true
    @Published var errorMessage: String?
    @Published var showDeleteConfirmation: Bool = false

    let workoutService = WorkoutService()

    /// V0.49 Slice 1 (2026-08-22): cached snapshot of the most-recent
    /// session roster for this workout, populated once in `.task` and
    /// refreshed after a session is dismissed. `launchFragmentTiming`
    /// reads this on tap to decide whether to skip the picker sheet:
    /// - snapshot non-nil → reuse that session id, drop straight into
    ///   `TimingView` with the existing roster pre-selected (V0.49
    ///   spec: assume attendance is stable across the workout).
    /// - snapshot nil → today's picker (legacy / first fragment of
    ///   the day / no roster yet locked).
    /// Fetched best-effort (nil on any error) — surfacing a banner
    /// here would degrade the experience without changing the
    /// outcome (the picker is the safe default).
    @Published var latestRosterSnapshot: SessionRosterSnapshot?

    func loadWorkout(workoutId: String) async {
        isLoading = true
        errorMessage = nil

        do {
            async let workoutTask = workoutService.fetchWorkout(workoutId: workoutId)
            async let setsTask = workoutService.fetchWorkoutSets(workoutId: workoutId)
            workout = try await workoutTask
            sets = try await setsTask
        } catch {
            errorMessage = "Couldn't load workout: \(error)"
        }

        isLoading = false
    }

    /// V0.49 Slice 1 (2026-08-22): populate `latestRosterSnapshot`
    /// from the workout's most-recent session with ≥1 roster row.
    /// Called from the existing `.task` block in WorkoutDetailView.
    /// Refreshed after a session dismisses so the next tap sees the
    /// freshest roster (Edit Attendees upserts can land on the same
    /// session id).
    func loadLatestRoster(workoutId: String) async {
        do {
            latestRosterSnapshot = try await workoutService.fetchLatestSessionRoster(workoutId: workoutId)
        } catch {
            // Fail-open: the picker remains the default. We log so a
            // persistent failure (RLS, schema cache miss) is debuggable
            // but we do NOT surface a banner.
            print("[WorkoutDetail] latest-roster fetch failed: \(error.localizedDescription)")
            latestRosterSnapshot = nil
        }
    }

    /// V0.47 (2026-08-22): multi-pass fragment times. The set is 2×
    /// through, so a fragment can legitimately hold MULTIPLE recorded
    /// times — one per pass. The old [String: Int] map silently
    /// overwrote pass 1 with pass 2. Values are time_ms arrays
    /// ordered oldest→newest by created_at (fetch order). Rows without
    /// a fragment_id can't be attributed and are dropped.
    ///
    /// V0.48 Slice 1 (2026-08-22): carry owner attribution alongside
    /// the time. `FragmentTimeRecord.swimmerName` is nil for rows that
    /// were never paired (solo runs, pre-pair handoff, or engine-declined).
    /// Load path joins swimmer names via `paired_swimmer_id` in a single
    /// bulk fetch (≤2 round trips total: one for times, one for swimmers).
    @Published var recordedTimesByFragmentId: [String: [FragmentTimeRecord]] = [:]

    func loadFragmentTimes() async {
        guard !sets.isEmpty else { return }
        // Phase 1: fetch all times for all sets, build a flat list of
        // (fragmentId, timeMs, pairedSwimmerId, createdAt) tuples, and
        // collect unique paired_swimmer_ids for the join.
        struct PendingRow {
            let fragmentId: String
            let timeMs: Int
            let pairedSwimmerId: String?
            let createdAt: String
        }
        var pending: [PendingRow] = []
        var pairedIds = Set<String>()
        do {
            for set in sets {
                let times = try await workoutService.fetchTimesForSet(workoutSetId: set.id)
                for t in times where t.fragmentId != nil {
                    if let fid = t.fragmentId {
                        pending.append(PendingRow(
                            fragmentId: fid,
                            timeMs: t.timeMs,
                            pairedSwimmerId: t.pairedSwimmerId,
                            createdAt: t.createdAt
                        ))
                        if let pid = t.pairedSwimmerId { pairedIds.insert(pid) }
                    }
                }
                // Legacy rows from before the fragment stamp: they
                // carry workout_set_id but NULL fragment_id. Two
                // legitimate buckets:
                //   (a) the set has exactly ONE parsed fragment
                //       (unambiguous — attribute to it)
                //   (b) the set has ZERO parsed fragments (non-composite
                //       plain set like `8 x 50 Free @ 1:30`). V0.50
                //       (2026-08-30) added (b): these sets now write
                //       fragment_id = "set_<setId>" via the synthetic
                //       FragmentContext in setRow, so the load path
                //       can bucket them under the same key.
                //       Legacy rows pre-V0.50 still carry NULL — bucket
                //       them under the synthetic key for back-compat.
                if let frags = set.fragments, frags.count == 1, let only = frags.first {
                    for t in times where t.fragmentId == nil {
                        pending.append(PendingRow(
                            fragmentId: only.id,
                            timeMs: t.timeMs,
                            pairedSwimmerId: t.pairedSwimmerId,
                            createdAt: t.createdAt
                        ))
                        if let pid = t.pairedSwimmerId { pairedIds.insert(pid) }
                    }
                }
                // V0.50 (2026-08-30): non-composite sets (fragments
                // empty / nil). All NULL-fragment_id rows for this set
                // bucket under the synthetic key the V0.50 setRow
                // prefill stamps on. Both fresh V0.50 rows and any
                // pre-V0.50 legacy rows land here.
                let isNonComposite = (set.fragments ?? []).isEmpty
                if isNonComposite {
                    let syntheticKey = "set_\(set.id)"
                    for t in times where t.fragmentId == nil {
                        pending.append(PendingRow(
                            fragmentId: syntheticKey,
                            timeMs: t.timeMs,
                            pairedSwimmerId: t.pairedSwimmerId,
                            createdAt: t.createdAt
                        ))
                        if let pid = t.pairedSwimmerId { pairedIds.insert(pid) }
                    }
                }
            }
        } catch {
            print("[WorkoutDetail] fragment-times fetch failed: \(error.localizedDescription)")
            return
        }

        // Phase 2: one bulk swimmer fetch for the join. Empty set
        // (no paired rows at all) skips the round trip.
        var nameBySwimmerId: [String: String] = [:]
        if !pairedIds.isEmpty {
            do {
                let swimmers = try await workoutService.fetchSwimmersByIds(ids: Array(pairedIds))
                for s in swimmers { nameBySwimmerId[s.id] = s.firstName }
            } catch {
                // Name lookup failed — fall back to unattributed rendering
                // for every row. The chips still render the times correctly.
                print("[WorkoutDetail] swimmer-name join failed: \(error.localizedDescription)")
            }
        }

        // Phase 3: bucket by fragmentId, preserving created_at order
        // (oldest→newest) so the chip list reads chronologically.
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFallback = ISO8601DateFormatter()
        var map: [String: [FragmentTimeRecord]] = [:]
        for row in pending {
            let capturedAt = isoFormatter.date(from: row.createdAt)
                ?? isoFallback.date(from: row.createdAt)
                ?? Date()
            let record = FragmentTimeRecord(
                swimmerName: row.pairedSwimmerId.flatMap { nameBySwimmerId[$0] },
                timeMs: row.timeMs,
                capturedAt: capturedAt
            )
            map[row.fragmentId, default: []].append(record)
        }
        // Each bucket is already in fetch order (rep_index asc within set,
        // sets iterated in order); stable sort by capturedAt defends against
        // any out-of-order rows the DB returns for legacy fragment_ids.
        for (key, bucket) in map {
            map[key] = bucket.sorted { $0.capturedAt < $1.capturedAt }
        }
        recordedTimesByFragmentId = map
    }

    func deleteWorkout(workoutId: String) async {
        do {
            try await workoutService.deleteWorkout(workoutId: workoutId)
        } catch {
            errorMessage = "Couldn't delete workout."
        }
    }

    func markComplete(workoutId: String) async {
        do {
            _ = try await workoutService.updateWorkout(workoutId: workoutId, updates: ["status": "complete"])
            workout?.status = .complete
        } catch {
            errorMessage = "Couldn't update workout."
        }
    }

    func startSession() {
        print("[WorkoutDetail] startSession tapped — placeholder for SetPicker")
    }

    func editWorkout() {
        print("[WorkoutDetail] editWorkout tapped — placeholder for I7 builder")
    }
}

/// V0.55 S0a (2026-09-13): segmented picker mode for the
/// `WorkoutDetailView`. Default is `.structured` (today's behaviour).
/// `.asWritten` swaps the existing `WorkoutPreview` for the new
/// `RawWorkoutTextView` rendering. S1/S2 own the bidirectional
/// linkage between the two surfaces; S0a only wires the toggle.
enum WorkoutDisplayMode: String, CaseIterable, Identifiable {
    case structured
    case asWritten = "as_written"

    var id: String { rawValue }

    /// Picker labels — kept short for the segmented control. Plain
    /// copy per the design-quality gate (no aphorisms).
    var label: String {
        switch self {
        case .structured: return "Structured"
        case .asWritten:  return "As written"
        }
    }
}

/// WorkoutDetailView — pushed from WorkoutsListView. Shows parsed workout + actions.
struct WorkoutDetailView: View {
    let workoutId: String
    @Environment(AuthManager.self) private var authManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool
    @StateObject private var viewModel = WorkoutDetailViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var activeSession: ActiveSession? = nil
    @State private var navigateToBuilder = false
    @State private var timingPrefill: SetPrefill?
    @State private var showSessionStart = false
    @State private var pendingSessionId = UUID().uuidString
    // V0.49 Slice 1 (2026-08-22): state driving the Edit Attendees
    // sheet. `editAttendeesSessionId` reuses the active session id
    // (latestRosterSnapshot.sessionId) when one exists, so the edit
    // upsert lands on the same session and wave_assignments stays
    // consistent. `editAttendeesPreselected` seeds the picker from
    // the current roster so the coach sees who's in, not an
    // attendance-derived guess.
    @State private var showEditAttendees: Bool = false
    @State private var editAttendeesSessionId: String = UUID().uuidString
    @State private var editAttendeesPreselected: Set<UUID> = []
    // V0.52 Slice 2 (2026-09-06): per-fragment confirmation sheet.
    // When the skip-the-picker path is live (cached roster), tapping
    // a fragment or set row sets `pendingSheetContext` instead of
    // jumping straight to TimingView. The sheet renders the read-only
    // deck brief (set name + squad + lane count + close-finish
    // warning if any), with one Start CTA + a Same Squad chip. The
    // sheet's Start handler synthesizes wave_assignments (idempotent
    // via V0.51's helper) and then sets `activeSession` — same as
    // today's skip path, just behind one extra read-only confirmation
    // gate. Tapping Cancel returns to the workout list with no
    // side effects.
    @State private var pendingSheetContext: PendingSheetContext?
    // t_d59998d9 (2026-08-05): per-fragment recorded times held in
    // local component state until persistence runs (t_be09a643).
    // V0.48 Slice 1 (2026-08-22): [FragmentTimeRecord] per fragment —
    // carries owner attribution so the chip can render name-prefixed
    // when the pairing engine has resolved the row. Live captures from
    // `onRecord` arrive unowned (swimmerName nil); the pairing handoff
    // eventually fills them in, and the next reload from the DB
    // renders the owned chip form. Merge with the VM's DB map in
    // `.task` and append to by onRecord on each capture.
    @State private var recordedTimesByFragmentId: [String: [FragmentTimeRecord]] = [:]
    // ponytail (warmth-through-motion iter 6): on-appear reveal.
    // Same pattern as login reveal (d46c444), today reveal (0a90257),
    // workouts reveal (06c6823), swimmers reveal (61404f1, 1ffa02c),
    // and workouts+swimmers cohesion (19e0e9f). When the WorkoutDetail
    // is pushed, the content fades + scales in over Animations.springSoft,
    // gated by Reduce Motion for a11y.
    @State private var animateIn: Bool = false
    // V0.55 S0a (2026-09-13): segmented Structured | As written
    // picker. Default `.structured` matches today's behaviour — the
    // existing WorkoutPreview renders below the picker and the
    // RawWorkoutTextView only appears when the user opts in.
    // S2 will replace the picker copy / default / bidirectional
    // linkage; S0a only adds the wire.
    //
    // Debug-only env override: launch with
    // `-HYDROLYZE_FORCE_AS_WRITTEN 1` to skip the picker and render
    // the As-written surface on first appearance. Used by the
    // screenshot pipeline so we don't need to tap the segmented
    // control over SSH (where system taps via simctl/idb can't land
    // reliably on iOS 26). No-op when unset — production launches
    // follow the user's tap.
    @State private var displayMode: WorkoutDisplayMode = {
        if ProcessInfo.processInfo.environment["HYDROLYZE_FORCE_AS_WRITTEN"] == "1" {
            return .asWritten
        }
        return .structured
    }()

    /// Wrapper for `.fullScreenCover(item:)` — needs Identifiable to drive the cover.
    /// Plain `String?` doesn't conform; without this the bottom TabView stays visible during timing.
    private struct ActiveSession: Identifiable, Hashable {
        let id: String
        // Phase 2.6 v1.6.1: workoutSetId is the set the coach picked in
        // the wave preview. Threaded into TimingView via the
        // SessionStartView.onComplete callback so the save() filter has
        // the current set id. The prefill-based path also sets
        // workoutSetId in TimingView.onAppear, but the explicit param
        // is the cleaner source of truth and matches TodayView's path.
        let workoutSetId: String
        // V0.49 Slice 2 (2026-08-22): the roster snapshot's entries
        // for the in-TimingView roster strip. nil when the launch
        // follows the picker path (no cached roster) — the strip
        // then hides entirely and the picker flow renders exactly
        // as today. Hashable so the activeSession equality check in
        // `.onChange(of: activeSession)` still works (Hashable
        // conformance on ActiveSession is the .fullScreenCover
        // trigger mechanism, and adding the optional [RosterEntryLite]
        // requires RosterEntryLite to be Hashable too — which Slice 2
        // ships in `TimingView.swift`).
        let roster: [RosterEntryLite]?

        static func == (lhs: ActiveSession, rhs: ActiveSession) -> Bool {
            // V0.49 Slice 2 (2026-08-22): the cover dismissal
            // detection (`.onChange(of: activeSession)`) compares
            // for `nil`, so equality here is a strict identity
            // check. Including the roster in `hash(into:)` would
            // trigger false re-dismissals on roster change; we
            // want dismissal tied to the cover's open/close only.
            return lhs.id == rhs.id
                && lhs.workoutSetId == rhs.workoutSetId
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
            hasher.combine(workoutSetId)
        }
    }

    var body: some View {
        ZStack {
            Color.bgBase.ignoresSafeArea()

            ScrollView {
                if let workout = viewModel.workout {
                    VStack(alignment: .leading, spacing: 20) {
                        metadataSection(workout: workout)
                        // V0.55 S0a (2026-09-13): segmented picker —
                        // `Structured | As written`. Default `.structured`
                        // so today's WorkoutPreview stays the default
                        // surface; the new RawWorkoutTextView renders
                        // only when the user opts in. S2 replaces the
                        // picker copy + wiring + adds bidirectional
                        // linkage; S0a only adds the toggle. Segmented
                        // style is the platform primitive per the
                        // design-quality gate (no custom chrome).
                        Picker("Display mode", selection: $displayMode) {
                            ForEach(WorkoutDisplayMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 16)

                        // V0.55 S1: shared render surface. Both
                        // the details page and the builder preview
                        // route through `WorkoutStructureView`, which
                        // internally calls the single
                        // `WorkoutPreviewBuilder.fromWorkoutAndSets`
                        // projection. Adding a field to the
                        // projection (e.g. a future zone-term round-
                        // trip) now propagates to both surfaces from
                        // exactly one call site — no drift risk. S2
                        // will rework this into the rep-identity card
                        // layout; S1 only extracts the existing
                        // `WorkoutPreview` rendering behind the
                        // shared surface. The `switch displayMode`
                        // below routes between the structured
                        // preview and the as-written surface
                        // (S0a), exactly one of which renders at a
                        // time.
                        switch displayMode {
                        case .structured:
                            WorkoutStructureView(
                                workout: workout,
                                sets: viewModel.sets,
                                onFragmentTap: { _, _, rgIdx, _, fragment in
                                    launchFragmentTiming(repGroupIndex: rgIdx, fragment: fragment)
                                },
                                // t_d59998d9 (2026-08-05): pass the
                                // local-state recorded-times map so
                                // each fragment row can show "Saved
                                // 0:42.31" once the stopwatch stops.
                                recordedTimesByFragmentId: recordedTimesByFragmentId,
                                // V0.47 Slice 3 (2026-08-22):
                                // vocabulary card is end-of-session
                                // only — read-only contexts hide it.
                                // The detail view surfaces mappings
                                // via the per-row "edit" link instead.
                                showVocabularyCard: false
                            )
                            .padding(.horizontal, 16)
                        case .asWritten:
                            // Raw text lives on `workout.description`
                            // (the `workout_text` column in Postgres).
                            // Empty / nil → show a single-line note so
                            // the surface isn't blank.
                            let raw = (workout.description?.isEmpty == false)
                                ? workout.description!
                                : "No raw text recorded for this workout."
                            RawWorkoutTextView(rawText: raw)
                                .background(Color.bgRaised)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .padding(.horizontal, 16)
                        }
                        if let errorMessage = viewModel.errorMessage {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundColor(Color.statusError)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity)
                                .background(Color.statusError.opacity(0.1))
                                .cornerRadius(8)
                                .padding(.horizontal, 16)
                        }
                        setsList
                        actionButtons(workout: workout)
                    }
                    .padding(.vertical, 16)
                } else if !viewModel.isLoading {
                    Text(viewModel.errorMessage ?? "Workout not found")
                        .foregroundColor(Color.textMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                }
            }
            .redacted(reason: viewModel.isLoading && viewModel.workout == nil ? .placeholder : [])

            if viewModel.isLoading && viewModel.workout == nil {
                ProgressView()
                    .tint(Color.textMuted)
            }
        }
        .navigationTitle("")  // V0.54 details-tidy: blank nav title.
        // The large in-content heading (metadataSection) carries the
        // workout name. Showing it a second time in the nav bar was
        // the V0.54 details-tidy defect 2 — pick one, per iOS HIG.
        // .inline keeps the nav-bar compact (no large two-line title).
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    viewModel.showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(Color.statusError)
                }
            }
        }
        .alert("Delete Workout?", isPresented: $viewModel.showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    await viewModel.deleteWorkout(workoutId: workoutId)
                    dismiss()
                }
            }
        } message: {
            Text("This action cannot be undone.")
        }
        .fullScreenCover(item: $activeSession) { session in
            // Phase 2.6 v1.6.1 fix: pull the workoutSetId from the
            // active session envelope (the set the coach picked in the
            // wave preview via previewSetIndex), NOT from timingPrefill.
            // timingPrefill.workoutSetId is resolved in
            // launchFragmentTiming via viewModel.sets[safe: repGroupIndex],
            // but repGroupIndex is the index WITHIN a named set's
            // repGroups — not the index into the flat viewModel.sets
            // array. For composite workouts that lookup returns nil, so
            // timingPrefill.workoutSetId is nil and save() throws
            // "Session is missing its workout set". The onComplete
            // callback already computed the correct set id and stored it
            // in activeSession.workoutSetId — use that.
            //
            // V0.49 Slice 2 (2026-08-22): thread `roster` so the
            // in-TimingView strip has its initial snapshot. The
            // strip is read-only now (2026-08-23): attendee edits
            // live ONLY in this view's Edit Attendees sheet, so no
            // roster-updated callback is threaded back.
            TimingView(
                prefill: timingPrefill,
                sessionId: session.id,
                workoutSetId: session.workoutSetId.isEmpty ? timingPrefill?.workoutSetId : session.workoutSetId,
                roster: session.roster,
                // t_d59998d9 (2026-08-05) + t_be09a643 (2026-08-05)
                // + t_bec2b88b (2026-08-06): recorded-time callback.
                // Fires once when the stopwatch transitions out of
                // `.running` with the full StopwatchCapturePayload
                // (the canonical handoff shape). The payload carries
                // recordedTimeMs, fragment metadata, the original
                // set text, and session/coach/swimmer context —
                // everything the persistence layer needs. We (a)
                // attach the time to the local @State map so the
                // fragment row shows "Saved 0:42.31" immediately,
                // and (b) kick off persistence asynchronously so the
                // row lands in recorded_times with swimmer_id=NULL
                // + all spec metadata populated. The pairing handoff
                // runs once the row is saved (pairExistingRow) —
                // the handoff is its own typed result, never a throw.
                onRecord: { payload in
                    // V0.48 Slice 1 (2026-08-22): append a fresh
                    // FragmentTimeRecord with swimmerName nil. The
                    // pairing handoff runs asynchronously (pairExistingRow
                    // — out of scope for this slice); when it resolves, the
                    // swimmer is written to recorded_times.paired_swimmer_id
                    // and the next loadFragmentTimes() reload repaints the
                    // chip in owned form ("Jack 1:41.7"). Until then the
                    // chip renders as unowned, identical to today.
                    recordedTimesByFragmentId[payload.fragment.fragmentId, default: []].append(
                        FragmentTimeRecord(
                            swimmerName: nil,
                            timeMs: payload.recordedTimeMs,
                            capturedAt: Date()
                        )
                    )
                    // V0.46 fix (2026-08-20): do NOT persist a fragment
                    // row here. onRecord only fires for sessioned runs
                    // (assembleCapturePayload returns nil when sessionId
                    // is nil), and every sessioned run's save() writes
                    // ALL laps to recorded_times via the batch save
                    // (single-swimmer saveSession / multi-swimmer
                    // savePairedLaps). Persisting a fragment row here too
                    // double-writes the final lap (one raw null-swimmer +
                    // wave_number NULL row using the stopwatch total
                    // elapsed, plus the paired row for the same rep) —
                    // surfacing as an extra row on the review page. The
                    // batch save is the single writer. The map update
                    // above is kept so the fragment row still shows
                    // "Saved 0:42.31" in the workout list.
                }
            )
        }
        .navigationDestination(isPresented: $navigateToBuilder) {
            WorkoutBuilderView(workoutId: workoutId)
        }
        .sheet(isPresented: $showSessionStart) {
            SessionStartView(
                sessionId: pendingSessionId,
                workoutSets: viewModel.sets,
                // Phase 2.6 v1.6.1 fix: onComplete now passes
                // both the sessionId and the picked workoutSetId.
                // The picked set comes from SessionStartView's
                // previewSetIndex at Start time.
                onComplete: { sessionId, workoutSetId in
                    showSessionStart = false
                    // V0.49 Slice 2 (2026-08-22): the picker
                    // path passes nil roster into the cover —
                    // TimingView's strip is hidden (today's flow,
                    // exactly the same as pre-Slice 2 once the
                    // strip is gone). After the lockRoster write
                    // lands, the cover dismiss triggers the
                    // .onChange that calls `loadLatestRoster`, so
                    // the next launch uses the freshly-cached
                    // snapshot (now populated) and the strip
                    // appears.
                    activeSession = ActiveSession(
                        id: sessionId,
                        workoutSetId: workoutSetId,
                        roster: nil
                    )
                }
            )
        }
        // V0.49 Slice 1 (2026-08-22): Edit Attendees sheet. Same
        // SessionStartView component, but in `isEditMode = true`
        // with the current roster pre-selected. On Done,
        // `SessionStartViewModel.lockRoster` re-upserts
        // session_roster for the ACTIVE session id (the one we
        // threaded in), so wave_assignments stay consistent and
        // the next fragment-launch skip reads the fresh roster.
        .sheet(isPresented: $showEditAttendees) {
            SessionStartView(
                sessionId: editAttendeesSessionId,
                workoutSets: viewModel.sets,
                isEditMode: true,
                preselectedSwimmerIds: editAttendeesPreselected,
                onComplete: { _, _ in
                    showEditAttendees = false
                    // Refresh the cached roster so the next fragment
                    // launch sees the latest set (in case the coach
                    // added/removed swimmers via Edit Attendees).
                    Task {
                        await viewModel.loadLatestRoster(workoutId: workoutId)
                    }
                }
            )
        }
        // V0.52 Slice 2 (2026-09-06): per-fragment read-only
        // confirmation sheet. The skip-the-picker flow (any
        // fragment tap when a roster is cached) used to jump
        // straight into TimingView with no read-only confirmation.
        // The spec requires a one-tap read-only gate so the coach
        // sees who's in + which lane + which set BEFORE the
        // stopwatch starts. The sheet renders the cached roster
        // (no WaveAllocator run needed — V0.51 already wrote
        // wave_assignments rows). Tapping Start → synthesize
        // (idempotent guard) + activate the timing cover. Tapping
        // Cancel → return to the workout list with no side
        // effects.
        //
        // V0.52 Slice 3 (2026-09-06): the Same Squad chip
        // opens the existing Edit Attendees sheet so the coach
        // can swap a swimmer without leaving the workout
        // detail. The skip path uses the same V0.49 Edit flow
        // (SessionStartView in edit mode with the cached
        // roster pre-selected). Closing the Edit sheet
        // re-fetches the latest roster snapshot so the
        // fragment sheet's next render shows the fresh
        // squad — the synthesized wave_assignments get rebuilt
        // automatically on the next Start tap (V0.51
        // synthesizer is idempotent).
        .sheet(item: $pendingSheetContext) { ctx in
            FragmentWaveSheetView(
                context: ctx,
                // Default to 6 lanes per V0.52 decisions (the spec
                // default). The skip path doesn't carry a per-set
                // lane count today — V0.53 will thread the
                // workout's lane count through `latestRosterSnapshot`
                // so the sheet can show the real number. 6 is the
                // common Australian squad pool width and matches
                // WaveAllocator.PoolConfig()'s default.
                poolLaneCount: 6,
                hasCloseFinishWarning: false,
                onStart: {
                    pendingSheetContext = nil
                    // Reuse V0.51's idempotent synthesizer. Already
                    // exists on the WorkoutService instance cached
                    // inside WorkoutDetailViewModel. Iterates with
                    // the WaveAllocator only if missing — no
                    // double-write risk.
                    Task {
                        await viewModel.workoutService.synthesizeWaveAssignmentsIfMissing(
                            sessionId: ctx.sessionId,
                            workoutSetId: ctx.workoutSetId,
                            rosterEntries: ctx.entries,
                            coachId: ctx.coachId
                        )
                        activeSession = ActiveSession(
                            id: ctx.sessionId,
                            workoutSetId: ctx.workoutSetId,
                            roster: ctx.roster
                        )
                    }
                },
                onCancel: {
                    pendingSheetContext = nil
                },
                // V0.52 Slice 3: open Edit Attendees using
                // the cached roster. The Edit sheet dismisses
                // via the existing .sheet(isPresented:
                // $showEditAttendees) flow; its onComplete
                // refreshes `latestRosterSnapshot` so the
                // NEXT fragment tap's sheet shows the new
                // squad. We intentionally DON'T dismiss the
                // fragment sheet here — the coach may want
                // to swap multiple swimmers or just check
                // the squad without changing it. After Edit
                // dismisses, the fragment sheet stays open
                // and Start remains the next action.
                onEditAttendees: {
                    editAttendeesSessionId = ctx.sessionId
                    editAttendeesPreselected = Set(
                        ctx.entries.compactMap { entry in
                            UUID(uuidString: entry.swimmerId)
                        }
                    )
                    pendingSheetContext = nil
                    showEditAttendees = true
                }
            )
        }
        .task {
            await viewModel.loadWorkout(workoutId: workoutId)
            // V0.47 (2026-08-22): load persisted fragment times so the
            // chips render on revisit, not just during live capture.
            await viewModel.loadFragmentTimes()
            // V0.49 Slice 1 (2026-08-22): pre-fetch the latest roster
            // snapshot so the per-fragment timing launcher can decide
            // synchronously whether to skip the picker. Best-effort —
            // nil on any error keeps today's flow.
            await viewModel.loadLatestRoster(workoutId: workoutId)
            // V0.48 Slice 3 (2026-08-22): live-capture merge guard.
            // The .task block re-runs whenever WorkoutDetailView re-appears
            // (e.g. dismissed fullScreenCover → user re-enters via back
            // navigation before the row's persistence landed). A naive
            // overwrite would drop the live capture — the local @State
            // already carries the row the DB hasn't picked up yet. We
            // merge by UNION: for each fragment bucket, concat DB rows +
            // local rows, then dedupe by (timeMs + capturedAt rounded
            // to the second). The pairing handoff + DB reload will
            // eventually resolve owner attribution; this guard only
            // protects the in-flight merge so the chip never disappears
            // mid-session.
            recordedTimesByFragmentId = mergePersistedWithLive(
                persisted: viewModel.recordedTimesByFragmentId,
                live: recordedTimesByFragmentId
            )
        }
        // ponytail: workout detail fade-in on push. Gating by
        // reduceMotion is the standard a11y pattern (matches d46c444,
        // 0a90257, 06c6823, 61404f1, 1ffa02c, 19e0e9f).
        .opacity(animateIn ? 1.0 : 0.0)
        .scaleEffect(animateIn ? 1.0 : 0.98)
        .animation(reduceMotion ? nil : Animations.springSoft, value: animateIn)
        .onAppear { animateIn = true }
        // V0.49 Slice 1 (2026-08-22): re-fetch the latest roster
        // snapshot every time the timing cover dismisses. Two
        // reasons we want a fresh read on return:
        //   1. Picker → TimingView path: the coach just locked a
        //      roster, so `latestRosterSnapshot` should now reflect
        //      that session id (without this, the second tap on
        //      any fragment would re-show the picker).
        //   2. Edit Attendees → Done path: the sheet's onComplete
        //      already reloads, but a defensive refresh here covers
        //      a Cancel-tap on the edit sheet that still persisted
        //      (lockRoster runs on Done only — Cancel is a no-op,
        //      but the cover dismissal is the unified signal).
        .onChange(of: activeSession) { _, newValue in
            guard newValue == nil else { return }
            Task {
                await viewModel.loadLatestRoster(workoutId: workoutId)
            }
        }
    }

    // Per-set start buttons — inline in the sets list.
    // V0.35 (2026-08-12): sets with parsed fragments render as tappable
    // fragment rows in WorkoutPreview above — the per-set row below is
    // redundant for them (and whole-set timing is wrong for composites).
    // Show rows only for sets WITHOUT fragments: simple sets (e.g.
    // "8 x 50 free on 1:00") have no fragment CTAs, so this row is their
    // only timing entry point.
    @ViewBuilder
    private var setsList: some View {
        let fragmentlessSets = viewModel.sets.filter { ($0.fragments ?? []).isEmpty }
        if !fragmentlessSets.isEmpty || viewModel.sets.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sets")
                    .font(.eyebrow)
                    .foregroundColor(Color.textFaint)
                    .tracking(1.5)
                    .padding(.horizontal, 16)

                if viewModel.sets.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "list.bullet.rectangle.portrait")
                            .font(.largeTitle)
                            .foregroundStyle(Color.textMuted)
                        Text("No sets in this workout")
                            .font(.headline)
                        Text("Open in the workout builder to add sets.")
                            .font(.subheadline)
                            .foregroundStyle(Color.textMuted)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                }

                ForEach(fragmentlessSets) { set in
                    setRow(set)
                }
            }
        }
    }

    private func setRow(_ set: WorkoutSet) -> some View {
        let prefill = SetPrefill(
            stroke: set.stroke ?? "Free",
            distance: set.distance ?? 50,
            reps: set.reps,
            interval: set.intervalText,
            intensityLabel: set.intensityLabel,
            workoutSetId: set.id,
            // V0.38 Slice 4 (2026-08-16): forward the structured
            // intensity_type rawValue alongside the human label so the
            // timing flow can detect "3mt" without string-matching the
            // label. The DB persists rawValue ("3mt"); the parser emits
            // label ("3-minute all-out"). Both flow through.
            intensityType: set.intensityType,
            // V0.41 Slice 2 (2026-08-18): forward the set-level zone
            // term so the timing flow resolves each swimmer's zone
            // pace as the drop-rule standard + target.
            zoneTerm: set.zoneTerm,
            // V0.50 (2026-08-30): synthetic fragment context for
            // non-composite sets. Previously nil here left a saved
            // row with fragment_id=NULL — the V0.48 chip renderer's
            // `where t.fragmentId != nil` filter excluded it, so the
            // coach saw no chip at all. The synthetic context uses
            // `set_\(set.id)` as the fragmentId so:
            //   1. save() forwards it to recorded_times.fragment_id
            //   2. loadFragmentTimes bucketing finds it under the
            //      same key and renders chips inline on setRow
            //   3. parsed-fragment rows (composite sets) keep their
            //      own non-synthetic fragmentIds — no collision
            // The fragmentId is namespaced (`set_`) so a future
            // parsed fragment id can never match by accident.
            fragmentContexts: [FragmentContext(
                fragmentId: "set_\(set.id)",
                parentIntervalId: set.id,
                distance: set.distance ?? 50,
                intensity: set.intensityLabel,
                startType: set.startType,
                suit: set.suit,
                gear: set.gear,
                descriptor: set.label
            )],
            // V0.43a (2026-08-18): forward the set-level gear so the
            // VM persists it to `recorded_times.gear`. Mirrors
            // `WorkoutSet.gear: [String]?` — nil for bare sets, which
            // the save path forwards as a missing JSON key.
            gear: set.gear
        )
        let isTimeable = set.distance != nil && set.distance! > 0

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                timingPrefill = prefill
                // V0.49 Slice 1 (2026-08-22): apply the same skip
                // decision the fragment path uses — a cached roster
                // drops the coach straight into TimingView with the
                // existing session id; otherwise today's picker.
                // Reuses the same V0.49 mechanism (wave_assignments
                // keyed by session id resolves pairing on the timing
                // side without a second picker round-trip).
                //
                // V0.52 Slice 2 (2026-09-06): the skip path now
                // routes through the read-only confirmation sheet
                // (`pendingSheetContext`) instead of jumping
                // straight into TimingView. See the matching
                // comment in `launchFragmentTiming` for the
                // rationale. The set-row path uses `set.label` as
                // the sheet's title; the fragment path uses the
                // fragment descriptor when present, falling through
                // to the parent set's label.
                if let roster = viewModel.latestRosterSnapshot {
                    let sessionId = roster.sessionId
                    pendingSheetContext = PendingSheetContext(
                        sessionId: sessionId,
                        workoutSetId: set.id,
                        setLabel: set.label,
                        entries: roster.entries,
                        coachId: authManager.coachId
                    )
                } else {
                    pendingSessionId = UUID().uuidString
                    showSessionStart = true
                }
            } label: {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(set.label)
                            .font(.bodyEmphasis)
                            .foregroundColor(Color.textPrimary)
                            .multilineTextAlignment(.leading)

                        HStack(spacing: 6) {
                            // Gear badges
                            if let gear = set.gear, !gear.isEmpty {
                                Text(gear.joined(separator: ", "))
                                    .font(.captionStrong)
                                    .foregroundColor(Color.textMuted)
                            }
                            // Intensity label
                            if let intensity = set.intensityLabel {
                                Text(intensity)
                                    .font(.caption)
                                    .foregroundColor(Color.accentAmber)
                            }
                            // Dive badge
                            if set.dive == true {
                                Text("DIVE")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(Color.accentAmber)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.accentAmber.opacity(0.12))
                                    .cornerRadius(4)
                            }
                            // Suit badge
                            if set.suit == true {
                                Text("SUIT")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(Color.textMuted)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.bgInset)
                                    .cornerRadius(4)
                            }
                        }
                    }

                    Spacer()

                    if isTimeable {
                        // V0.54 details-tidy: disclosure chevron (was
                        // play.fill) with explicit 8pt trailing inset.
                        // The prior rendering had the icon flush
                        // against the right edge per the spec
                        // "disclosure triangle flush against right
                        // edge with no padding" defect — moving to
                        // chevron.right (matches WorkoutsListView's
                        // WorkoutRow disclosure, line 550) + 8pt
                        // trailing padding gives the row the standard
                        // list-row trailing inset.
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Color.textFaint)
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, 8)  // standard list-row trailing inset
                .padding(.vertical, 12)
                .background(isTimeable ? Color.clear : Color.clear)
            }
            .disabled(!isTimeable)
            .opacity(isTimeable ? 1 : 0.5)

            // V0.50 (2026-08-30): inline chip surface for non-composite
            // sets. Buckets under the synthetic `set_<setId>` key the
            // setRow prefill stamps on the saved row. Renders the same
            // 1-2 / 3+ tier logic as FragmentCTARow so a coach's eye
            // gets identical feedback for both a fragment-tapped set
            // and a set-row-tapped set. Hidden when no records (the
            // common case for sets not yet timed).
            let syntheticKey = "set_\(set.id)"
            let setTimes = recordedTimesByFragmentId[syntheticKey] ?? []
            if !setTimes.isEmpty {
                setChipsRow(records: setTimes, syntheticKey: syntheticKey)
            }

            Divider()
                .background(Color.bgInset)
                .padding(.leading, 16)
        }
    }

    // V0.50 (2026-08-30): chip strip rendered under non-composite set
    // rows. Mirrors the V0.48 tier logic from FragmentCTARow so a
    // coach's eye reads the same surface regardless of whether they
    // tapped a per-fragment CTA or a set-row play button. Inline chips
    // for 1-2 records; aggregate `N saved ▸` for 3+. The aggregate
    // opens the same per-fragment sheet via onAggregateTap when the
    // view declares one — for setRow, no aggregate sheet is wired in
    // this slice, so 3+ just renders the inline chip count for now
    // (deferred to a follow-up slice once the spec decides whether
    // set-level buckets deserve a sheet of their own).
    @ViewBuilder
    private func setChipsRow(records: [FragmentTimeRecord], syntheticKey: String) -> some View {
        HStack(spacing: 6) {
            if records.count <= 2 {
                ForEach(records) { rec in
                    Text(setChipText(rec))
                        .font(.numeric)
                        .foregroundColor(Color.textMuted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.bgInset)
                        .cornerRadius(8)
                }
            } else {
                Text("\(records.count) saved")
                    .font(.numeric)
                    .foregroundColor(Color.textMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.bgInset)
                    .cornerRadius(8)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    /// V0.50 (2026-08-30) → V0.54 details-tidy: single-chip formatter
    /// for set-level records. Mirrors `FragmentCTARow.chipLabel(for:)`
    /// (WorkoutPreview.swift:2687) so the coach's eye never has to
    /// context-switch between fragment-row chips and set-row chips.
    /// The prior version used `TimingSession.formatMs` (full
    /// M:SS.HH) for BOTH owned and unowned rows — that violated the
    /// spec example "Jack 1:41.7" which uses the compact sub-minute
    /// form. Fix: owned rows now render "Name · 33.10" (middot
    /// separator + compact owned time, per the established
    /// FragmentCTARow pattern), unowned rows keep "Saved · 0:33.10"
    /// (full form, with the "Saved" prefix preserved).
    private func setChipText(_ rec: FragmentTimeRecord) -> String {
        if rec.hasOwner, let name = rec.swimmerName {
            return "\(name) · \(compactOwnedTime(rec.timeMs))"
        }
        return "Saved · \(TimingSession.formatMs(rec.timeMs))"
    }

    /// V0.54 details-tidy: mirror of WorkoutPreview's `compactOwnedTime`
    /// (file-scope helper at WorkoutPreview.swift:3724). Owned rows
    /// drop the leading "0:" and the second hundredths digit for
    /// sub-minute times (e.g. "33.10" for 33_100ms), matching the
    /// spec example "Jack 1:41.7" for ≥1min and "33.10" for
    /// sub-minute. Inline here instead of importing across files
    /// because the helper is file-private in WorkoutPreview.swift.
    private func compactOwnedTime(_ ms: Int) -> String {
        let totalCs = ms / 10
        let cs = totalCs % 100
        let totalSec = totalCs / 100
        let sec = totalSec % 60
        let min = totalSec / 60
        if min >= 1 {
            let tenths = cs / 10
            return String(format: "%d:%02d.%d", min, sec, tenths)
        }
        return String(format: "%02d.%02d", sec, cs)
    }

    // t_c74dffbc (2026-08-04): per-fragment timing launch. Builds a
    // SetPrefill from the fragment's metadata so the live stopwatch opens
    // pre-filled with the fragment's distance, intensity, and start type.
    // The workoutSetId is the repGroup's parent set (resolved by index
    // against viewModel.sets); in production the parsed ParsedRepGroup
    // would carry an explicit workoutSetId from the server.
    //
    // fragmentContexts carries a single fragment context (the one the
    // coach tapped) so the save flow keys the prediction on the
    // fragment's distance / intensity / start — not the parent set.
    //
    // V0.49 Slice 1 (2026-08-22): SKIP-THE-PICKER.
    // `latestRosterSnapshot` is the cached most-recent session roster
    // for this workout, populated once in `.task` (and refreshed after
    // a session dismisses). On a roster hit we drop straight into
    // TimingView with the existing session id — `wave_assignments`
    // already keys off it, so the timing flow's pairing engine
    // resolves swimmers from those rows without ever asking the
    // coach to pick again. On a miss (legacy / first fragment of the
    // day / RLS-blank), we mint a fresh UUID and show today's picker
    // — the safe default. Fail-open: any error or empty roster
    // resolves to the picker path. workoutSetId is the parent's id
    // (not "" — passing "" would have save() throw "Session is
    // missing its workout set" for composite workouts per the long
    // comment at :279-:294).
    private func launchFragmentTiming(repGroupIndex: Int, fragment: ParsedFragment) {
        let parentSet = viewModel.sets[safe: repGroupIndex]
        let fragmentContext = FragmentContext(
            fragmentId: fragment.id ?? "fragment_\(repGroupIndex)_\(fragment.distance ?? 0)",
            parentIntervalId: parentSet?.id ?? "",
            distance: fragment.distance ?? parentSet?.distance ?? 50,
            intensity: fragment.intensity?.label ?? fragment.descriptor,
            startType: fragment.startType,
            suit: fragment.suit,
            gear: fragment.gear,
            descriptor: fragment.descriptor
        )
        let prefill = SetPrefill(
            stroke: fragment.stroke ?? parentSet?.stroke ?? "Free",
            distance: fragment.distance ?? parentSet?.distance ?? 50,
            reps: 1, // each fragment is one timed unit
            interval: parentSet?.intervalText,
            intensityLabel: fragment.intensity?.label ?? fragment.descriptor ?? parentSet?.intensityLabel,
            workoutSetId: parentSet?.id,
            // V0.38 Slice 4 (2026-08-16): forward the parent's
            // intensity_type so a fragment of a 3MT parent set still
            // triggers the 3MT timing flow. Fragments themselves don't
            // carry intensity_type — they inherit from the parent.
            intensityType: parentSet?.intensityType,
            // V0.41 Slice 2 (2026-08-18): a fragment of a zone parent
            // set inherits the parent's zone term — the per-fragment
            // timing still resolves each swimmer's zone pace.
            zoneTerm: parentSet?.zoneTerm,
            fragmentContexts: [fragmentContext],
            // V0.43a (2026-08-18): fragments inherit the parent's
            // gear because the per-fragment FragmentContext's own
            // gear (when present) wins via resolvedSaveGear's
            // fragment-first rule; this is the fallback for
            // fragments without explicit gear entries.
            gear: parentSet?.gear
        )
        timingPrefill = prefill
        // V0.49 Slice 1 skip path: read the cached snapshot (loaded
        // in `.task`). The snapshot is non-nil only when the
        // workout already has a locked roster — `wave_assignments`
        // rows for that session id drive pairing on the timing
        // side, so reusing the id is the entire mechanism.
        //
        // V0.52 Slice 2 (2026-09-06): the skip path now flows
        // through a per-fragment read-only confirmation sheet
        // (`pendingSheetContext`) instead of jumping straight into
        // TimingView. The sheet renders the set label, the cached
        // roster (one row per swimmer), and a single Start CTA.
        // The Start handler invokes V0.51's idempotent
        // `synthesizeWaveAssignmentsIfMissing` and then sets
        // `activeSession` — the same end state as the V0.49 path,
        // behind one extra tap the spec mandates ("the coach's
        // job at session start becomes ASSENT, not data entry").
        // Cancel dismisses without writing anything. Fragment-flow
        // memory: subsequent fragment taps re-use the cached
        // snapshot, so the sheet's Start handler is a 1-tap
        // acknowledgment per fragment, not a per-fragment
        // roster-picker round-trip.
        if let roster = viewModel.latestRosterSnapshot {
            let sessionId = roster.sessionId
            let setId = parentSet?.id ?? ""
            pendingSheetContext = PendingSheetContext(
                sessionId: sessionId,
                workoutSetId: setId,
                setLabel: fragment.descriptor ?? parentSet?.label ?? "Set",
                entries: roster.entries,
                coachId: authManager.coachId
            )
        } else {
            // Fallback path: today's flow. The session id is fresh
            // because no roster exists yet for this workout — the
            // picker will lock one, then `.task`'s re-run on the
            // next view appearance will populate the cache and the
            // following tap will skip.
            pendingSessionId = UUID().uuidString
            showSessionStart = true
        }
    }

    private func metadataSection(workout: Workout) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(workout.title ?? "Untitled")
                .font(.titleMedium)
                .foregroundColor(Color.textPrimary)

            // V0.54 details-tidy: inline metadata now reads as a
            // tinted status pill (was stray "·" middot dividers).
            // Matches the WorkoutsListView status dot + label
            // pattern (WorkoutsListView.swift:498-516) so the
            // coach's eye gets one consistent status vocabulary
            // across the list and the detail surface.
            HStack(spacing: 8) {
                if let scheduledAt = workout.scheduledAt {
                    Text(formatDate(scheduledAt))
                        .font(.caption)
                        .foregroundColor(Color.textFaint)
                }

                if let amPm = workout.amPm {
                    Text(amPm)
                        .font(.captionStrong)
                        .foregroundColor(Color.accentAmber)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentAmber.opacity(0.15))
                        .clipShape(Capsule())
                }

                statusPill(workout.status)
            }
        }
        .padding(.horizontal, 16)
    }

    /// V0.54 details-tidy: small status pill (capsule + tint) replacing
    /// the prior stray "·" middot + raw status text. Reuses the
    /// existing `statusColor(_:)` helper for the per-status color
    /// mapping (draft textFaint, scheduled textMuted, inProgress
    /// accentAmber, complete statusSuccess) — same vocabulary as
    /// the Workouts list dot + label.
    private func statusPill(_ status: WorkoutStatus) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor(status))
                .frame(width: 6, height: 6)
            Text(status.rawValue.capitalized)
                .font(.captionStrong)
                .foregroundColor(statusColor(status))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(statusColor(status).opacity(0.12))
        .clipShape(Capsule())
    }

    private func actionButtons(workout: Workout) -> some View {
        VStack(spacing: 12) {
            if workout.status == .draft || workout.status == .scheduled {
                Button("Edit Workout") {
                    navigateToBuilder = true
                }
                .font(.titleSmall)
                .foregroundColor(Color.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(Color.bgSunken)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.divider, lineWidth: 1)
                )
            }

            if workout.status == .inProgress {
                Button("Mark Complete") {
                    Task { await viewModel.markComplete(workoutId: workoutId) }
                }
                .font(.titleSmall)
                .foregroundColor(Color.statusSuccess)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(Color.bgSunken)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.statusSuccess.opacity(0.3), lineWidth: 1)
                )
            }

            // V0.49 Slice 1 (2026-08-22): Edit Attendees. Shown for ALL
            // statuses (not gated on draft/scheduled) because the
            // mid-session case is the spec's explicit edge case —
            // "a swimmer does leave/join" is handled via this button,
            // NOT by re-showing the picker on every fragment launch.
            // Below the existing buttons so the eye scans the
            // primary CTAs first; identical secondary style to Edit
            // Workout so the muscle memory is the same.
            Button("Edit Attendees") {
                // Reuse the latest roster's session id when one
                // exists so the upsert lands on the active session
                // (V0.49 spec: Done re-persists session_roster for
                // the ACTIVE session id). Falls back to a fresh UUID
                // when no roster exists yet — first-fragment edit
                // path — which becomes the new active id.
                editAttendeesSessionId = viewModel.latestRosterSnapshot?.sessionId ?? UUID().uuidString
                editAttendeesPreselected = Set(
                    (viewModel.latestRosterSnapshot?.entries ?? []).compactMap { entry in
                        UUID(uuidString: entry.swimmerId)
                    }
                )
                showEditAttendees = true
            }
            .font(.titleSmall)
            .foregroundColor(Color.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(Color.bgSunken)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.divider, lineWidth: 1)
            )
        }
        .padding(.horizontal, 16)
    }

    private func formatDate(_ dateStr: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: dateStr + "T00:00:00Z") ?? formatter.date(from: dateStr) ?? Date()
        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "EEE MMM d"
        return displayFormatter.string(from: date).uppercased()
    }

    private func statusColor(_ status: WorkoutStatus) -> Color {
        switch status {
        case .draft: return Color.textFaint
        case .scheduled: return Color.textMuted
        case .inProgress: return Color.accentAmber
        case .complete: return Color.statusSuccess
        }
    }

    // V0.48 Slice 3 (2026-08-22): merge the DB-loaded map with the
    // local @State's live captures. Dedupes by (timeMs, capturedAt
    // truncated to the second) — the same row arriving from both
    // sides is recognised by both fields matching within ±1s. The
    // pairing handoff may rewrite owner attribution between the
    // local capture and the DB load; when the dedupe key matches we
    // prefer the persisted record (its `swimmerName` is the one the
    // pairing engine has resolved, not the local capture's nil).
    //
    // Why truncate to the second: `capturedAt = Date()` on the live
    // append happens ~milliseconds before the row's created_at lands
    // in the DB, so equality on full Date would miss the dedupe. The
    // spec ("dedupe by timeMs+capturedAt-second is acceptable") accepts
    // this precision; in practice two real captures within the same
    // centisecond from the same stopwatch don't occur — the timer
    // can't fire twice in <1cs.
    //
    // Bucket-by-bucket iteration: O(N+M) where N = live buckets, M =
    // persisted buckets. Empty inputs short-circuit to the other side
    // (no work, no dedupe).
    private func mergePersistedWithLive(
        persisted: [String: [FragmentTimeRecord]],
        live: [String: [FragmentTimeRecord]]
    ) -> [String: [FragmentTimeRecord]] {
        if live.isEmpty { return persisted }
        if persisted.isEmpty { return live }
        var merged: [String: [FragmentTimeRecord]] = [:]
        let liveKeys = Set(live.keys)
        let persistedKeys = Set(persisted.keys)
        let allKeys = liveKeys.union(persistedKeys)
        for key in allKeys {
            let persistedRows = persisted[key] ?? []
            let liveRows = live[key] ?? []
            // Build a dedupe key for each persisted row and use it to
            // filter the live set. When the same key appears in both,
            // we keep the persisted version (its swimmerName is the
            // pairing-resolved one, not the local capture's nil).
            let persistedKeysByRow: Set<String> = Set(persistedRows.map(dedupeKey))
            let newLiveRows = liveRows.filter { !persistedKeysByRow.contains(dedupeKey($0)) }
            // Sort by capturedAt so the chip list stays chronological.
            let combined = (persistedRows + newLiveRows).sorted { $0.capturedAt < $1.capturedAt }
            merged[key] = combined
        }
        return merged
    }

    private func dedupeKey(_ record: FragmentTimeRecord) -> String {
        let secondBucket = Int(record.capturedAt.timeIntervalSince1970)
        return "\(record.timeMs)|\(secondBucket)"
    }
}

#Preview {
    NavigationStack {
        WorkoutDetailView(workoutId: "test-id")
    }
    .environment(AuthManager())
}

// MARK: - V0.52 Slice 2 — Per-fragment confirmation sheet

/// V0.52 Slice 2 (2026-09-06): the Identifiable context for the
/// per-fragment read-only deck-brief sheet. Carries everything the
/// sheet needs to render + Start the timing flow:
///   - `sessionId`: the cached roster's session id (the skip path's
///     reusable session — wave_assignments already keys off it)
///   - `workoutSetId`: the set the coach tapped (parent set for
///     composite fragments, per V0.50 spec)
///   - `setLabel`: human label like "8 × 50 Free"
///   - `entries`: the cached roster snapshot's entries (drives the
///     squad count, name resolution, and the Same Squad chip)
///   - `coachId`: passed into synthesizeWaveAssignmentsIfMissing
///
/// `id` is the sessionId — sheet(item:) treats each context as a
/// distinct presentation, so two rapid taps on different fragments
/// would re-render rather than ignore the second tap.
struct PendingSheetContext: Identifiable, Hashable {
    let sessionId: String
    let workoutSetId: String
    let setLabel: String
    let entries: [SessionRosterSnapshot.Entry]
    let coachId: String?

    var id: String { sessionId + ":" + workoutSetId }

    static func == (lhs: PendingSheetContext, rhs: PendingSheetContext) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var roster: [RosterEntryLite] {
        entries.map { entry in
            RosterEntryLite(
                swimmerId: entry.swimmerId,
                firstName: entry.firstName,
                lastName: entry.lastName
            )
        }
    }
}

/// V0.52 Slice 2 (2026-09-06): the read-only per-fragment deck
/// brief. Slimmer than the SessionStartView's WaveSheetView — it
/// renders the SET the coach is about to time (not the wave-by-lane
/// allocation, which V0.51 synthesized as placeholder rows rather
/// than computed via WaveAllocator). The squad is shown as a flat
/// name list with lane hints, plus the one-tap Start CTA.
///
/// Tapping Start → `onStart` → synthesizeWaveAssignmentsIfMissing
/// (idempotent) → dismiss + activate the timing cover. Tapping
/// Cancel → dismiss with no side effects.
///
/// "Same squad" chip (V0.52 Slice 3): wired here as the
/// `onEditAttendees` callback. Slice 2 ships the chip present but
/// inert (S3's Edit Attendees integration is the next slice).
struct FragmentWaveSheetView: View {
    let context: PendingSheetContext
    let poolLaneCount: Int
    let hasCloseFinishWarning: Bool
    let onStart: () -> Void
    let onCancel: () -> Void
    let onEditAttendees: (() -> Void)?

    /// Squad count shown on the chip + Start CTA subtitle.
    private var swimmerCount: Int { context.entries.count }

    /// Per-spec label: "SQUAD OF N" (matches the sheet's quiet
    /// vocabulary — no "Selected", no "Locked", just the count).
    private var squadLabel: String {
        swimmerCount == 1 ? "SQUAD OF 1" : "SQUAD OF \(swimmerCount)"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bgBase.ignoresSafeArea()
                VStack(spacing: 0) {
                    header
                    if hasCloseFinishWarning {
                        closeFinishBanner
                    }
                    squadScroll
                    sameSquadChip
                    startButton
                }
            }
            .navigationTitle("Confirm Squad")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onCancel)
                        .foregroundColor(Color.textPrimary)
                }
            }
            .interactiveDismissDisabled(true)
        }
    }

    /// Header — set label + lane count. The set label is the
    /// line a coach reads aloud ("Wave 1, on the zero — go!"); the
    /// lane count is the pool's spatial anchor (the coach knows
    /// "Lane 3" maps to a physical lane).
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("FRAGMENT")
                .font(.eyebrow)
                .tracking(1.0)
                .foregroundColor(Color.textFaint)
            Text(context.setLabel)
                .font(.titleMedium)
                .foregroundColor(Color.textPrimary)
                .multilineTextAlignment(.leading)
            HStack(spacing: 8) {
                Text("POOL")
                    .font(.eyebrow)
                    .tracking(1.0)
                    .foregroundColor(Color.textFaint)
                Text("\(poolLaneCount) LANES")
                    .font(.eyebrow)
                    .foregroundColor(Color.textMuted)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.bgDeep)
    }

    /// Squad list — names, one per row, no drag handles. The
    /// "N swimmers" prefix tells the coach at a glance who's
    /// in; the names below are the lineup.
    private var squadScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(squadLabel)
                        .font(.eyebrow)
                        .tracking(1.0)
                        .foregroundColor(Color.textFaint)
                    Spacer()
                    Text("\(poolLaneCount) LANE POOL")
                        .font(.eyebrow)
                        .foregroundColor(Color.textFaint)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                LazyVStack(spacing: 0) {
                    ForEach(context.entries, id: \.swimmerId) { entry in
                        HStack(spacing: 12) {
                            // Lane pill from the snapshot. nil for
                            // sessions without lane data → no pill.
                            if let lane = entry.lane {
                                Text("L\(lane)")
                                    .font(.numericSmall)
                                    .foregroundColor(Color.textFaint)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.bgInset)
                                    .cornerRadius(4)
                            }
                            Text(entry.displayName)
                                .font(.bodyEmphasis)
                                .foregroundColor(Color.textPrimary)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.bgRaised)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 12)
            }
        }
    }

    /// V0.52 Slice 3 placeholder: same-squad chip. Slice 2
    /// renders the chip present but inert (no `onEditAttendees`).
    /// Slice 3 will pass the Edit Attendees closure from the
    /// parent `WorkoutDetailView`.
    @ViewBuilder
    private var sameSquadChip: some View {
        HStack {
            Spacer()
            if let onEdit = onEditAttendees {
                Button(action: onEdit) {
                    HStack(spacing: 6) {
                        Image(systemName: "person.2.fill")
                            .font(.captionStrong)
                        Text("Same squad")
                            .font(.captionStrong)
                        Text("·")
                            .font(.captionStrong)
                            .foregroundColor(Color.textFaint)
                        Text("edit")
                            .font(.caption)
                            .foregroundColor(Color.textMuted)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.bgDeep)
                    .foregroundColor(Color.textPrimary)
                    .cornerRadius(8)
                }
            } else {
                // Slice 2: chip rendered but inert. Shows the
                // affordance so the layout is stable across
                // slices.
                HStack(spacing: 6) {
                    Image(systemName: "person.2.fill")
                        .font(.captionStrong)
                    Text("Same squad")
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

    /// Per-spec close-finish banner — same shape as the picker
    /// sheet's banner so the coach's eye reads the same warning
    /// across both surfaces. The skip path's synthesizeWaveAssignmentsIfMissing
    /// does NOT run a real WaveAllocator — placeholder rows have
    /// wave_number=1, lane=1, no cross-lane collisions. The banner
    /// therefore stays quiet for skip-path launches today; the
    /// future V0.53+ wave_assignment refresh will surface real
    /// collisions here.
    @ViewBuilder
    private var closeFinishBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.eyebrow)
                .foregroundColor(Color.accentAmber)
            Text("CLOSE FINISHES — coach can't LAP < 0.5s")
                .font(.eyebrow)
                .tracking(0.8)
                .foregroundColor(Color.accentAmber)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentAmber.opacity(0.15))
        .cornerRadius(8)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// Primary CTA. One tap → onStart → synthesize
    /// wave_assignments + open TimingView.
    private var startButton: some View {
        Button(action: onStart) {
            HStack {
                Text("Start Fragment")
                    .font(.titleSmall)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color.accentAction)
            .foregroundColor(Color.textOnAccent)
            .cornerRadius(12)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }
}

private extension SessionRosterSnapshot.Entry {
    /// Human-readable name from first/last (matches the
    /// `RosterEntryLite` projection's naming for visual consistency
    /// across skip-path UI surfaces).
    var displayName: String {
        switch (firstName, lastName) {
        case let (first?, last?) where !last.isEmpty:
            return "\(first) \(last)"
        case let (first?, _):
            return first
        case let (nil, last?) where !last.isEmpty:
            return last
        default:
            return "Swimmer"
        }
    }
}