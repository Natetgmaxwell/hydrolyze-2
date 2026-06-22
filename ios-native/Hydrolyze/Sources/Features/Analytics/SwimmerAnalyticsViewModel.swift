import Foundation

/// SwimmerAnalyticsSummary — the per-swimmer projection rendered in
/// the SwimmerAnalyticsView. Carries the headline numbers (best PB,
/// last time, mean, stddev) + derived metrics (CV, trend, squad
/// percentile) that the view binds to.
///
/// CV = σ / μ (per the v1 §2.1 of the coach-analytics brainstorm).
/// Squad percentile: the swimmer's best PB vs the squad's best PBs
/// at the same (stroke, distance) — "Alice is at the 70th percentile
/// for 50 free" (per the v1 §3.3 of the brainstorm).
struct SwimmerAnalyticsSummary {
    let swimmerId: String
    let bestTimeMs: Int?
    let lastTimeMs: Int?
    let meanMs: Int?        // mean of the trend window
    let stddevMs: Int?      // stddev of the trend window
    let cvPct: Double?      // σ / μ * 100, nil if no data
    let trend: Trend
    let squadPercentile: Double?  // 0.0 - 1.0, where the swimmer ranks

    enum Trend {
        case improving
        case regressing
        case flat
        case insufficientData
    }
}

/// SwimmerAnalyticsViewModel — drives the per-swimmer analytics view.
/// Loads the swimmer, their PBs, their full recorded times for the
/// trend window (6 weeks default), and (for percentile) the squad's
/// best PBs at the same (stroke, distance) as the swimmer's best
/// PB. Composes the existing `SwimmerService` + `ChartDataService`
/// primitives — no new queries.
@MainActor
final class SwimmerAnalyticsViewModel: ObservableObject {
    @Published var swimmer: Swimmer?
    @Published var summary: SwimmerAnalyticsSummary?
    @Published var progressionTimes: [RecordedTime] = []
    @Published var lastFive: [LastFiveEntry] = []
    @Published var isLoading: Bool = true
    @Published var errorMessage: String?

    let swimmerId: String
    private let swimmerService = SwimmerService()
    private let chartDataService = ChartDataService()

    /// PHASE 2 (Analytics): trend window is 6 weeks. The cohort
    /// trend view (v1 §3.2) and the per-swimmer trend view share
    /// the same window — one knob, not two.
    private let trendWindowDays: Int = 42

    init(swimmerId: String) {
        self.swimmerId = swimmerId
    }

    /// One entry in the "last 5 times" section. Carries enough
    /// context to render a useful label (the event + a short date
    /// string).
    struct LastFiveEntry: Identifiable {
        let id: String  // recorded_time.id
        let timeMs: Int
        let label: String
    }

