import Foundation
import Supabase

/// WorkoutService — query layer for workouts, workout_sets, recorded_times.
final class WorkoutService {
    private struct CachedParse {
        let workout: ParsedWorkout
    }

    private let supabase = SupabaseService.shared.client
    private var parseCache: [String: CachedParse] = [:]
    private let parseCacheLimit = 50

    private func parseCacheKey(for text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
    }

    /// Fetch today's scheduled workout (nearest future scheduled, or null if none).
    func fetchTodayWorkout(coachId: String) async throws -> Workout? {
        let todayStr = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        let response = try await supabase.from("workouts")
            .select("id, coach_id, title, description, scheduled_at, am_pm, completed_at, status, created_at, updated_at")
            .eq("coach_id", value: coachId)
            .eq("status", value: "scheduled")
            .gte("scheduled_at", value: todayStr)
            .order("scheduled_at", ascending: true)
            .limit(1)
            .execute()
        let workouts = try JSONDecoder().decode([Workout].self, from: response.data)
        return workouts.first
    }

    /// Fetch all workouts for a coach, most recent first.
    func fetchWorkouts(coachId: String) async throws -> [Workout] {
        do {
            let response = try await supabase.from("workouts")
                .select()
                .eq("coach_id", value: coachId)
                .filter("archived_at", operator: "is", value: "null")
                .order("created_at", ascending: false)
                .execute()
            return try JSONDecoder().decode([Workout].self, from: response.data)
        } catch {
            let msg = error.localizedDescription.lowercased()
            if msg.contains("column") && msg.contains("does not exist") {
                let response = try await supabase.from("workouts")
                    .select()
                    .eq("coach_id", value: coachId)
                    .order("created_at", ascending: false)
                    .execute()
                return try JSONDecoder().decode([Workout].self, from: response.data)
            }
            throw error
        }
    }

    /// Fetch a single workout with its sets.
    func fetchWorkout(workoutId: String) async throws -> Workout {
        let response = try await supabase.from("workouts")
            .select()
            .eq("id", value: workoutId)
            .single()
            .execute()
        return try JSONDecoder().decode(Workout.self, from: response.data)
    }

    /// Fetch all sets for a workout.
    func fetchWorkoutSets(workoutId: String) async throws -> [WorkoutSet] {
        let response = try await supabase.from("workout_sets")
            .select()
            .eq("workout_id", value: workoutId)
            .order("order_index", ascending: true)
            .execute()
        return try JSONDecoder().decode([WorkoutSet].self, from: response.data)
    }

    /// Create a new workout with optional sets.
    /// V0.45 (2026-08-18): sessionType parameter added — lets the
    /// template entry point tag a newly-created workout as "3mt" so
    /// the row badge survives the round-trip to the DB. Defaults to
    /// nil so existing callers are unaffected.
    func createWorkout(coachId: String, title: String?, description: String?, scheduledAt: String? = nil, workoutText: String? = nil, groupId: String? = nil, sessionType: String? = nil) async throws -> Workout {
        struct CreatePayload: Encodable {
            let coachId: String
            let title: String?
            let description: String?
            let scheduledAt: String?
            let status: String
            let workoutText: String?
            let groupId: String?
            /// V0.45 (2026-08-18): session template tag (e.g. "3mt").
            /// Optional — omitted from the payload when nil so the DB
            /// keeps the column null for non-template rows.
            let sessionType: String?

            enum CodingKeys: String, CodingKey {
                case coachId = "coach_id"
                case title
                // NOTE: `description` is deliberately NOT in CodingKeys —
                // it maps to the same column as workoutText (workout_text),
                // and a duplicate raw value is a compile error. The
                // property stays for call-site compatibility; it never
                // encodes. workoutText is the single source for the column.
                case scheduledAt = "scheduled_at"
                case status
                case workoutText = "workout_text"
                case groupId = "group_id"
                case sessionType = "session_type"
            }
        }
        let payload = CreatePayload(
            coachId: coachId,
            title: title,
            description: description,
            scheduledAt: scheduledAt,
            status: "draft",
            workoutText: workoutText,
            groupId: groupId,
            sessionType: sessionType
        )
        let response = try await supabase.from("workouts")
            .insert(payload)
            .select()
            .single()
            .execute()
        return try JSONDecoder().decode(Workout.self, from: response.data)
    }

