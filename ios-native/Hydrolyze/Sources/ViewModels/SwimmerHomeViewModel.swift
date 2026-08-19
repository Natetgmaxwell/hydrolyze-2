import Foundation

/// PHASE 2.5: SwimmerHomeViewModel — the data layer for the
/// SwimmerHomeView. Loads the swimmer's recent times + PBs +
/// calibration context. Read-only for MVP.
///
/// Data sources:
/// - ChartDataService.fetchSpeedCurveData(swimmerId:since:) —
///   the swimmer's full history, no event filter
/// - SwimmerService.fetchPersonalBests(swimmerId:) — the PBs
///
/// The RLS policies (Phase 2.1) ensure the swimmer can only see
/// their own data. If the policy is bypassed somehow, the
/// fetch still returns just the swimmer's rows because the
/// WHERE clauses scope by swimmer_id.
@MainActor
final class SwimmerHomeViewModel: ObservableObject {
    @Published var recentSessions: [SessionEntry] = []
    @Published var pbs: [PBEntry] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    /// One recent recorded time. Carries enough context for the
    /// My Swims list to render an event label + relative date.
    struct TimeEntry: Identifiable {
        let id: String  // recorded_time.id
        let timeMs: Int
        let stroke: String
        let distance: Int
        let relativeDate: String
        let createdAt: Date
        let sessionKey: String
        let sessionDate: Date
        let workoutTitle: String?
    }

    /// One session/workout grouping for the My Swims list.
    struct SessionEntry: Identifiable {
        let id: String  // sessionKey
        let date: Date
        let title: String?
        let times: [TimeEntry]
    }

    /// One personal best.
    struct PBEntry: Identifiable {
        let id: String
        let stroke: String
        let distance: Int
        let timeMs: Int
        let intensity: String?
    }

    private let swimmerService = SwimmerService()
    private let chartDataService = ChartDataService()

    /// Lookback window for "recent times." 6 weeks matches the
    /// analytics trend window (the SwimmerAnalyticsViewModel uses
    /// the same value) so the views are consistent.
    private let recentWindowDays: Int = 42

