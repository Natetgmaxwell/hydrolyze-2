import Foundation
import Supabase

/// ChartDataService — aggregates recorded_times + personal_bests queries
/// into the shapes the chart components need. Thin wrapper around the
/// existing services — no query logic duplication.
final class ChartDataService {
    private let supabase = SupabaseService.shared.client
    private let workoutService = WorkoutService()
    private let swimmerService = SwimmerService()

    /// Fetch a swimmer's recorded times for a specific distance/stroke over a time window.
    /// Sorted by created_at ascending (oldest first) for chart rendering.
    func fetchProgressionData(
        swimmerId: String,
        distance: Int,
        stroke: String,
        since: Date
    ) async throws -> [RecordedTime] {
        let all = try await workoutService.fetchRecordedTimes(swimmerId: swimmerId, since: since)
        return all
            .filter { $0.paceDistance == distance }
            .sorted { ($0.createdAt) < ($1.createdAt) }
    }

    /// Fetch all recorded times for a specific workout set (a single session's reps).
    /// Sorted by rep_index ascending.
    func fetchTrendData(workoutSetId: String) async throws -> [RecordedTime] {
        return try await workoutService.fetchTimesForSet(workoutSetId: workoutSetId)
    }

    /// Fetch a swimmer's full recorded times for the speed curve (no distance filter).
    /// Sorted by created_at ascending.
    func fetchSpeedCurveData(swimmerId: String, since: Date) async throws -> [RecordedTime] {
        let all = try await workoutService.fetchRecordedTimes(swimmerId: swimmerId, since: since)
        return all.sorted { ($0.createdAt) < ($1.createdAt) }
    }
}
