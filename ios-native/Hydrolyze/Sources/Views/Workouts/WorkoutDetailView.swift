import SwiftUI

@MainActor
final class WorkoutDetailViewModel: ObservableObject {
    @Published var workout: Workout?
    @Published var sets: [WorkoutSet] = []
    @Published var isLoading: Bool = true
    @Published var errorMessage: String?
    @Published var showDeleteConfirmation: Bool = false

    private let workoutService = WorkoutService()

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
                // carry workout_set_id but NULL fragment_id. If the
                // set has exactly ONE fragment, attribute them to it
                // (a single-fragment set is unambiguous).
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
                        WorkoutPreview(
                            workout: buildParsedWorkout(from: workout, sets: viewModel.sets),
                            // t_c74dffbc (2026-08-04): per-fragment CTA. Tapping
                            // a fragment builds a SetPrefill from the fragment's
                            // metadata and launches the live stopwatch. The
                            // workoutSetId is the repGroup's parent set; in
                            // production the parsed ParsedRepGroup carries a
                            // workoutSetId field. Here we resolve by index
                            // against the workout's sets list.
                            onFragmentTap: { _, _, rgIdx, _, fragment in
                                launchFragmentTiming(repGroupIndex: rgIdx, fragment: fragment)
                            },
                            // t_d59998d9 (2026-08-05): pass the local-state
                            // recorded-times map so each fragment row can
                            // show "Saved 0:42.31" once the stopwatch stops.
                            recordedTimesByFragmentId: recordedTimesByFragmentId,
                            // V0.47 Slice 3 (2026-08-22): vocabulary card
                            // is end-of-session only — read-only contexts
                            // hide it. The detail view surfaces mappings
                            // via the per-row "edit" link instead.
                            showVocabularyCard: false
                        )
                            .padding(.horizontal, 16)
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
        .navigationTitle(viewModel.workout?.title ?? "Workout")
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
            fragmentContexts: nil,
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
                if let roster = viewModel.latestRosterSnapshot {
                    activeSession = ActiveSession(
                        id: roster.sessionId,
                        workoutSetId: set.id,
                        // V0.49 Slice 2 (2026-08-22): populate
                        // the timing roster strip from the snapshot.
                        // Skip-the-picker path → strip is visible.
                        // Picker path (no snapshot) → strip hidden.
                        roster: roster.entries.map { entry in
                            RosterEntryLite(
                                swimmerId: entry.swimmerId,
                                firstName: entry.firstName,
                                lastName: entry.lastName
                            )
                        }
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
                        Image(systemName: "play.fill")
                            .font(.caption)
                            .foregroundColor(Color.textMuted)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(isTimeable ? Color.clear : Color.clear)
            }
            .disabled(!isTimeable)
            .opacity(isTimeable ? 1 : 0.5)

            Divider()
                .background(Color.bgInset)
                .padding(.leading, 16)
        }
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
        if let roster = viewModel.latestRosterSnapshot {
            activeSession = ActiveSession(
                id: roster.sessionId,
                workoutSetId: parentSet?.id ?? "",
                // V0.49 Slice 2 (2026-08-22): populate the
                // strip from the cached snapshot. nil → strip
                // hidden (picker path — same as today).
                roster: roster.entries.map { entry in
                    RosterEntryLite(
                        swimmerId: entry.swimmerId,
                        firstName: entry.firstName,
                        lastName: entry.lastName
                    )
                }
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
        VStack(alignment: .leading, spacing: 4) {
            Text(workout.title ?? "Untitled")
                .font(.titleMedium)
                .foregroundColor(Color.textPrimary)

            HStack(spacing: 8) {
                if let scheduledAt = workout.scheduledAt {
                    Text(formatDate(scheduledAt))
                        .font(.caption)
                        .foregroundColor(Color.textFaint)
                }

                if let amPm = workout.amPm {
                    Text("·")
                        .foregroundColor(Color.textFaint)
                    Text(amPm)
                        .font(.captionStrong)
                        .foregroundColor(Color.accentAmber)
                }

                Text("·")
                    .foregroundColor(Color.textFaint)
                Text(workout.status.rawValue.capitalized)
                    .font(.captionStrong)
                    .foregroundColor(statusColor(workout.status))
            }
        }
        .padding(.horizontal, 16)
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

    private func buildParsedWorkout(from workout: Workout, sets: [WorkoutSet]) -> ParsedWorkout {
        ParsedWorkout(
            title: workout.title,
            sections: [
                ParsedSection(
                    title: nil,
                    namedSets: [
                        ParsedNamedSet(
                            label: nil,
                            note: nil,
                            repGroups: sets.map { set in
                                // t_d59998d9 (2026-08-05): map the
                                // WorkoutSet's parsed leaf fragments into
                                // the ParsedRepGroup so FragmentCTARow
                                // renders. nil/empty fragments falls through
                                // to the static label path (unchanged from
                                // t_c74dffbc). The pace target reads from
                                // the parent set's intervalText, which is
                                // what the row's "pace target badge" wants.
                                let parsedFragments: [ParsedFragment]? = set.fragments?.map { f in
                                    let intensityType = ParsedIntensityType(rawValue: f.intensity) ?? .easy
                                    let intensity: ParsedIntensity? = (f.intensity == "unknown" || f.intensity.isEmpty)
                                        ? nil
                                        : ParsedIntensity(type: intensityType, label: f.intensity)
                                    return ParsedFragment(
                                        id: f.id,
                                        distance: f.distanceMeters,
                                        stroke: set.stroke,
                                        instruction: nil,
                                        intensity: intensity,
                                        intensityType: intensityType.rawValue,
                                        intensityLabel: f.intensity == "unknown" ? nil : f.intensity,
                                        startType: f.startType,
                                        suit: nil,
                                        gear: nil,
                                        descriptor: nil,
                                        confidence: f.confidence
                                    )
                                }
                                return ParsedRepGroup(
                                    reps: set.reps,
                                    distance: set.distance,
                                    stroke: set.stroke,
                                    interval: set.intervalText,
                                    intensity: set.intensityLabel.map {
                                        ParsedIntensity(
                                            type: ParsedIntensityType(rawValue: set.intensityType ?? "easy") ?? .easy,
                                            label: $0
                                        )
                                    },
                                    pacing: nil,
                                    pattern: [],
                                    patternType: nil,
                                    connectors: nil,
                                    note: nil,
                                    gear: set.gear,
                                    gearOptional: false,
                                    descend: nil,
                                    details: nil,
                                    dive: set.dive,
                                    suit: set.suit,
                                    ambiguousTerm: nil,
                                    fragments: parsedFragments,
                                    // V0.41 (2026-08-18): round-trip the
                                    // persisted set-level zone term so the
                                    // builder preview (Slice 3) and timing
                                    // flow (Slice 2) read it back.
                                    zoneTerm: set.zoneTerm
                                )
                            }
                        )
                    ]
                )
            ]
        )
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