import Foundation
import Supabase

/// AnalyticsService — Phase 4 coaching brain.
///
/// Aggregates recorded_times + workout_sets to answer:
///   1. Training band distribution — how much of the squad's work
///      is easy / moderate / threshold / sprint? (the "are we doing
///      too much junk mileage?" signal)
///   2. Gear/suit/dive breakdown — what fraction of reps use gear,
///      suits, or dive starts? (the "are we training race conditions?"
///      signal)
///   3. Per-swimmer improvement — who's getting faster, who's plateaued?
///
/// The metadata flywheel (parser → workout_sets → recorded_times)
/// makes these queries possible. Without gear/suit/dive on the set
/// rows, we can't ask "how much dive work did we do this week?"
final class AnalyticsService {
    private let client = SupabaseService.shared.client

    // MARK: - Types

    struct TrainingBandStats: Identifiable {
        let id = UUID()
        let band: String          // "Easy", "Moderate", "Threshold", "Sprint"
        let repCount: Int
        let distanceMeters: Int
        let color: String         // hex color for charting

        var fraction: Double {
            // Computed by caller after all bands are fetched
            0 // placeholder — set by aggregate
        }
    }

    struct GearBreakdown {
        let totalReps: Int
        let repsWithGear: Int
        let repsWithSuit: Int
        let repsWithDive: Int
        let topGear: [(gear: String, count: Int)]
    }

    struct SwimmerImprovement: Identifiable {
        let id = UUID()
        let swimmerId: String
        let swimmerName: String
        let improvementPct: Double   // negative = faster (improvement)
        let sampleCount: Int
    }

    // MARK: - Queries

    /// Training band distribution for the squad over a time window.
    /// Joins recorded_times → workout_sets to get intensity metadata.
    func fetchTrainingBands(coachId: String, since: Date) async throws -> [TrainingBandStats] {
        // Query recorded_times joined with workout_sets for intensity
        // The workout_sets.intensity column holds the parser-extracted label
        let response: [RecordedTimeRow] = try await client
            .from("recorded_times")
            .select("""
                id,
                swimmer_id,
                pace_distance,
                created_at,
                workout_set:workout_sets (
                    intensity,
                    gear,
                    dive,
                    suit
                )
            """)
            .eq("swimmer_id", value: "not.is.null")
            .gte("created_at", value: ISO8601DateFormatter().string(from: since))
            .execute()
            .value

        // Aggregate by intensity band
        var bandMap: [String: (reps: Int, distance: Int)] = [:]
        for row in response {
            let intensity = row.workoutSet?.intensity ?? "unknown"
            let band = mapIntensityToBand(intensity)
            let dist = row.paceDistance ?? 0
            let current = bandMap[band] ?? (0, 0)
            bandMap[band] = (current.reps + 1, current.distance + dist)
        }

        // Build results with colors
        let bandColors: [String: String] = [
            "Easy": "#4CAF50",       // green
            "Moderate": "#2196F3",   // blue
            "Threshold": "#FF9800",  // amber
            "Sprint": "#F44336",     // red
            "Unknown": "#9E9E9E",    // grey
        ]

        let totalReps = bandMap.values.reduce(0) { $0 + $1.reps }

        return bandMap.map { (band, counts) in
            TrainingBandStats(
                band: band,
                repCount: counts.reps,
                distanceMeters: counts.distance,
                color: bandColors[band] ?? "#9E9E9E"
            )
        }
        .sorted { bandOrder($0.band) < bandOrder($1.band) }
        .map { stats in
            // Can't mutate fraction in the struct (it's let), so return
            // as-is. The view computes fractions from the array.
            stats
        }
    }

    /// Gear/suit/dive breakdown for the squad.
    func fetchGearBreakdown(coachId: String, since: Date) async throws -> GearBreakdown {
        let response: [RecordedTimeRow] = try await client
            .from("recorded_times")
            .select("""
                id,
                workout_set:workout_sets (
                    gear,
                    dive,
                    suit
                )
            """)
            .gte("created_at", value: ISO8601DateFormatter().string(from: since))
            .execute()
            .value

        let total = response.count
        var gearCount = 0
        var suitCount = 0
        var diveCount = 0
        var gearTally: [String: Int] = [:]

        for row in response {
            if let gear = row.workoutSet?.gear, !gear.isEmpty {
                gearCount += 1
                for g in gear {
                    gearTally[g, default: 0] += 1
                }
            }
            if row.workoutSet?.suit == true { suitCount += 1 }
            if row.workoutSet?.dive == true { diveCount += 1 }
        }

        let topGear = gearTally
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { (gear: $0.key, count: $0.value) }

        return GearBreakdown(
            totalReps: total,
            repsWithGear: gearCount,
            repsWithSuit: suitCount,
            repsWithDive: diveCount,
            topGear: Array(topGear)
        )
    }

    // MARK: - Helpers

    private func mapIntensityToBand(_ intensity: String?) -> String {
        guard let i = intensity?.lowercased() else { return "Unknown" }
        switch i {
        case "sprint", "atp", "all-out", "max": return "Sprint"
        case "threshold", "t-pace", "css", "race pace", "hard": return "Threshold"
        case "aerobic", "moderate", "tempo", "steady", "cruise": return "Moderate"
        case "easy", "recovery", "warm-up", "drill": return "Easy"
        default: return "Unknown"
        }
    }

    private func bandOrder(_ band: String) -> Int {
        switch band {
        case "Sprint": return 0
        case "Threshold": return 1
        case "Moderate": return 2
        case "Easy": return 3
        default: return 4
        }
    }
}

// MARK: - DB Row Types (private)

private struct RecordedTimeRow: Codable {
    let id: String
    let swimmerId: String?
    let paceDistance: Int?
    let createdAt: String
    let workoutSet: WorkoutSetMeta?

    enum CodingKeys: String, CodingKey {
        case id
        case swimmerId = "swimmer_id"
        case paceDistance = "pace_distance"
        case createdAt = "created_at"
        case workoutSet = "workout_set"
    }
}

struct WorkoutSetMeta: Codable {
    let intensity: String?
    let gear: [String]?
    let dive: Bool?
    let suit: Bool?
}