    /// Call the parse-workout Edge Function to parse workout text.
    func parseWorkout(text: String) async throws -> ParsedWorkout {
        let cacheKey = parseCacheKey(for: text)
        if let cached = parseCache[cacheKey] {
            return cached.workout
        }

        struct ParseRequest: Encodable { let workoutText: String }
        let body = try JSONEncoder().encode(ParseRequest(workoutText: text))
        var request = URLRequest(url: URL(string: "https://flidjtldfvrrntzwtnsq.supabase.co/functions/v1/parse-workout")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZsaWRqdGxkZnZycm50end0bnNxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjE1MjcyODMsImV4cCI6MjA3NzEwMzI4M30.kRhOyhPLVmVww6W03wMrlZnX0yeD6F73_cUpaOaRldE", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "ParseWorkout", code: (response as? HTTPURLResponse)?.statusCode ?? 500)
        }
        let parsedWorkout = try JSONDecoder().decode(ParsedWorkout.self, from: data)
        parseCache[cacheKey] = CachedParse(workout: parsedWorkout)
        if parseCache.count > parseCacheLimit, let oldestKey = parseCache.keys.first {
            parseCache.removeValue(forKey: oldestKey)
        }
        return parsedWorkout
    }

    /// Synchronous on-device parse path. Delegates to `WorkoutParser`
    /// (an MVP port of `scripts/parser-bench/engine.ts`). Use this for
    /// the typical coach input that fits the common case — the result
    /// is a single section, single named set bundling every extracted
    /// RepGroup. For inputs that need FBBF rotation, N.X notation,
    /// same-as-above references, notes-as-labels, or odd/even pairing,
    /// fall back to the async `parseWorkout(text:)` server path.
    func parseWorkoutSync(_ text: String) -> ParsedWorkout {
        return WorkoutParser.parse(text)
    }

    /// Create a single set on a workout.
    func createWorkoutSet(workoutId: String, setData: [String: String]) async throws -> WorkoutSet {
        var combined: [String: String] = ["workout_id": workoutId]
        setData.forEach { combined[$0.key] = $0.value }

        let response = try await supabase.from("workout_sets")
            .insert(combined)
            .select()
            .single()
            .execute()
        return try JSONDecoder().decode(WorkoutSet.self, from: response.data)
    }

    /// Update a workout (status, title, etc.).
    func updateWorkout(workoutId: String, updates: [String: String]) async throws -> Workout {
        var combined: [String: String] = updates
        combined["id"] = workoutId

        let response = try await supabase.from("workouts")
            .update(combined)
            .eq("id", value: workoutId)
            .select()
            .single()
            .execute()
        return try JSONDecoder().decode(Workout.self, from: response.data)
    }

    /// Update a workout set (mark complete, update fields).
    func updateWorkoutSet(setId: String, updates: [String: String]) async throws -> WorkoutSet {
        var combined: [String: String] = updates
        combined["id"] = setId

        let response = try await supabase.from("workout_sets")
            .update(combined)
            .eq("id", value: setId)
            .select()
            .single()
            .execute()
        return try JSONDecoder().decode(WorkoutSet.self, from: response.data)
    }

    func archiveWorkout(workoutId: String) async throws {
        try await supabase.from("workouts")
            .update(["archived_at": ISO8601DateFormatter().string(from: Date())])
            .eq("id", value: workoutId)
            .execute()
    }

