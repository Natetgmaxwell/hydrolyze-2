import Foundation
import Supabase

/// TimingService — persists timing sessions to recorded_times.
/// One row per lap, linked to swimmer_id.
final class TimingService {
    private let supabase = SupabaseService.shared.client

    func saveSession(_ session: TimingSession) async throws {
        struct LapRow: Encodable {
            let id: String
            let session_id: String?
            let swimmer_id: String
            let time_ms: Int
            let rep_index: Int
            let created_at: String
            let intensity: String
            let stroke: String
            let pace_distance: Int?
            let workout_set_id: String?
            let confidence: Int?
            /// V0.46 fix (2026-08-20): owning coach's coaches.id. Required
            /// by the coach_own_recorded_times RLS policy (migration
            /// 20260806180000). nil → NULL → RLS WITH CHECK violation.
            let coach_id: String?
            /// PHASE 2.6 v1.17.0 (S5): write the engine's raw
            /// pairing probability alongside the bucketed
            /// confidence. The single-swimmer path hardcodes
            /// confidence: 100 (a single swimmer with no
            /// Hungarian ambiguity is, by definition, a 100%
            /// confident pairing), so the matching Gaussian is
            /// exp(0) = 1.0. Future work could derive this from
            /// the actual lap vs PB z-score, but for v1.17.0
            /// the single-swimmer path stays a clean 1.0.
            let assignment_confidence: Double?
        }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let rows = session.laps.map { lap in
            LapRow(
                id: UUID().uuidString,
                session_id: nil, // single swimmer has no session_id right now
                swimmer_id: session.swimmerId,
                time_ms: lap.elapsedMs,
                rep_index: lap.lapNumber - 1,
                created_at: timestamp,
                intensity: session.intensityLabel ?? "race",
                stroke: session.stroke,
            pace_distance: session.distance,
            workout_set_id: session.workoutSetId,
            confidence: 100,
            coach_id: session.coachId,
            assignment_confidence: 1.0
        )
        }
        try await supabase.from("recorded_times")
            .insert(rows)
            .execute()
    }

    /// V0.39 Slice 4 (2026-08-18): persist the drop-rule event
    /// trail as `set_rest_events` rows. One row per extension
    /// decision — strike rows with `reverted = false`, revert
    /// rows with `reverted = true`. The recovery flywheel
    /// (V0.40+) reads this table to learn per-swimmer
    /// recovery-signature patterns.
    ///
    /// `sessionId` and `workoutSetId` are passed through from
    /// the VM; both are optional to match the existing
    /// `recorded_times` single-swimmer path (which currently
    /// writes `session_id: nil`). The single-swimmer flow
    /// passes `sessionId: nil` so the row's session_id key
    /// is omitted from the wire JSON (consistent with the
    /// `LapRow` pattern in `saveSession`); the migration's
    /// `session_id` column default is consulted. For the
    /// multi-swimmer path (a future slice), both ids are
    /// supplied.
    ///
    /// The service owns the row construction + `created_at`
    /// stamping (mirrors the `LapRow` pattern in
    /// `saveSession` above) so the VM just hands over the
    /// in-memory event trail.
    ///
    /// No-op when `events` is empty — the VM already gates
    /// the call on `!restEvents.isEmpty`, but the early
    /// return is cheap insurance against a retry double-write.
    func saveRestEvents(
        _ events: [RestEvent],
        sessionId: String?,
        workoutSetId: String?
    ) async throws {
        guard !events.isEmpty else { return }
        // V0.39 Slice 4 (2026-08-18): stamp every row in this
        // batch with the same created_at. The supabase-swift
        // SDK forwards the JSON body verbatim to PostgREST, so
        // each row carries its own `created_at` string —
        // coalescing here (vs letting each row get `now()`)
        // means the batch reads as a single set completion in
        // the DB.
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let rows = events.map { event in
            RestEventRow(
                event: event,
                sessionId: sessionId,
                workoutSetId: workoutSetId,
                createdAt: timestamp
            )
        }
        try await supabase.from("set_rest_events")
            .insert(rows)
            .execute()
    }

    /// Save paired laps from the ML pairing engine for a multi-swimmer session
    ///
    /// V0.43a (2026-08-18): gain `gear: String?` so the fragment
    /// gear parsed by V0.37 (or the set-level gear when no
    /// fragment) is persisted to `recorded_times.gear`. The prior
    /// save path dropped it (the VM hardcoded "none") so all 432
    /// live rows read 'none' — this + the VM resolution closes the
    /// gap. nil means "no gear for this set"; the DB column is
    /// nullable with no non-null default, so an absent JSON key
    /// stores NULL.
    func savePairedLaps(
        sessionId: String,
        stroke: String,
        distance: Int,
        intensity: String,
        gear: String?,
        coachId: String?,
        assignments: [LapAssignment]
    ) async throws {
        struct PairedLapRow: Encodable {
            let id: String
            let session_id: String
            let swimmer_id: String?      // Optional if we use paired_swimmer_id for tentative
            let paired_swimmer_id: String // Tentative assignment from ML
            let workout_set_id: String?
            let time_ms: Int
            let rep_index: Int
            let intensity: String
            let stroke: String
            let pace_distance: Int?
            /// V0.46 fix (2026-08-20): owning coach's coaches.id. Required
            /// by the coach_own_recorded_times RLS policy.
            let coach_id: String?
            /// V0.43a (2026-08-18): the fragment or set gear
            /// (single text — `WorkoutSet.gear` is `[String]?` but
            /// `recorded_times.gear` is a single text column).
            /// nil for bare sets; the JSON encodes it as a
            /// missing key so the DB stores NULL.
            let gear: String?
            let created_at: String
            let confidence: Int
            /// PHASE 2.6 v1.17.0 (S5): the engine's Gaussian
            /// pairing probability (exp(-z²/2) where z is the
            /// velocity-space z-score). The S4 cost function
            /// emits this on every LapAssignment; we forward it
            /// to the DB so the iOS review flow can read it
            /// back. The DB column recorded_times.assignment_confidence
            /// was already in the schema (double precision,
            /// nullable); v1.17's RecordedTime model decodes it.
            let assignment_confidence: Double
            let lap_order: Int
            let wave_number: Int
        }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let rows = assignments.map { assignment in
            PairedLapRow(
                id: UUID().uuidString,
                session_id: sessionId,
                swimmer_id: nil, // Leave swimmer_id null until confirmed
                paired_swimmer_id: assignment.swimmerId.uuidString,
                workout_set_id: assignment.workoutSetId,
                time_ms: assignment.lap.elapsedMs,
                rep_index: assignment.lap.lapNumber - 1,
                intensity: intensity,
                stroke: stroke,
                pace_distance: distance,
                coach_id: coachId,
                gear: gear,
                created_at: timestamp,
                confidence: assignment.confidence,
                assignment_confidence: assignment.assignmentConfidence,
                lap_order: assignment.lap.lapNumber,
                wave_number: assignment.waveNumber
            )
        }

        guard !rows.isEmpty else { return }
        try await supabase.from("recorded_times")
            .insert(rows)
            .execute()
    }
}