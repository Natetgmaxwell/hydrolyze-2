import Foundation
import Supabase

/// CalibrationFactors — reads the per-(swimmer, X, distance, stroke)
/// calibration stats and returns the pair-wise ratio to apply as a
/// multiplier in the prediction engine.
///
/// Shape (verified against the live schema 2026-06-20):
/// For each (swimmer, distance, stroke, X) bucket, the table stores
/// `mean_time_ms`, `stddev_time_ms`, `m2` (Welford accumulator, added
/// in T1.5), and `sample_count`. The pair-wise ratio is computed
/// from the means:
///
///   suit_mult            = mean(suit=true)              / mean(suit=false)
///   start_mult(in_water) = 1.0   (the reference; no adjustment)
///   start_mult(dive)     = mean(start_type=dive)       / mean(in_water)
///   start_mult(backstroke_start)
///                       = mean(start_type=backstroke_start) / mean(in_water)
///
/// If a required group is missing (table has < 2 rows for the same
/// (swimmer, distance, stroke) under the required X values), the
/// helper returns `nil` and the engine falls back to a multiplier
/// of 1.0 (no adjustment). The convention is: a value < 1.0 means
/// the X is faster (e.g. a suit saves time); a value > 1.0 means
/// the X is slower. The same multiplier works in both directions —
/// the engine multiplies the predicted time by the multiplier
/// regardless of whether the source is a suited time being
/// converted to a no-suit time, or vice versa.
///
/// T2 (PHASE 1, v3, 2026-06-20): read-only. The save path (T6) will
/// update these tables on every `recorded_times` insert via the
/// Welford formula, using the `m2` column added in T1.5.
///
/// Usage:
///   let cal = CalibrationFactors()
///   try await cal.prefetch(forSwimmerIds: ["uuid-1", "uuid-2"])
///   let mult = cal.suitMultiplier(swimmerId: "uuid-1", distance: 50, stroke: "Free")
///   if let mult { predicted *= mult }
///
/// The pre-fetch pattern matches the existing `HistoricalTimePredictor`
/// (which takes pre-fetched `recordedTimes` and `pbs` arrays as
/// parameters). The caller does the async fetch once per session,
/// the sync methods are called per-set.
final class CalibrationFactors {
    private let supabase = SupabaseService.shared.client

    /// Per-(swimmer, X, distance, stroke) calibration stat from
    /// `swimmer_suits` or `swimmer_starts`. Either `suit` or
    /// `startType` is populated depending on which table the row
    /// came from. The other is `nil` (the column is not in the
    /// other table).
    struct CalibrationRow: Codable, Sendable, Equatable {
        let swimmerId: String
        let distance: Int
        let stroke: String
        let meanTimeMs: Double?
        let sampleCount: Int
        let suit: Bool?
        let startType: String?

        enum CodingKeys: String, CodingKey {
            case swimmerId = "swimmer_id"
            case distance
            case stroke
            case meanTimeMs = "mean_time_ms"
            case sampleCount = "sample_count"
            case suit
            case startType = "start_type"
        }
    }

    /// Cache keyed by swimmerId; holds all calibration rows for
    /// that swimmer (across suit/start, all distances, all strokes).
    /// Populated by `prefetch(forSwimmerIds:)`; queried by the sync
    /// multiplier methods.
    private var cache: [String: [CalibrationRow]] = [:]

    /// Fetch all calibration rows for the given swimmers from both
    /// `swimmer_suits` and `swimmer_starts` in parallel. Populates
    /// the cache. Call once before invoking the sync multiplier
    /// methods.
    func prefetch(forSwimmerIds swimmerIds: [String]) async throws {
        guard !swimmerIds.isEmpty else { return }
        async let suits = fetchSuits(forSwimmerIds: swimmerIds)
        async let starts = fetchStarts(forSwimmerIds: swimmerIds)
        let (suitRows, startRows) = try await (suits, starts)
        for row in suitRows {
            cache[row.swimmerId, default: []].append(row)
        }
        for row in startRows {
            cache[row.swimmerId, default: []].append(row)
        }
    }

    private func fetchSuits(forSwimmerIds swimmerIds: [String]) async throws -> [CalibrationRow] {
        let response = try await supabase.from("swimmer_suits")
            .select("swimmer_id, distance, stroke, mean_time_ms, sample_count, suit")
            .in("swimmer_id", values: swimmerIds)
            .execute()
        return try JSONDecoder().decode([CalibrationRow].self, from: response.data)
    }