    /// Delete a workout and all its sets.
    func deleteWorkout(workoutId: String) async throws {
        try await supabase.from("workouts")
            .delete()
            .eq("id", value: workoutId)
            .execute()
    }

    /// Record a time for a swimmer on a set (or standalone workout).
    func recordTime(
        swimmerId: String,
        timeMs: Int,
        repIndex: Int,
        intensity: String,
        workoutSetId: String? = nil,
        workoutId: String? = nil,
        gear: String? = nil,
        waveNumber: Int = 1,
        paceDistance: Int? = nil
    ) async throws -> RecordedTime {
        struct RecordPayload: Encodable {
            let swimmerId: String
            let timeMs: Int
            let repIndex: Int
            let intensity: String
            let workoutSetId: String?
            let workoutId: String?
            let gear: String?
            let waveNumber: Int
            let paceDistance: Int?
        }
        let payload = RecordPayload(
            swimmerId: swimmerId,
            timeMs: timeMs,
            repIndex: repIndex,
            intensity: intensity,
            workoutSetId: workoutSetId,
            workoutId: workoutId,
            gear: gear,
            waveNumber: waveNumber,
            paceDistance: paceDistance
        )
        let response = try await supabase.from("recorded_times")
            .insert(payload)
            .select()
            .single()
            .execute()
        return try JSONDecoder().decode(RecordedTime.self, from: response.data)
    }

    /// Fetch recorded times for a swimmer within a time window (for progression chart).
    func fetchRecordedTimes(swimmerId: String, since: Date) async throws -> [RecordedTime] {
        let formatter = ISO8601DateFormatter()
        let sinceStr = formatter.string(from: since)
        let response = try await supabase.from("recorded_times")
            .select()
            .eq("swimmer_id", value: swimmerId)
            .gte("created_at", value: sinceStr)
            .order("created_at", ascending: true)
            .execute()
        return try JSONDecoder().decode([RecordedTime].self, from: response.data)
    }

    /// Fetch recorded times for a specific workout set.
    func fetchTimesForSet(workoutSetId: String) async throws -> [RecordedTime] {
        let response = try await supabase.from("recorded_times")
            .select()
            .eq("workout_set_id", value: workoutSetId)
            .order("rep_index", ascending: true)
            .execute()
        return try JSONDecoder().decode([RecordedTime].self, from: response.data)
    }

    /// V0.48 Slice 1 (2026-08-22) — bulk fetch swimmers by id for the
    /// fragment-time owner join. One round trip; the caller (typically
    /// `WorkoutDetailViewModel.loadFragmentTimes`) collects the unique
    /// `paired_swimmer_id`s from a set of `RecordedTime` rows and passes
    /// them here. Returns the full row (we only need `first_name` but
    /// `Swimmer` is the standard decode target). Empty input → empty
    /// output, never a DB round trip.
    ///
    /// Lives on `WorkoutService` (not `SwimmerService`) because SwimmerService
    /// is in a squad-link WIP branch and is on this slice's DO-NOT-TOUCH list.
    func fetchSwimmersByIds(ids: [String]) async throws -> [Swimmer] {
        guard !ids.isEmpty else { return [] }
        let response = try await supabase.from("swimmers")
            .select()
            .in("id", values: ids)
            .execute()
        return try JSONDecoder().decode([Swimmer].self, from: response.data)
    }

