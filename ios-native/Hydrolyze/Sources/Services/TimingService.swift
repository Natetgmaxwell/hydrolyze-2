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
                confidence: 100
            )
        }
        try await supabase.from("recorded_times")
            .insert(rows)
            .execute()
    }

    /// Save paired laps from the ML pairing engine for a multi-swimmer session
    func savePairedLaps(
        sessionId: String,
        stroke: String,
        distance: Int,
        intensity: String,
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
            let created_at: String
            let confidence: Int
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
                created_at: timestamp,
                confidence: assignment.confidence,
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