    private func fetchStarts(forSwimmerIds swimmerIds: [String]) async throws -> [CalibrationRow] {
        let response = try await supabase.from("swimmer_starts")
            .select("swimmer_id, distance, stroke, mean_time_ms, sample_count, start_type")
            .in("swimmer_id", values: swimmerIds)
            .execute()
        return try JSONDecoder().decode([CalibrationRow].self, from: response.data)
    }
    /// The suit multiplier to apply for a set at (swimmer, distance,
    /// stroke) with the given `setSuit` value. Returns
    /// `mean(suit=true) / mean(suit=false)` when `setSuit = true`, or
    /// `mean(suit=false) / mean(suit=true)` when `setSuit = false`
    /// — i.e. the helper picks the right direction so the engine can
    /// just multiply the predicted time by the result.
    ///
    /// Returns `nil` if:
    ///   - the cache has no rows for this swimmer, or
    ///   - the cache has < 2 suit rows for this (distance, stroke), or
    ///   - either row's `mean_time_ms` is null, or
    ///   - the reference mean is zero (would divide by zero).
    ///
    /// The convention: a value < 1.0 means the requested suit is
    /// FASTER (the typical case for sprint). A value > 1.0 means
    /// the requested suit is SLOWER (unusual). The engine multiplies
    /// the predicted time by the multiplier regardless of the
    /// direction (no-suit-to-suit or suit-to-no-suit, the math is
    /// the same).
    func suitMultiplier(swimmerId: String, distance: Int, stroke: String, setSuit: Bool) -> Double? {
        guard let rows = cache[swimmerId] else { return nil }
        var suitTrue: CalibrationRow?
        var suitFalse: CalibrationRow?
        for row in rows where row.suit != nil && row.distance == distance && row.stroke == stroke {
            if row.suit == true && suitTrue == nil {
                suitTrue = row
            } else if row.suit == false && suitFalse == nil {
                suitFalse = row
            }
            if suitTrue != nil && suitFalse != nil { break }
        }
        guard let trueRow = suitTrue,
              let falseRow = suitFalse,
              let meanTrue = trueRow.meanTimeMs,
              let meanFalse = falseRow.meanTimeMs,
              meanTrue > 0, meanFalse > 0
        else { return nil }
        return setSuit ? (meanTrue / meanFalse) : (meanFalse / meanTrue)
    }

    /// The start multiplier to apply for a set at (swimmer, distance,
    /// stroke) with the given `startType`. Returns `mean(startType) /
    /// mean(in_water)` for the matching rows in the cache. For
    /// `startType = "in_water"`, returns 1.0 (the reference, no
    /// adjustment). Returns `nil` if:
    ///   - the cache has no rows for this swimmer, or
    ///   - no row exists for the requested `startType` at this
    ///     (distance, stroke), or
    ///   - the row's `mean_time_ms` is null, or
    ///   - `startType != "in_water"` and the in_water row is missing
    ///     or has a zero mean.
    ///
    /// The convention: a value < 1.0 means the startType is FASTER
    /// than in_water (e.g. a dive saves time on a 50). A value >
    /// 1.0 means the startType is SLOWER.
    func startMultiplier(swimmerId: String, distance: Int, stroke: String, startType: String) -> Double? {
        guard let rows = cache[swimmerId] else { return nil }
        // in_water is the reference; return 1.0 if a row exists for it.
        if startType == "in_water" {
            for row in rows where row.startType == "in_water" && row.distance == distance && row.stroke == stroke {
                if row.meanTimeMs != nil { return 1.0 }
            }
            return nil
        }
        var targetRow: CalibrationRow?
        var inWaterRow: CalibrationRow?
        for row in rows where row.startType != nil && row.distance == distance && row.stroke == stroke {
            if row.startType == startType && targetRow == nil {
                targetRow = row
            } else if row.startType == "in_water" && inWaterRow == nil {
                inWaterRow = row
            }
            if targetRow != nil && inWaterRow != nil { break }
        }
        guard let target = targetRow,
              let meanTarget = target.meanTimeMs,
              let inWater = inWaterRow,
              let meanInWater = inWater.meanTimeMs,
              meanInWater > 0
        else { return nil }
        return meanTarget / meanInWater
    }

    /// Clear the cache (for tests or memory pressure).
    func clearCache() {
        cache.removeAll()
    }

    /// Test-only: seed the cache directly with pre-built rows.
    /// Production code uses `prefetch(forSwimmerIds:)` to populate via
    /// Supabase. The CLI test harness uses this to bypass the
    /// Supabase round-trip and exercise the sync multiplier methods
    /// with deterministic mock data.
    ///
    /// Per the v3 plan T5: "Tests are deterministic (seeded mock
    /// data)." This is the seed mechanism.
    func seedForTesting(rowsBySwimmerId: [String: [CalibrationRow]]) {
        cache = rowsBySwimmerId
    }
}
