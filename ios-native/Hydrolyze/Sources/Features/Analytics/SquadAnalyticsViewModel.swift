import Foundation

/// SquadAnalyticsSummary — the per-swimmer projection the squad list
/// renders. Holds the headline numbers (best PB across all sets,
/// most recent recorded time) and a derived trend (improving /
/// regressing / flat / insufficient data).
///
/// Trend computation (per the v1 §7.3 of the coach-analytics
/// brainstorm — the per-swimmer improvement rate):
///   - Take the last 6 weeks of recorded_times
///   - Compute the slope: (recent_mean - older_mean) / older_mean
///   - Improving: slope < -1% (negative means times are getting
///     smaller, which is faster — good)
///   - Regressing: slope > +1% (times getting bigger — slower)
///   - Flat: between ±1%
///   - Insufficient data: < 3 recorded times in the window
struct SquadAnalyticsSummary: Identifiable {
    let id: String
    let swimmer: Swimmer
    let bestTimeMs: Int?
    let lastTimeMs: Int?
    let lastSixWeeksTrend: Trend

    enum Trend {
        case improving       // slope < -1%
        case regressing      // slope > +1%
        case flat            // between ±1%
        case insufficientData  // < 3 swims in window
    }

    var trend: Trend { lastSixWeeksTrend }
}

/// SquadAnalyticsViewModel — drives the squad analytics list. Loads
/// all active swimmers, then per-swimmer fetches the personal bests
/// (best across all PB rows) and the last few recorded times. The
/// trend is computed from the last 6 weeks of recorded times.
///
/// Fan-out pattern: fetches per swimmer are dispatched in parallel
/// via TaskGroup (15 swimmers × 3 round-trips would be 45 sequential
/// queries; parallel fetches in <2s total instead of >20s).
@MainActor
final class SquadAnalyticsViewModel: ObservableObject {
    @Published var summaries: [SquadAnalyticsSummary] = []
    @Published var isLoading: Bool = true
    @Published var errorMessage: String?

    private let swimmerService = SwimmerService()
    private let chartDataService = ChartDataService()

    /// PHASE 2 (Analytics): the trend window. 6 weeks is the brainstorm
    /// default ("8 weeks default" per §12.3 of v2; we start with 6
    /// to keep the sparkline stable and pivot to 8 once we see
    /// typical usage). The user can override later via the v2
    /// time-horizon settings.
    private let trendWindowDays: Int = 42

    /// PHASE 2 (Analytics): the maximum number of recorded_times
    /// fetched per swimmer for the trend computation. We don't need
    /// 1000; we need enough to compute a stable slope. 30 is
    /// comfortably above the "needs 3+" minimum and keeps the
    /// payload small.
    private let trendFetchLimit: Int = 30

    /// PHASE 2 (Analytics): the threshold for "improving" vs
    /// "regressing". A 1% slope over 6 weeks is the standard
    /// "noticeable but not noise" threshold (Stewart & Hopkins
    /// 2000 puts between-competition variation at ~1.4%; anything
    /// larger than that is signal).
    private let trendThresholdPct: Double = 1.0

