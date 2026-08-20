import Foundation

/// RecordedTime — mirrors recorded_times table in Postgres.
/// Each row = one swimmer's time for one rep of one set.
struct RecordedTime: Codable, Identifiable, Sendable, Hashable {
    let id: String
    let sessionId: String?
    let swimmerId: String?
    let workoutSetId: String?
    let workoutId: String?
    let timeMs: Int
    let repIndex: Int
    let intensity: String
    let gear: String?
    let waveNumber: Int?
    let paceDistance: Int?
    var createdAt: String
    var lapOrder: Int?
    var pairedSwimmerId: String?
    var confidence: Int?
    /// PHASE 2.6 v1.17.0: DB has this column (text, default 'auto').
    /// 'auto' = engine-paired, 'coachConfirmed' = coach accepted
    /// despite low confidence. The iOS code now decodes it; future
    /// v1.17 work can use it to distinguish engine pairings from
    /// coach overrides (e.g., for analytics, calibration).
    let source: String?
    /// PHASE 2.6 v1.17.0: DB has this column (double precision, the
    /// raw probability 0.0-1.0 that the pairing is correct). The
    /// `confidence` (smallint 0-100) is the integer percentage.
    /// The engine should use assignmentConfidence when present
    /// for finer precision; the v1.16 engine uses confidence
    /// everywhere. Future v1.17 work will switch the cost
    /// function over.
    let assignmentConfidence: Double?
    /// PHASE 2.6 v1.17.0: DB has this column (text, denormalized
    /// from workout_sets.stroke for query convenience). Lets the
    /// review UI show "50m Free" without joining workout_sets on
    /// every render. The v1.14 review UI joins workout_sets for
    /// distance; with stroke on recorded_times, the join
    /// becomes optional.
    let stroke: String?
    /// PHASE 2.5: read-only joined workout title for grouping the
    /// My Swims list by session. Embedded as a nested object so the
    /// Supabase foreign-table select stays standard (`workout:workouts!workout_id(title)`).
    /// Falls back to nil when the row has no linked workout or the workout
    /// is untitled.
    let workout: WorkoutRef?

    /// t_be09a643 (2026-08-05): fragment metadata columns added by
    /// migration `extend_recorded_times_with_fragment_metadata`. Each
    /// row written by the per-fragment CTA flow carries the fragment
    /// context so the pairing engine can evaluate the tap against the
    /// right (swimmer, distance, intensity, start) prediction rather
    /// than the parent workout_set's generic PB.
    ///
    /// All four fields are nullable for backward compatibility with
    /// legacy rows that pre-date per-fragment timing — the decoder
    /// tolerates missing keys via `decodeIfPresent`.
    let fragmentId: String?
    let distanceMeters: Int?
    let fragmentStartType: String?
    let paceTargetSec: Int?
    let rawText: String?

    /// Convenience accessor used by the view model.
    var workoutTitle: String? { workout?.title }

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case swimmerId = "swimmer_id"
        case workoutSetId = "workout_set_id"
        case workoutId = "workout_id"
        case timeMs = "time_ms"
        case repIndex = "rep_index"
        case intensity
        case gear
        case waveNumber = "wave_number"
        case paceDistance = "pace_distance"
        case createdAt = "created_at"
        case lapOrder = "lap_order"
        case pairedSwimmerId = "paired_swimmer_id"
        case confidence
        case source
        case assignmentConfidence = "assignment_confidence"
        case stroke
        case workout
        case fragmentId = "fragment_id"
        case distanceMeters = "distance_meters"
        case fragmentStartType = "start_type"
        case paceTargetSec = "pace_target_sec"
        case rawText = "raw_text"
    }
}

/// Lightweight read-only reference to the parent workout for a recorded time.
/// Keeps RecordedTime Codable when the select embeds `workouts`.
struct WorkoutRef: Codable, Sendable, Hashable {
    let title: String?
}