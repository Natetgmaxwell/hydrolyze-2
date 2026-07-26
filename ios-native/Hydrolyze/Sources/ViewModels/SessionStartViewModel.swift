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

    func loadRoster(coachId: String?, workoutId: String? = nil) async {
        self.coachId = coachId
        guard let coachId = coachId else { return }
        isLoading = true
        errorMessage = nil
        do {
            let fetched = try await swimmerService.fetchSwimmers(coachId: coachId)
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

            await seedSelectionFromAttendance(workoutId: workoutId)
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
        poolConfig: WaveAllocator.PoolConfig = WaveAllocator.PoolConfig()
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

                enum CodingKeys: String, CodingKey {
                    case id
                    case coachId = "coach_id"
                    case startedAt = "started_at"
                }
            }
            let sessionRow = SessionRow(
                id: sessionId,
                coachId: self.coachId ?? "",
                startedAt: ISO8601DateFormatter().string(from: Date())
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

            // PHASE 2.6 v1.13.0: use PBService as the SINGLE function
            // for "what's this swimmer's predicted time for this set +
            // intensity + gear?" Replaces the per-(swimmer, set) call
            // to HistoricalTimePredictor. The 4 code paths to the
            // same data (profile screen, wave preview, save flow,
            // coarsePredictions) all use this function now.
            //
            // For the wave preview, we use the set's intensityLabel
            // (e.g., 'moderate', 'max') and the swimmer's preferredGear
            // (defaults to 'none'). PBService does the 5-way match
            // (swimmer, stroke, distance, intensity, gear) with
            // tiered fallbacks: exact → any-gear-same-intensity →
            // any-intensity-same-stroke/distance → population seed.
            let pbService = PBService()
            // PHASE 1 (T3.5, 2026-06-20): the calibration factors are
            // fetched in parallel with the other inputs (the existing
            // async lets above). Empty calibration (no `swimmer_suits`
            // / `swimmer_starts` rows yet for these swimmers) is fine —
            // the predictor falls back to a multiplier of 1.0 (no
            // adjustment) when the helper returns nil. So this
            // prefetch is non-blocking in the sense that the
            // prediction flow works whether or not the data exists.
            let calibration = CalibrationFactors()
            async let calibrationFetch = calibration.prefetch(
                forSwimmerIds: selectedSwimmerIds
            )
            // Await calibration (in parallel with the other
            // continuations below; calibrationFetch is the 5th parallel
            // read alongside sessionInsert / rosterInsert / pbsFetch
            // / timesFetch above).
            _ = try await calibrationFetch
            self.calibration = calibration

            // PHASE 2.6 v1.13.0: use PBService as the SINGLE function
            // for "what's this swimmer's predicted time for this set +
            // intensity + gear?" Replaces the per-(swimmer, set) call
            // to HistoricalTimePredictor. The 4 code paths to the
            // same data (profile screen, wave preview, save flow,
            // coarsePredictions) all use this function now.
            //
            // For the wave preview, we use the set's intensityLabel
            // (e.g., 'moderate', 'max') and the swimmer's preferredGear
            // (defaults to 'none'). PBService delegates to
            // HistoricalTimePredictor which applies the suit +
            // start calibration from the `calibration` cache.
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
            self.predictionsBySwimmerBySet = perSetPredictions

            // Also build a per-swimmer prediction map (any set) for the
            // legacy `pbBySwimmer` accessor (still used by old debug paths
            // and by the v1 WavePreviewView's tight-gap heuristic). v2
            // surfaces predictions through `predictionsBySwimmerBySet`
            // for the maturity badges.
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
            self.pbBySwimmer = fallbackPBMap

            // WaveAllocator: constraint-aware wave + lane assignment using
            // the per-set predictions. Replaces the old WaveOptimizer.
            // WaveAllocator.allocate is a `static` method, so no instance
            // creation — call it on the type directly. (This was an
            // instance-method call in 1b7d65c, which caused a 'static
            // member cannot be used on instance' error on the Mac Studio
            // build.)
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