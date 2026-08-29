import SwiftUI
import Supabase

/// SessionStartViewModel — orchestrates the session-start flow:
/// Step 1: roster picker (multi-select swimmers) → Step 2: wave preview (drag-and-drop)
/// Then "Start" writes wave_assignments and navigates to TimingView.
@MainActor
final class SessionStartViewModel: ObservableObject {

    enum Step: String {
        case rosterPicker
        case wavePreview
    }

    @Published var step: Step = .rosterPicker
    @Published var availableSwimmers: [Swimmer] = []
    @Published var selectedSwimmerIds: Set<UUID> = []
    @Published var searchQuery: String = ""
    @Published var waveAssignments: [WaveAssignment] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    @Published var sessionId: String?
    @Published var workoutSets: [WorkoutSet] = []
    @Published var previewSetIndex: Int = 0
    @Published var poolConfig: WaveAllocator.PoolConfig = WaveAllocator.PoolConfig()

    private var coachId: String?
    private(set) var pbBySwimmer: [String: Int] = [:]

    /// Per-set predictions: workoutSetId → swimmerId → Prediction. Built in
    /// `lockRoster` from the recorded_times + swimmer_pbs tables via the
    /// 3-layer HistoricalTimePredictor. Used by the WaveAllocator for
    /// per-set wave re-evaluation — a swimmer's 50 Free PB is a terrible
    /// predictor of their 200 IM time, so the wave order that minimises
    /// close finishes for Set 1 differs from the wave order for Set 2.
    /// Also surfaced in the wave preview UI as a "predicted from N swims"
    /// maturity badge per chip. (Phase 2.6 pairing engine v2.)
    private(set) var predictionsBySwimmerBySet: [String: [String: Prediction]] = [:]

    /// All recorded_times for the selected swimmers, fetched once during
    /// `lockRoster` and passed to the HistoricalTimePredictor per call.
    /// Kept around so the view layer can introspect maturity per chip.
    private(set) var recordedTimes: [RecordedTime] = []
    /// PHASE 1 (T3.5, 2026-06-20): the per-(swimmer, X, distance, stroke)
    /// calibration factors. Populated in `lockRoster` from a parallel
    /// fetch against `swimmer_suits` and `swimmer_starts`. Optional
    /// because it's set after the async fetch completes; the predictor
    /// handles a nil calibration as "no calibration applied" (multiplier
    /// of 1.0), so a missing calibration is safe.
    private(set) var calibration: CalibrationFactors?

    /// All swimmer_pbs for the selected swimmers, fetched once during
    /// `lockRoster` and passed to the HistoricalTimePredictor (Layer 2 fallback).
    private(set) var allPBs: [SwimmerPB] = []

    /// Coach preferences (prediction algorithm + confidence display toggle).
    /// Sourced from `AuthManager.coachPreferences` once sign-in is complete.
    var coachPreferences: CoachPreferences = .default

    // swimmerId → fullName map, populated during loadRoster for name resolution in wave preview
    var swimmerNamesById: [UUID: String] = [:]

    private let supabase = SupabaseService.shared.client
    private let swimmerService = SwimmerService()
    // V0.46 (2026-08-21): used by loadRoster to read the workout's
    // squad link (group_id) so the picker can filter the roster to
    // in-squad swimmers when the workout is squad-scoped.
    private let workoutService = WorkoutService()

    // V0.49 Slice 1 (2026-08-22): one-shot completion flag for
    // Edit Attendees. `lockRoster` sets this in edit mode (instead
    // of advancing to wavePreview); the view reads it via
    // `.onChange`, dismisses the sheet, and resets it. Kept
    // distinct from `createdSessionId` because that's `private(set)`
    // and the view-side reset would be a compile error.
    @Published var didCompleteEdit: Bool = false
    private(set) var createdSessionId: String?