    /// Fetch the swimmer's history + PBs. The coach's session
    /// auth isn't needed here — the iOS anon key (configured in
    /// SupabaseService) is enough because the swimmer_own_*
    /// RLS policies grant SELECT on the swimmer's own rows
    /// (auth.uid() = swimmers.auth_id).
    func load(swimmerId: String?) async {
        guard let swimmerId = swimmerId else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            async let timesTask = chartDataService.fetchSpeedCurveData(
                swimmerId: swimmerId,
                since: Date().addingTimeInterval(-Double(recentWindowDays) * 86400)
            )
            async let pbsTask = swimmerService.fetchPersonalBests(swimmerId: swimmerId)
            let (times, pbs) = try await (timesTask, pbsTask)

            let calendar = Calendar.current
            let entries: [TimeEntry] = times.compactMap { rt in
                // RecordedTime.timeMs is non-optional (recorded_times.time_ms is NOT NULL).
                // paceDistance + stroke are optional (only set on pace sets / pre-Phase 2.6 rows).
                let timeMs = rt.timeMs
                guard let stroke = rt.stroke,
                      let distance = rt.paceDistance else { return nil }
                let date = ISO8601DateParser.parse(rt.createdAt) ?? Date()
                // Group by session when available, otherwise by workout, otherwise by calendar day.
                // The session/workout id is enough to keep distinct practices separate; prefixing
                // with the date keeps the header stable and readable even when ids are nil.
                let dayStart = calendar.startOfDay(for: date)
                let keyParts = [
                    rt.sessionId,
                    rt.workoutId,
                    ISO8601DateFormatter().string(from: dayStart)
                ].compactMap { $0 }
                let sessionKey = keyParts.isEmpty ? rt.id : keyParts.joined(separator: "|")
                return TimeEntry(
                    id: rt.id,
                    timeMs: timeMs,
                    stroke: stroke,
                    distance: distance,
                    relativeDate: relativeDateString(from: date),
                    createdAt: date,
                    sessionKey: sessionKey,
                    sessionDate: dayStart,
                    workoutTitle: rt.workoutTitle
                )
            }
            // Most recent first; cap at the last 20 entries so
            // the My Swims list stays scannable
            let sortedEntries = entries
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(20)
                .map { $0 }

            // Group by session, preserving most-recent-first order.
            var sessionsByKey: [String: SessionEntry] = [:]
            for entry in sortedEntries {
                var existing = sessionsByKey[entry.sessionKey]
                let times = (existing?.times ?? []) + [entry]
                sessionsByKey[entry.sessionKey] = SessionEntry(
                    id: entry.sessionKey,
                    date: entry.sessionDate,
                    title: entry.workoutTitle,
                    times: times
                )
            }
            // Re-sort sessions by their newest time so the list is chronological top-down.
            self.recentSessions = sessionsByKey.values.sorted {
                let aMax = $0.times.map(\.createdAt).max() ?? $0.date
                let bMax = $1.times.map(\.createdAt).max() ?? $1.date
                return aMax > bMax
            }

            self.pbs = pbs.compactMap { pb in
                PBEntry(
                    id: pb.id,
                    stroke: pb.stroke,
                    distance: pb.distance,
                    timeMs: pb.timeMs,
                    intensity: pb.intensity
                )
            }
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    private func relativeDateString(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        let days = Int(interval / 86400)
        if days < 0 { return "in the future" }
        if days == 0 { return "today" }
        if days == 1 { return "yesterday" }
        if days < 7 { return "\(days)d ago" }
        if days < 30 { return "\(days / 7)w ago" }
        return "\(days / 30)mo ago"
    }

    #if DEBUG
    /// V0.46 Slice 5: screenshot-harness seed. Two sessions of 50m
    /// Free times plus four PBs — the My Swims / My PBs shape.
    /// Network is never touched.
    func seedV46DemoSwimmerData() {
        let cal = Calendar.current
        func entry(_ dayOffset: Int, _ hour: Int, _ ms: Int, rep: Int, sessionKey: String) -> TimeEntry {
            let base = cal.date(bySettingHour: hour, minute: 30, second: 0, of: Date()) ?? Date()
            let date = cal.date(byAdding: .day, value: dayOffset, to: base) ?? base
            return TimeEntry(
                id: "v46-te-\(sessionKey)-\(rep)",
                timeMs: ms,
                stroke: "Free",
                distance: 50,
                relativeDate: relativeDateString(from: date),
                createdAt: date,
                sessionKey: sessionKey,
                sessionDate: cal.startOfDay(for: date),
                workoutTitle: sessionKey == "v46-s1" ? "Threshold Tuesday" : "Sprint pyramid"
            )
        }
        let s1 = (1...4).map { entry(-2, 6, 31_400 + $0 * 260, rep: $0, sessionKey: "v46-s1") }
        let s2 = (1...4).map { entry(-6, 6, 30_980 + $0 * 310, rep: $0, sessionKey: "v46-s2") }
        recentSessions = [
            SessionEntry(id: "v46-s1", date: s1[0].sessionDate, title: "Threshold Tuesday", times: s1),
            SessionEntry(id: "v46-s2", date: s2[0].sessionDate, title: "Sprint pyramid", times: s2),
        ]
        pbs = [
            PBEntry(id: "v46-pb-1", stroke: "Free", distance: 50, timeMs: 29_870, intensity: nil),
            PBEntry(id: "v46-pb-2", stroke: "Free", distance: 100, timeMs: 65_210, intensity: nil),
            PBEntry(id: "v46-pb-3", stroke: "Back", distance: 50, timeMs: 33_540, intensity: nil),
            PBEntry(id: "v46-pb-4", stroke: "Fly", distance: 50, timeMs: 31_020, intensity: nil),
        ]
        isLoading = false
        errorMessage = nil
    }
    #endif
}