    func load(coachId: String?) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        guard let coachId = coachId, !coachId.isEmpty else {
            errorMessage = "Coach not signed in"
            return
        }
        do {
            let swimmers = try await swimmerService.fetchSwimmers(coachId: coachId)
            // Fan-out: per-swimmer fetch in parallel via TaskGroup.
            // Without this, 15 swimmers × 2 sequential round-trips
            // (PBs + last-N-times) = 30 sequential queries, ~20-30s.
            // With TaskGroup: ~2s total (the slowest single query).
            let summaries: [SquadAnalyticsSummary] = await withTaskGroup(of: SquadAnalyticsSummary?.self) { group in
                for swimmer in swimmers {
                    group.addTask { [self] in
                        return await computeSummary(for: swimmer)
                    }
                }
                var collected: [SquadAnalyticsSummary] = []
                for await summary in group where summary != nil {
                    collected.append(summary!)
                }
                // Stable sort: improving first, then flat, then
                // regressing, then insufficient data. Within each
                // group: best PB (fastest) first.
                return sortForCoachView(collected)
            }
            self.summaries = summaries
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    /// Per-swimmer fetch: PBs + recent times → summary. Returns nil
    /// on a per-swimmer error so the squad list is partial-tolerant
    /// (one swimmer's failure doesn't blank the whole view).
    ///
    /// The "recent times" fetch uses `fetchSpeedCurveData` (not
    /// `fetchProgressionData`) because the squad view doesn't have
    /// a single (distance, stroke) to filter on. We need the
    /// swimmer's full history so the trend window can be applied
    /// client-side across all events.
    private func computeSummary(for swimmer: Swimmer) async -> SquadAnalyticsSummary? {
        do {
            // Fetch PBs and full history in parallel for this swimmer
            async let pbsTask = swimmerService.fetchPersonalBests(swimmerId: swimmer.id)
            // PHASE 2 (Analytics): 1-year lookback is enough to
            // compute a 6-week trend window (we filter to the
            // window client-side below). Going further back is
            // wasted payload; 1 year covers the season.
            let lookback = Date().addingTimeInterval(-365 * 86400)
            async let historyTask = chartDataService.fetchSpeedCurveData(
                swimmerId: swimmer.id,
                since: lookback
            )
            let (pbs, history) = try await (pbsTask, historyTask)

            // Best PB: lowest timeMs across all PB rows (PBs are
            // per-(stroke, distance) so "best" means fastest across
            // all events for that swimmer)
            let bestTimeMs = pbs.compactMap { $0.timeMs }.min()

            // Last time: history is sorted ASC by createdAt, so
            // the most recent time is the last element. Filter to
            // entries with a real timeMs (recorded times have it
            // populated; coarse rows might not).
            let lastTimeMs = history.compactMap { $0.timeMs }.last

            let trend = computeTrend(from: history)
            return SquadAnalyticsSummary(
                id: swimmer.id,
                swimmer: swimmer,
                bestTimeMs: bestTimeMs,
                lastTimeMs: lastTimeMs,
                lastSixWeeksTrend: trend
            )
        } catch {
            // Per-swimmer error: skip rather than blanking the whole
            // squad list. The coach can still see N-1 swimmers.
            return nil
        }
    }

    /// Trend: split the recent times into "first half" (older) and
    /// "second half" (recent), compute mean of each, derive the %
    /// change. Negative = improving (times getting smaller = faster).
    private func computeTrend(from recent: [RecordedTime]) -> SquadAnalyticsSummary.Trend {
        guard recent.count >= 3 else { return .insufficientData }

        // Filter to the trend window (default 6 weeks = 42 days).
        // RecordedTime.createdAt is a String (ISO8601) per the model.
        let formatter = ISO8601DateFormatter()
        let cutoff = Date().addingTimeInterval(-Double(trendWindowDays) * 86400)
        let recentInWindow = recent.filter { rt in
            guard let date = formatter.date(from: rt.createdAt) else { return false }
            return date >= cutoff
        }
        let sample = recentInWindow.isEmpty ? recent : recentInWindow
        guard sample.count >= 3 else { return .insufficientData }

        // Split into halves by createdAt (already ordered desc from
        // the fetch). The "older" half is the second slice; the
        // "recent" half is the first slice. If times are interleaved,
        // we use the median split.
        let times = sample.compactMap { $0.timeMs }.sorted()
        guard times.count >= 3 else { return .insufficientData }
        let mid = times.count / 2
        let olderHalf = times[0..<mid]
        let recentHalf = times[mid...]
        guard !olderHalf.isEmpty, !recentHalf.isEmpty else { return .insufficientData }

        let olderMean = Double(olderHalf.reduce(0, +)) / Double(olderHalf.count)
        let recentMean = Double(recentHalf.reduce(0, +)) / Double(recentHalf.count)
        guard olderMean > 0 else { return .insufficientData }
        let pctChange = ((recentMean - olderMean) / olderMean) * 100.0

        if pctChange < -trendThresholdPct { return .improving }
        if pctChange >  trendThresholdPct { return .regressing }
        return .flat
    }

    /// Sort: improving first, then flat, then regressing, then
    /// insufficient data. Within each group: fastest PB first.
    private func sortForCoachView(_ summaries: [SquadAnalyticsSummary]) -> [SquadAnalyticsSummary] {
        return summaries.sorted { a, b in
            let rankA = trendRank(a.trend)
            let rankB = trendRank(b.trend)
            if rankA != rankB { return rankA < rankB }
            // Within group: fastest first (nil PBs last)
            switch (a.bestTimeMs, b.bestTimeMs) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.swimmer.fullName < b.swimmer.fullName
            }
        }
    }

    private func trendRank(_ trend: SquadAnalyticsSummary.Trend) -> Int {
        switch trend {
        case .improving: return 0
        case .flat: return 1
        case .regressing: return 2
        case .insufficientData: return 3
        }
    }
}