    var selectedSwimmers: [Swimmer] {
        // Dedupe by id — if `availableSwimmers` somehow contains the same swimmer
        // twice (e.g. RLS join or stale cache), the optimizer would otherwise emit
        // two WaveAssignments for the same (swimmer, set) pair and the preview
        // would render the same swimmer twice. First occurrence wins.
        var seen = Set<String>()
        return availableSwimmers.filter { swimmer in
            guard selectedSwimmerIds.contains(UUID(uuidString: swimmer.id) ?? UUID()) else { return false }
            let (inserted, _) = seen.insert(swimmer.id)
            return inserted
        }
    }

    var filteredSwimmers: [Swimmer] {
        if searchQuery.isEmpty { return availableSwimmers }
        let q = searchQuery.lowercased()
        return availableSwimmers.filter {
            $0.fullName.lowercased().contains(q)
        }
    }

    /// How the current selection was arrived at — drives the caption above
    /// the picker so the coach can see why the roster looks like it does.
    ///
    /// Carries no counts: `selectedSwimmerIds.count` and
    /// `availableSwimmers.count` are the live truth, and duplicating them
    /// here would go stale the moment the coach taps a chip.
    enum RosterSeed: Equatable {
        /// Seeded from resolved attendance (explicit marks + standing
        /// schedules). The normal case once swimmers have onboarded.
        case attendance
        /// Nobody in the squad has any signal at all — no intents, no
        /// standing schedules. Falls back to selecting everyone so a coach
        /// mid-onboarding is never handed an empty roster.
        case noSignalFallback
        /// Attendance couldn't be resolved (workout has no date, or the
        /// fetch failed). Falls back to selecting everyone.
        case unavailable
    }

    /// Per-swimmer provenance for the picker chips, keyed by swimmer id.
    /// Empty when the roster wasn't seeded from attendance.
    ///
    /// `@Published` matters: this is an ObservableObject (not @Observable),
    /// so a plain property would mutate without notifying SwiftUI and the
    /// captions would never appear.
    @Published private(set) var attendanceReasons: [String: AttendanceResolver.Reason] = [:]
    @Published private(set) var rosterSeed: RosterSeed = .unavailable