    func load(coachId: String?) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        guard let coachId = coachId, !coachId.isEmpty else {
            errorMessage = "Coach not signed in"
            return
        }
        do {
            // Parallel: swimmer + PBs + history + squad-PBs
            async let swimmerTask = swimmerService.fetchSwimmer(swimmerId: swimmerId)
            async let pbsTask = swimmerService.fetchPersonalBests(swimmerId: swimmerId)
            let lookback = Date().addingTimeInterval(-365 * 86400)
            async let historyTask = chartDataService.fetchSpeedCurveData(
                swimmerId: swimmerId,
                since: lookback
            )
            let (swimmer, pbs, history) = try await (swimmerTask, pbsTask, historyTask)

            // Squad percentiles: fetch every swimmer's PB at the
            // swimmer's best event. This is one query but might
            // be a lot of data — we filter client-side. For 15
            // swimmers × ~3 events = ~45 PB rows, fine.
            async let squadPBsTask = fetchSquadPBs(coachId: coachId)
            let squadPBs = try await squadPBsTask

            self.swimmer = swimmer

            // Filter history to the trend window
            let inWindow = filterToTrendWindow(history: history)
            self.progressionTimes = inWindow

            // Best PB (across all events)
            let bestTimeMs = pbs.compactMap { $0.timeMs }.min()
            let lastTimeMs = inWindow.compactMap { $0.timeMs }.last

            // Mean / stddev of the trend window
            let timesInWindow = inWindow.compactMap { $0.timeMs }
            let meanMs = timesInWindow.isEmpty ? nil : Int(Double(timesInWindow.reduce(0, +)) / Double(timesInWindow.count))
            let stddevMs: Int? = {
                guard let mean = meanMs, timesInWindow.count >= 2 else { return nil }
                let variance = Double(timesInWindow.map { pow(Double($0) - Double(mean), 2) }.reduce(0, +)) / Double(timesInWindow.count - 1)
                return Int(sqrt(variance))
            }()
            let cvPct: Double? = {
                guard let mean = meanMs, mean > 0, let sd = stddevMs else { return nil }
                return Double(sd) / Double(mean) * 100.0
            }()

            // Squad percentile for the swimmer's best event
            let squadPercentile: Double? = {
                guard let best = bestTimeMs else { return nil }
                // Find the swimmer's best event (the (stroke, distance) of
                // the PB that matches bestTimeMs)
                guard let bestPB = pbs.first(where: { $0.timeMs == best }) else { return nil }
                let event = "\(bestPB.distance)|\(bestPB.stroke)"
                let squadAtEvent = squadPBs
                    .filter { "\($0.distance)|\($0.stroke)" == event }
                    .compactMap { $0.timeMs }
                guard !squadAtEvent.isEmpty else { return nil }
                // Percentile: fraction of squad times >= this swimmer's
                // (faster swimmers push the percentile UP, so the
                // convention is: 100th percentile = fastest)
                let faster = squadAtEvent.filter { $0 <= best }.count
                return Double(faster) / Double(squadAtEvent.count)
            }()

            // Trend (reuse the squad view's algorithm)
            let trend = computeTrend(from: inWindow)

            self.summary = SwimmerAnalyticsSummary(
                swimmerId: swimmerId,
                bestTimeMs: bestTimeMs,
                lastTimeMs: lastTimeMs,
                meanMs: meanMs,
                stddevMs: stddevMs,
                cvPct: cvPct,
                trend: trend,
                squadPercentile: squadPercentile
            )

            // Last 5: most recent 5 times, regardless of event,
            // with a useful label (event + relative date)
            self.lastFive = computeLastFive(from: history)
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    /// Filter the swimmer's history to the trend window. Times
    /// without a parseable createdAt fall through (kept) so we
    /// don't silently lose data on a parse error.
    private func filterToTrendWindow(history: [RecordedTime]) -> [RecordedTime] {
        let formatter = ISO8601DateFormatter()
        let cutoff = Date().addingTimeInterval(-Double(trendWindowDays) * 86400)
        return history.filter { rt in
            guard let date = formatter.date(from: rt.createdAt) else { return true }
            return date >= cutoff
        }
    }

    /// Trend: same algorithm as the squad view, scoped to a
    /// single swimmer. Returns .insufficientData if there are < 3
    /// times in the window.
    private func computeTrend(from recent: [RecordedTime]) -> SwimmerAnalyticsSummary.Trend {
        let times = recent.compactMap { $0.timeMs }.sorted()
        guard times.count >= 3 else { return .insufficientData }
        let mid = times.count / 2
        let olderHalf = times[0..<mid]
        let recentHalf = times[mid...]
        guard !olderHalf.isEmpty, !recentHalf.isEmpty else { return .insufficientData }
        let olderMean = Double(olderHalf.reduce(0, +)) / Double(olderHalf.count)
        let recentMean = Double(recentHalf.reduce(0, +)) / Double(recentHalf.count)
        guard olderMean > 0 else { return .insufficientData }
        let pctChange = ((recentMean - olderMean) / olderMean) * 100.0
        if pctChange < -1.0 { return .improving }
        if pctChange >  1.0 { return .regressing }
        return .flat
    }

    /// Last 5 times: most recent across all events, with a short
    /// label. The label format is "<distance> <stroke> · <N> days ago"
    /// — readable at a glance without being verbose.
    private func computeLastFive(from history: [RecordedTime]) -> [LastFiveEntry] {
        let formatter = ISO8601DateFormatter()
        let sortedDesc = history.sorted { ($0.createdAt) > ($1.createdAt) }
        let top5 = Array(sortedDesc.prefix(5))
        return top5.compactMap { rt in
            guard let timeMs = rt.timeMs, let date = formatter.date(from: rt.createdAt) else { return nil }
            let dist = rt.paceDistance.map { "\($0)m" } ?? "?"
            let stroke = rt.stroke ?? "?"
            let daysAgo = max(0, Int(Date().timeIntervalSince(date) / 86400))
            let relative = daysAgo == 0 ? "today" : daysAgo == 1 ? "1d ago" : "\(daysAgo)d ago"
            return LastFiveEntry(
                id: rt.id,
                timeMs: timeMs,
                label: "\(dist) \(stroke) · \(relative)"
            )
        }
    }

    /// Squad PBs at every (stroke, distance) — needed for the
    /// percentile computation. Fetches all swimmers' PBs (one
    /// query) and filters client-side to the swimmer's best event.
    private func fetchSquadPBs(coachId: String) async throws -> [SwimmerPB] {
        let swimmers = try await swimmerService.fetchSwimmers(coachId: coachId)
        // Fan-out: per-swimmer PBs in parallel
        return await withTaskGroup(of: [SwimmerPB].self) { group in
            for swimmer in swimmers {
                group.addTask { [self] in
                    return (try? await swimmerService.fetchPersonalBests(swimmerId: swimmer.id)) ?? []
                }
            }
            var collected: [SwimmerPB] = []
            for await pbs in group {
                collected.append(contentsOf: pbs)
            }
            return collected
        }
    }
}