    /// Insert structured sets from a parsed workout into workout_sets.
    func createSetsForWorkout(workoutId: String, from parsed: ParsedWorkout) async throws {
        struct SetRow: Encodable {
            let workout_id: String
            let reps: Int?
            let distance: Int?
            let stroke: String?
            let interval_text: String?
            let intensity_type: String?
            let intensity_label: String?
            // V0.41 (2026-08-18): set-level zone term, persisted so the
            // timing flow (Slice 2) and builder preview (Slice 3) read
            // it back from the DB row.
            let zone_term: String?
            let gear: [String]?       // Phase 1 fix: send full gear array, not just .first
            let dive: Bool            // Phase 1 metadata
            let suit: Bool            // Phase 1 metadata
            let start_type: String    // Phase 1 metadata: derived from dive
            let order_index: Int
            // V0.35 (2026-08-12): parsed leaf fragments, persisted as JSONB.
            let fragments: [WorkoutSetFragment]?

            enum CodingKeys: String, CodingKey {
                case workout_id, reps, distance, stroke
                case interval_text, intensity_type, intensity_label
                case zone_term
                case gear, dive, suit, start_type, order_index
                case fragments
            }
        }

        var sortOrder = 0
        for section in parsed.sections {
            for namedSet in section.namedSets {
                for group in namedSet.repGroups {
                    guard let distance = group.distance else {
                        print("⚠️ Skipping set insert: distance is nil for workout \(workoutId)")
                        continue
                    }
                    let dive = group.dive ?? false
                    // V0.35 (2026-08-12): persist the parser's leaf fragments
                    // so the on-the-day detail view can render tappable
                    // fragment rows. Fragments without a deterministic id
                    // (pre-V0.35 server, on-device parser) are skipped — a
                    // fragment that can't be keyed by fragment_id is untimeable.
                    let fragments: [WorkoutSetFragment]? = group.fragments?.enumerated().compactMap { idx, f in
                        guard let id = f.id, !id.isEmpty else {
                            print("⚠️ Skipping fragment without id for workout \(workoutId)")
                            return nil
                        }
                        return WorkoutSetFragment(
                            id: id,
                            orderIndex: idx,
                            distanceMeters: f.distance ?? 0,
                            reps: group.reps ?? 1,
                            intensity: f.intensity?.label ?? "unknown",
                            // FIX (2026-08-19): per-fragment start type —
                            // was smearing the PARENT's dive flag onto every
                            // fragment, so "75 DIVE + 25 easy" timed the
                            // easy leg as a dive too. The fragment's own
                            // parsed start_type is authoritative (dive/push/
                            // wall from the server); the coach's rule: all
                            // fragments default to push unless stated.
                            startType: f.startType ?? "push",
                            paceTargetSec: Self.paceTargetSeconds(from: group.interval),
                            confidence: f.confidence
                        )
                    }
                    let row = SetRow(
                        workout_id: workoutId,
                        reps: group.reps ?? 1,
                        distance: distance,
                        stroke: group.stroke,
                        interval_text: group.interval,
                        intensity_type: group.intensity?.type.rawValue,
                        intensity_label: group.intensity?.label,
                        zone_term: group.zoneTerm,
                        gear: group.gear,
                        dive: dive,
                        suit: group.suit ?? false,
                        // Derive start_type from dive flag: dive → 'dive', else default 'in_water'
                        start_type: dive ? "dive" : "in_water",
                        order_index: sortOrder,
                        fragments: fragments
                    )
                    sortOrder += 1
                    _ = try await supabase.from("workout_sets")
                        .insert(row)
                        .execute()
                }
            }
        }
    }

    /// V0.35 (2026-08-12): parse a send-off interval ("1:30" → 90) into
    /// seconds for the fragment's pace_target_sec. nil for open intervals.
    private static func paceTargetSeconds(from interval: String?) -> Int? {
        guard let interval = interval else { return nil }
        let parts = interval.split(separator: ":")
        guard parts.count == 2, let minutes = Int(parts[0]), let seconds = Int(parts[1]) else { return nil }
        return minutes * 60 + seconds
    }

    /// Replace all sets for a workout — delete then re-insert.
    func replaceSetsForWorkout(workoutId: String, parsed: ParsedWorkout) async throws {
        try await supabase.from("workout_sets")
            .delete()
            .eq("workout_id", value: workoutId)
            .execute()
        try await createSetsForWorkout(workoutId: workoutId, from: parsed)
    }
}