    func loadRoster(
        coachId: String?,
        workoutId: String? = nil,
        // V0.49 Slice 1 (2026-08-22): Edit Attendees entry
        // point. When `isEditMode` is true the picker seeds from
        // `preselectedSwimmerIds` (the current roster) instead
        // of attendance-derived guesses. Normal mode is
        // unchanged — `isEditMode = false` skips the edit path.
        isEditMode: Bool = false,
        preselectedSwimmerIds: Set<UUID>? = nil
    ) async {
        self.coachId = coachId
        guard let coachId = coachId else { return }
        isLoading = true
        errorMessage = nil
        do {
            // V0.46 (2026-08-21): scope the picker to the workout's squad
            // when one is set. fetchSwimmersInGroup is the same query path
            // SwimmersListView uses for squad-scoped rows. Unscoped
            // workouts (no group_id) fall back to the coach-wide roster —
            // pre-existing behavior, preserved intentionally for legacy
            // workouts that predate the squad-link feature.
            var fetched: [Swimmer]
            if let workoutId = workoutId,
               let workout = try? await workoutService.fetchWorkout(workoutId: workoutId),
               let groupId = workout.groupId {
                fetched = try await swimmerService.fetchSwimmersInGroup(groupId: groupId)
            } else {
                fetched = try await swimmerService.fetchSwimmers(coachId: coachId)
            }
            // Dedupe by id — protects downstream ForEach (Identifiable) and the
            // optimizer from processing the same swimmer twice.
            var seen = Set<String>()
            availableSwimmers = fetched.filter { swimmer in
                let (inserted, _) = seen.insert(swimmer.id)
                return inserted
            }
            swimmerNamesById = Dictionary(uniqueKeysWithValues: availableSwimmers.compactMap { swimmer -> (UUID, String)? in
                guard let uuid = UUID(uuidString: swimmer.id) else { return nil }
                return (uuid, swimmer.fullName)
            })

            // V0.49 Slice 1 (2026-08-22): Edit Attendees bypasses
            // the attendance-derived seed and uses the current
            // roster ids as the initial selection. The picker
            // then renders with checkmarks on exactly who's
            // currently in the session, so the coach can add or
            // remove without having to re-find every swimmer.
            if isEditMode, let preselected = preselectedSwimmerIds {
                // Intersect with the loaded roster so the count
                // doesn't inflate on a stale preselection
                // (matches the v1.17 attendance-seed safety
                // check below).
                let available = Set(availableSwimmers.map(\.id))
                selectedSwimmerIds = Set(
                    preselected
                        .filter { available.contains($0.uuidString) }
                )
                rosterSeed = .attendance
                attendanceReasons = [:]
            } else {
                await seedSelectionFromAttendance(workoutId: workoutId)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// v1.17 Slice 5 — THE vision slice.
    ///
    /// Seed `selectedSwimmerIds` from resolved attendance instead of
    /// `selectAll()`. This is the single line of causation that was missing:
    /// every downstream consumer — the roster insert, the PB fetch, the
    /// recorded-times fetch, the wave preview, `wave_assignments`,
    /// `coarsePredictions`, and the Hungarian cost matrix — already derives
    /// from `selectedSwimmerIds`. Narrow it here and the pairing engine
    /// stops trying to match times to swimmers who aren't in the water.
    ///
    /// The coach can still add or remove anyone. This is a pre-seed, not a
    /// lock — "Coach is the authority" is preserved; the N taps are not.
    ///
    /// Falls back to `selectAll()` in exactly two cases, both of which mean
    /// "we know nothing", never "nobody is coming":
    ///   - the squad has no intents AND no standing schedules (onboarding)
    ///   - attendance couldn't be resolved at all (undated workout, fetch failed)
    ///
    /// A squad where everyone explicitly declined does NOT fall back. That
    /// is a real answer, and handing the coach a full roster on a morning
    /// nobody is coming would be worse than an empty one.
    private func seedSelectionFromAttendance(workoutId: String?) async {
        attendanceReasons = [:]

        guard let workoutId else {
            rosterSeed = .unavailable
            selectAll()
            return
        }

        do {
            let resolved = try await CoachIntentService()
                .fetchResolvedAttendance(forWorkoutId: workoutId)

            guard !resolved.hasNoSignal else {
                rosterSeed = .noSignalFallback
                selectAll()
                return
            }

            attendanceReasons = Dictionary(
                uniqueKeysWithValues: resolved.entries.map { ($0.swimmerId, $0.reason) }
            )
            // Intersect with the loaded roster: fetchResolvedAttendance reads
            // every non-archived swimmer, which may not be the same set the
            // picker is showing. Selecting an id that isn't in
            // `availableSwimmers` would silently inflate the count without
            // ever appearing as a chip.
            let available = Set(availableSwimmers.map(\.id))
            selectedSwimmerIds = Set(
                resolved.attendingIds
                    .filter { available.contains($0) }
                    .compactMap(UUID.init(uuidString:))
            )
            rosterSeed = .attendance
        } catch {
            // Includes AttendanceError.unschedulable. Don't surface an error
            // banner — the coach can still pick a roster by hand, which is
            // exactly what they did before this feature existed.
            rosterSeed = .unavailable
            selectAll()
        }
    }

    // V0.49 Slice 1 (2026-08-22): per-set prediction helper — shared
    // between the normal and edit branches of `lockRoster` so both
    // paths compute identical WaveAllocator inputs. PHASE 2.6 v1.13.0
    // uses PBService for the 5-way match (swimmer, stroke, distance,
    // intensity, gear) with tiered fallbacks. Returns the raw map;
    // callers decide whether to assign it to `predictionsBySwimmerBySet`.
    private func buildPerSetPredictions(
        workoutSets: [WorkoutSet],
        allPBsFetched: [SwimmerPB],
        allTimesFetched: [RecordedTime],
        calibration: CalibrationFactors
    ) -> [String: [String: Prediction]] {
        let pbService = PBService()
        var perSetPredictions: [String: [String: Prediction]] = [:]
        for set in workoutSets {
            guard set.stroke != nil, set.distance != nil else { continue }
            let intensity = set.intensityLabel ?? "moderate"
            let gear = "none"  // wave preview defaults to no gear
            var predsForSet: [String: Prediction] = [:]
            for swimmer in selectedSwimmers {
                if let pred = pbService.fetchPrediction(
                    swimmer: swimmer,
                    set: set,
                    intensity: intensity,
                    gear: gear,
                    prefs: coachPreferences,
                    recordedTimes: allTimesFetched,
                    pbs: allPBsFetched,
                    calibration: calibration
                ) {
                    predsForSet[swimmer.id] = pred
                }
            }
            if !predsForSet.isEmpty {
                perSetPredictions[set.id] = predsForSet
            }
        }
        return perSetPredictions
    }

    // V0.49 Slice 1 (2026-08-22): per-swimmer "best across any set"
    // fallback map. Surfaced through `pbBySwimmer` for the legacy
    // WavePreviewView tight-gap heuristic + debug paths. v2 reads
    // from `predictionsBySwimmerBySet` directly for the maturity
    // badges; the fallback map only exists for back-compat.
    private func buildPbFallbackMap(
        workoutSets: [WorkoutSet],
        perSetPredictions: [String: [String: Prediction]]
    ) -> [String: Int] {
        var fallbackPBMap: [String: Int] = [:]
        for set in workoutSets {
            guard let preds = perSetPredictions[set.id] else { continue }
            for (swimmerId, pred) in preds {
                if let existing = fallbackPBMap[swimmerId] {
                    fallbackPBMap[swimmerId] = min(existing, pred.timeMs)
                } else {
                    fallbackPBMap[swimmerId] = pred.timeMs
                }
            }
        }
        return fallbackPBMap
    }

    func toggleSwimmer(_ id: UUID) {
        if selectedSwimmerIds.contains(id) {
            selectedSwimmerIds.remove(id)
        } else {
            selectedSwimmerIds.insert(id)
        }
    }

    func selectAll() {
        selectedSwimmerIds = Set(availableSwimmers.compactMap { UUID(uuidString: $0.id) })
    }

    func clearAll() {
        selectedSwimmerIds.removeAll()
    }

    func lockRoster(
        sessionId: String,
        workoutSets: [WorkoutSet],
        poolConfig: WaveAllocator.PoolConfig = WaveAllocator.PoolConfig(),
        // V0.49 Slice 1 (2026-08-22): Edit Attendees mode — same
        // upsert path but skips the session-row upsert (the row
        // already exists) and the wave-preview step transition
        // (the sheet dismisses via `didCompleteEdit`). Defaults to
        // false so the normal picker flow is untouched.
        isEditMode: Bool = false
    ) async {
        guard !selectedSwimmers.isEmpty else { return }
        self.sessionId = sessionId
        self.workoutSets = workoutSets
        self.poolConfig = poolConfig

        isLoading = true
        errorMessage = nil

        do {
            // Build the session + roster rows (in-memory; sent in parallel below).
            struct SessionRow: Encodable {
                let id: String
                let coachId: String
                let startedAt: String
                // V0.49 hotfix (2026-08-22): the roster-skip lookup keys
                // on sessions.workout_id, but this row never wrote it —
                // every session in the DB has workout_id NULL, so
                // fetchLatestSessionRoster(workoutId:) could never match
                // and the picker showed every time. Derived from the
                // first set (one launch covers all sets of the workout).
                let workoutId: String?

                enum CodingKeys: String, CodingKey {
                    case id
                    case coachId = "coach_id"
                    case startedAt = "started_at"
                    case workoutId = "workout_id"
                }
            }
            let sessionRow = SessionRow(
                id: sessionId,
                coachId: self.coachId ?? "",
                startedAt: ISO8601DateFormatter().string(from: Date()),
                workoutId: workoutSets.first?.workoutId
            )
            struct RosterRow: Encodable {
                let sessionId: String
                let swimmerId: String
                let attendanceMarkedAt: String

                enum CodingKeys: String, CodingKey {
                    case sessionId = "session_id"
                    case swimmerId = "swimmer_id"
                    case attendanceMarkedAt = "attendance_marked_at"
                }
            }
            let rosterPayload = selectedSwimmers.map { swimmer in
                RosterRow(
                    sessionId: sessionId,
                    swimmerId: swimmer.id,
                    attendanceMarkedAt: ISO8601DateFormatter().string(from: Date())
                )
            }

            // PARALLEL FETCH (Phase 2.5-c + 2.6 performance): 4 independent
            // writes/fetches. The recorded_times + swimmer_pbs queries are
            // needed for the 3-layer HistoricalTimePredictor. Firing all
            // four concurrently cuts the Lock Roster wait from
            // sum(t_session + t_roster + t_pbs + t_times) to max of all
            // four. On a healthy Supabase: ~500ms (vs ~1-2s sequential).
            //
            // We can't annotate the async let with `: Void` — `.execute()`
            // returns `PostgrestResponse<Void>`, not `Void`. Letting the
            // compiler infer the type and awaiting the result works.
            let selectedSwimmerIds = selectedSwimmers.map { $0.id }
            // V0.49 Slice 1 (2026-08-22): in edit mode the session
            // row already exists — we only re-upsert session_roster
            // for the new selection. Re-upserting the session row
            // would overwrite `started_at` with `now()`, corrupting
            // the session timeline. Skipping is safe because
            // `sessions.id` is the PK — it can't be missing if
            // `latestRosterSnapshot` returned a session id.
            //
            // We split into two code paths (the edit-mode branch
            // drops the session upsert; the normal branch runs the
            // original 4-way parallel await) rather than mixing a
            // conditional inside an `async let` (the latter doesn't
            // compose cleanly with the trailing-`execute()` shape
            // used everywhere else in this method).
            if isEditMode {
                // RLS fix (2026-08-23): the edit path can arrive with a
                // freshly-generated session id (WorkoutDetailView falls
                // back to UUID().uuidString when no roster snapshot has
                // loaded yet — e.g. editing attendees before the first
                // timing launch of the day). session_roster's coach
                // policy requires session_id to reference a session the
                // caller owns; with no sessions row the roster upsert
                // throws 42501 ("new row violates row-level security
                // policy") — the exact error reported from the workout
                // page. Upsert the session row with ignoreDuplicates so
                // the common case (row exists) is a no-op that preserves
                // the original started_at, and the missing-row case
                // creates it before the roster write.
                _ = try await supabase.from("sessions")
                    .upsert(sessionRow, onConflict: "id", ignoreDuplicates: true)
                    .execute()
                // Deselect fix (2026-08-23): upsert alone can never REMOVE
                // a swimmer — on conflict it only adds/updates rows. Delete
                // every roster row for this session whose swimmer is not
                // in the new selection first, then upsert the selection
                // with onConflict matching UNIQUE(session_id, swimmer_id)
                // (the table's PK is a surrogate `id` the client never
                // sends, so a bare upsert would 23505 on re-kept rows).
                try await supabase.from("session_roster")
                    .delete()
                    .eq("session_id", value: sessionId)
                    // Filter fix (2026-08-23): PostgrestFilterBuilder.not()
                    // interpolates `value.rawValue` WITHOUT parentheses —
                    // passing the [String] array directly emitted
                    // `swimmer_id=not.in.<uuid>`, which PostgREST rejects
                    // ("failed to parse filter (not.in. ...)"). The `in`
                    // operator's grammar requires a parenthesized list.
                    // Hand-build the parens (same shape supabase-js
                    // documents for .not('col','in','(a,b,c)')).
                    .not("swimmer_id", operator: .in, value: "(\(selectedSwimmerIds.joined(separator: ",")))")
                    .execute()
                _ = try await supabase.from("session_roster")
                    .upsert(rosterPayload, onConflict: "session_id,swimmer_id")
                    .execute()
                // WaveAllocator still runs so the pairing engine
                // can rebuild waves if the roster changed shape
                // (added/removed swimmers), and predictions are
                // re-fetched below — these are read-only operations
                // and don't touch the session row.
                let pbResponse = try await supabase.from("swimmer_pbs")
                    .select()
                    .execute()
                let allPBsFetched = try JSONDecoder().decode([SwimmerPB].self, from: pbResponse.data)
                let allTimesFetched = try await swimmerService.fetchRecordedTimes(
                    swimmerIds: selectedSwimmerIds
                )
                self.allPBs = allPBsFetched
                self.recordedTimes = allTimesFetched
                let calibration = CalibrationFactors()
                _ = try await calibration.prefetch(forSwimmerIds: selectedSwimmerIds)
                self.calibration = calibration
                let perSetPredictions = buildPerSetPredictions(
                    workoutSets: workoutSets,
                    allPBsFetched: allPBsFetched,
                    allTimesFetched: allTimesFetched,
                    calibration: calibration
                )
                self.predictionsBySwimmerBySet = perSetPredictions
                self.pbBySwimmer = buildPbFallbackMap(workoutSets: workoutSets, perSetPredictions: perSetPredictions)
                waveAssignments = WaveAllocator.allocate(
                    roster: selectedSwimmers,
                    sets: workoutSets,
                    poolConfig: poolConfig,
                    predictions: perSetPredictions
                )
                createdSessionId = sessionId
                didCompleteEdit = true
                isLoading = false
                return
            }
            async let sessionInsert = supabase.from("sessions")
                .upsert(sessionRow)
                .execute()
            async let rosterInsert = supabase.from("session_roster")
                .upsert(rosterPayload)
                .execute()
            async let pbsFetch = supabase.from("swimmer_pbs")
                .select()
                .execute()
            async let timesFetch = swimmerService.fetchRecordedTimes(
                swimmerIds: selectedSwimmerIds
            )

            // Await writes first (writes must commit before we trust the
            // session exists; the reads can be parallel with the writes
            // but the predictor needs the data after).
            //
            // The write calls return `PostgrestResponse<Void>` — we don't
            // need the value, just need to know the write succeeded.
            // Explicit `_ =` silences the "Expression of type
            // 'PostgrestResponse<Void>' is unused" warning.
            _ = try await sessionInsert
            _ = try await rosterInsert
            let pbResponse = try await pbsFetch
            let allPBsFetched = try JSONDecoder().decode([SwimmerPB].self, from: pbResponse.data)
            let allTimesFetched = try await timesFetch

            self.allPBs = allPBsFetched
            self.recordedTimes = allTimesFetched

            // v1.17 Slice 5: the post-hoc promoteConfirmedToRoster call that
            // used to sit here is gone. It ran AFTER selectedSwimmerIds had
            // already been consumed by the roster insert, the times fetch,
            // the wave preview and wave_assignments — so it wrote into
            // session_roster and changed nothing the pairing engine ever
            // read. That ordering bug is exactly why attendance never
            // narrowed the candidate pool.
            //
            // Attendance is now applied at load time (seedSelectionFromAttendance),
            // so `selectedSwimmers` above IS the resolved attending set,
            // minus anyone the coach removed and plus anyone they added.
            // The roster insert at line ~284 already carries it.

            // V0.49 Slice 1 (2026-08-22): the edit-mode branch already
            // handled calibration + WaveAllocator + didCompleteEdit
            // and returned above. The code below is the normal-mode
            // path only.
            //
            // PHASE 2.6 v1.13.0: use PBService as the SINGLE function
            // for "what's this swimmer's predicted time for this set +
            // intensity + gear?" — factored into
            // `buildPerSetPredictions` so the edit-mode branch can
            // call it without copy-pasting the PBService /
            // CalibrationFactors setup. `WaveAllocator.allocate` is
            // a `static` method on the type (was an instance-method
            // call in 1b7d65c, which caused a 'static member cannot
            // be used on instance' error on the Mac Studio build).
            let calibration = CalibrationFactors()
            async let calibrationFetch = calibration.prefetch(
                forSwimmerIds: selectedSwimmerIds
            )
            _ = try await calibrationFetch
            self.calibration = calibration

            let perSetPredictions = buildPerSetPredictions(
                workoutSets: workoutSets,
                allPBsFetched: allPBsFetched,
                allTimesFetched: allTimesFetched,
                calibration: calibration
            )
            self.predictionsBySwimmerBySet = perSetPredictions
            self.pbBySwimmer = buildPbFallbackMap(workoutSets: workoutSets, perSetPredictions: perSetPredictions)

            waveAssignments = WaveAllocator.allocate(
                roster: selectedSwimmers,
                sets: workoutSets,
                poolConfig: poolConfig,
                predictions: perSetPredictions
            )

            step = .wavePreview
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Update the lane count and re-allocate waves for the current
    /// poolConfig. Used by the lane picker slider in WavePreviewView
    /// (Phase 2.5-c coach-configurable lanes).
    func setLaneCount(_ count: Int) {
        let clamped = max(1, min(10, count))
        guard clamped != poolConfig.laneCount else { return }
        poolConfig.laneCount = clamped
        // Re-run the allocation with the new lane count. We use the
        // existing predictions (no DB roundtrip needed) so the
        // re-allocation is instant. WaveAllocator.allocate is a
        // static method.
        guard !selectedSwimmers.isEmpty else { return }
        waveAssignments = WaveAllocator.allocate(
            roster: selectedSwimmers,
            sets: workoutSets,
            poolConfig: poolConfig,
            predictions: predictionsBySwimmerBySet
        )
    }

    func moveSwimmer(from source: WaveAssignment, toLane: Int, toPosition: Int) {
        guard let sourceIndex = waveAssignments.firstIndex(where: { $0.id == source.id }) else { return }

        var updated = waveAssignments

        // Swap position with whoever is already at (toLane, toPosition).
        if let targetIndex = updated.firstIndex(where: {
            $0.lane == toLane && $0.positionInLane == toPosition
        }) {
            updated[targetIndex].lane = source.lane
            updated[targetIndex].positionInLane = source.positionInLane
        }

        updated[sourceIndex].lane = toLane
        updated[sourceIndex].positionInLane = toPosition

        waveAssignments = updated
    }

    func resetToSuggested() {
        guard !selectedSwimmers.isEmpty else { return }
        // Re-run the WaveAllocator with the existing predictions. No
        // DB roundtrip needed — the predictions were computed once
        // in `lockRoster` and stored. WaveAllocator.allocate is a
        // static method.
        waveAssignments = WaveAllocator.allocate(
            roster: selectedSwimmers,
            sets: workoutSets,
            poolConfig: poolConfig,
            predictions: predictionsBySwimmerBySet
        )
    }

    func startSession() async -> Bool {
        guard let sessionId = sessionId else { return false }

        isLoading = true
        errorMessage = nil

        do {
            struct WaveAssignmentRow: Encodable {
                let id: String
                let sessionId: String
                let swimmerId: String
                let workoutSetId: String
                let lane: Int
                let positionInLane: Int
                let predictedTouchMs: Int
                let waveNumber: Int
                let sendOffOffsetMs: Int
                let coachId: String
                let createdAt: String

                enum CodingKeys: String, CodingKey {
                    case id
                    case sessionId = "session_id"
                    case swimmerId = "swimmer_id"
                    case workoutSetId = "workout_set_id"
                    case lane
                    case positionInLane = "position_in_lane"
                    case predictedTouchMs = "predicted_touch_ms"
                    case waveNumber = "wave_number"
                    case sendOffOffsetMs = "send_off_offset_ms"
                    case coachId = "coach_id"
                    case createdAt = "created_at"
                }
            }
            let assignmentsPayload = waveAssignments.map { wa in
                WaveAssignmentRow(
                    id: wa.id,
                    sessionId: sessionId,
                    swimmerId: wa.swimmerId,
                    workoutSetId: wa.workoutSetId,
                    lane: wa.lane,
                    positionInLane: wa.positionInLane,
                    predictedTouchMs: wa.predictedTouchMs,
                    waveNumber: wa.waveNumber,
                    sendOffOffsetMs: wa.sendOffOffsetMs,
                    coachId: self.coachId ?? "",
                    createdAt: ISO8601DateFormatter().string(from: Date())
                )
            }

            try await supabase.from("wave_assignments")
                .upsert(assignmentsPayload)
                .execute()

            createdSessionId = sessionId
            isLoading = false
            return true
        } catch {
            print("[SessionStartViewModel] Error in startSession: \(error)")
            errorMessage = error.localizedDescription
            isLoading = false
            return false
        }
    }
}