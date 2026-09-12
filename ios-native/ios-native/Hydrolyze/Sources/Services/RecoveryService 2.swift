import Foundation
import Supabase

/// RecoveryService — V0.42 Slice 1 (2026-08-18) — Supabase fetch
/// layer for the recovery-signature flywheel. Reads the
/// `set_rest_events` table populated by V0.39 (drop-rule events,
/// schema migrations 20260818130000 + 20260818134000). Pure read;
/// the engine never writes here (V0.39 owns the writes in
/// `TimingService.saveRestEvents(...)`).
///
/// Mirrors `AnalyticsService` (the pattern: `private let client =
/// SupabaseService.shared.client`, private snake_case `Codable` DB
/// row structs, `.from("table").select(...)` + `.eq` / `.gte`
/// filters, decode via `JSONDecoder`).
///
/// The aggregator is `RecoveryAggregator` in `RecoverySignature.swift`
/// (pure Foundation — CLI-testable). This file is the thin async
/// boundary between the wire format and the aggregator.
final class RecoveryService {
    private let client = SupabaseService.shared.client

    // MARK: - Raw fetch

    /// V0.42 Slice 1 (2026-08-18): fetch every `set_rest_events`
    /// row for one swimmer since `since`. No pagination — the
    /// per-swimmer row count is bounded (cap is 2 strikes per set
    /// per V0.39; a swimmer with 8 weeks of daily anaerobic work
    /// tops out around 100 rows). The single fetch is fine.
    ///
    /// `since` is the lower bound on `created_at`; the caller
    /// (the VM) passes "8 weeks ago" so the fetch matches the
    /// `weeklyTrend` window. Supabase's `.gte("created_at", ...)`
    /// uses the column's `timestamptz` index.
    func fetchEvents(swimmerId: String, since: Date) async throws -> [RestEventRecord] {
        let sinceISO = ISO8601DateFormatter().string(from: since)
        let response = try await client
            .from("set_rest_events")
            .select("*")
            .eq("swimmer_id", value: swimmerId)
            .gte("created_at", value: sinceISO)
            .execute()
        return try JSONDecoder().decode([RestEventRecord].self, from: response.data)
    }

    // MARK: - Convenience: fetch + aggregate

    /// V0.42 Slice 1 (2026-08-18): fetch + aggregate into the
    /// per-swimmer `RecoverySignature`. Pure composition — see
    /// `RecoveryAggregator.signature(events:)` for the math.
    func fetchSignature(swimmerId: String, since: Date) async throws -> RecoverySignature {
        let events = try await fetchEvents(swimmerId: swimmerId, since: since)
        return RecoveryAggregator.signature(events: events)
    }

    /// V0.42 Slice 1 (2026-08-18): fetch + aggregate into the
    /// per-swimmer weekly trend. `weeks` is the look-back window
    /// length; the VM passes 8 (V0.42 spec §Decisions row 2).
    func fetchWeeklyTrend(
        swimmerId: String,
        since: Date,
        weeks: Int = 8
    ) async throws -> [WeeklyStrainPoint] {
        let events = try await fetchEvents(swimmerId: swimmerId, since: since)
        return RecoveryAggregator.weeklyTrend(events: events, weeks: weeks)
    }

    /// V0.42 Slice 3 (2026-08-18): fetch + aggregate into the
    /// revert rate. Mirrors `RecoveryAggregator.revertRate(...)` —
    /// the fetch layer's wrapper exists for symmetry with the other
    /// recovery methods so the VM has one service call per surface.
    func fetchRevertRate(swimmerId: String, since: Date) async throws -> Double {
        let events = try await fetchEvents(swimmerId: swimmerId, since: since)
        return RecoveryAggregator.revertRate(events: events)
    }
}