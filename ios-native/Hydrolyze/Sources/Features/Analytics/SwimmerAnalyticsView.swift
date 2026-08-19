import SwiftUI

/// SwimmerAnalyticsView — coach-facing per-swimmer progress dashboard.
/// Distinct from `SwimmerDetailView` (which is the admin/profile page
/// with Edit/Archive/Delete buttons). This view is analytics-only:
/// the PB trajectory (using the existing `ProgressionChart`), a
/// training band (mean ± σ over the last N swims), the coefficient
/// of variation (consistency), the last 5 times sparkline, and the
/// swimmer's percentile within the squad for their best event.
///
/// Per the v1 §1.4 of the coach-analytics brainstorm:
///   "Per swimmer, plot their 50m free times as a tight band
///    (last 20 sessions at race intensity) with their PBs marked.
///    The tighter the band, the more *predictable* their race."
/// This view is the per-swimmer drilldown from the squad list.
///
/// Coach-only for v1 (matches the existing single-role app).
struct SwimmerAnalyticsView: View {
    let swimmerId: String
    @StateObject private var viewModel: SwimmerAnalyticsViewModel

    @Environment(AuthManager.self) private var authManager

    private var coachId: String? {
        authManager.coachId
    }

    init(swimmerId: String) {
        self.swimmerId = swimmerId
        _viewModel = StateObject(wrappedValue: SwimmerAnalyticsViewModel(swimmerId: swimmerId))
    }

    var body: some View {
        ZStack {
            Color.bgBase.ignoresSafeArea()

            if viewModel.isLoading && viewModel.swimmer == nil {
                ProgressView()
                    .tint(Color.accentAction)
            } else if let swimmer = viewModel.swimmer {
                ScrollView {
                    VStack(spacing: 16) {
                        SwimmerAnalyticsHeader(swimmer: swimmer, summary: viewModel.summary)
                        trainingBandSection
                        progressionSection
                        lastFiveSection
                        contextSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            } else if let error = viewModel.errorMessage {
                errorView(error)
            }
        }
        .navigationTitle(viewModel.swimmer?.fullName ?? "Swimmer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(Color.bgBase, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task {
            await viewModel.load(coachId: coachId)
        }
    }

    // MARK: - Sections

    private var trainingBandSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Training Band", subtitle: "Mean ± σ over the last 6 weeks")
            if let mean = viewModel.summary?.meanMs, let stddev = viewModel.summary?.stddevMs {
                TrainingBandView(mean: mean, stddev: stddev, personalBestMs: viewModel.summary?.bestTimeMs)
            } else {
                Text("Insufficient data — need at least 5 recorded times in the last 6 weeks.")
                    .font(.system(size: 12))
                    .foregroundColor(Color.textMuted)
            }
        }
        .padding(14)
        .background(Color.bgDeep)
        .cornerRadius(10)
    }

    private var progressionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // PHASE 2 (Analytics) v2.0.1: explicit event label
            // so the coach knows WHAT the progression is for.
            // Per user feedback: "the coach doesn't know what
            // the progression is for" — silently filtering to
            // the best event makes the chart correct but
            // unlabelled. The label "50m Free · last 6 weeks"
            // makes the context explicit at a glance.
            sectionHeader(
                "Progression",
                subtitle: progressionSubtitle
            )
            if !viewModel.progressionTimes.isEmpty {
                ProgressionChart(
                    times: viewModel.progressionTimes,
                    personalBestMs: viewModel.summary?.bestTimeMs
                )
                .frame(height: 180)
            } else {
                Text("No recorded times in the last 6 weeks.")
                    .font(.system(size: 12))
                    .foregroundColor(Color.textMuted)
            }
        }
        .padding(14)
        .background(Color.bgDeep)
        .cornerRadius(10)
    }

    /// "50m Free · last 6 weeks" — the subtitle line above the
    /// chart. Tells the coach what event the chart is showing
    /// (which the chart itself can't say because it's just a
    /// time series). When bestEvent is nil, falls back to a
    /// generic "Last 6 weeks" so the section never reads "all
    /// events last 6 weeks" (which was the original bug —
    /// the chart bundled 5 events into one timeline).
    private var progressionSubtitle: String {
        let window = "last 6 weeks"
        guard let bestEvent = viewModel.bestEvent else {
            return window
        }
        return "\(bestEvent.distance)m \(bestEvent.stroke) · \(window)"
    }

    private var lastFiveSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // PHASE 2 (Analytics) v2.0.1: also include the event
            // label here, mirroring the Progression subtitle.
            // "Last 5 Times · 50m Free" is consistent with
            // "Progression · 50m Free · last 6 weeks" — the
            // coach sees the same event filter applied to both
            // sections, never has to guess.
            sectionHeader(
                "Last 5 Times",
                subtitle: lastFiveSubtitle
            )
            if viewModel.lastFive.isEmpty {
                Text("No recent times.")
                    .font(.system(size: 12))
                    .foregroundColor(Color.textMuted)
            } else {
                VStack(spacing: 4) {
                    ForEach(viewModel.lastFive) { entry in
                        HStack {
                            Text(formatMs(entry.timeMs))
                                .font(.system(size: 14, weight: .medium, design: .monospaced))
                                .foregroundColor(Color.textPrimary)
                            Spacer()
                            Text(entry.label)
                                .font(.system(size: 11))
                                .foregroundColor(Color.textMuted)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .padding(14)
        .background(Color.bgDeep)
        .cornerRadius(10)
    }

    /// "Most recent 50m Free times" — subtitle for Last 5 Times.
    private var lastFiveSubtitle: String {
        guard let bestEvent = viewModel.bestEvent else {
            return "Most recent recorded times"
        }
        return "Most recent \(bestEvent.distance)m \(bestEvent.stroke) times"
    }

    private var contextSection: some View {
        HStack(spacing: 12) {
            metricTile(
                label: "CV",
                value: viewModel.summary.map { String(format: "%.1f%%", $0.cvPct ?? 0) } ?? "—",
                hint: "Coefficient of variation"
            )
            metricTile(
                label: "Squad %ile",
                value: viewModel.summary.flatMap { $0.squadPercentile.map { String(format: "%.0f%%", $0) } } ?? "—",
                hint: "Best time vs squad"
            )
            metricTile(
                label: "Swims",
                value: "\(viewModel.progressionTimes.count)",
                hint: "Last 6 weeks"
            )
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color.textPrimary)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundColor(Color.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metricTile(label: String, value: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundColor(Color.textMuted)
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(Color.accentAction)
            Text(hint)
                .font(.system(size: 9))
                .foregroundColor(Color.textFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.bgDeep)
        .cornerRadius(8)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundColor(Color.accentAmber)
            Text("Couldn't load swimmer analytics")
                .font(.headline)
                .foregroundColor(Color.textPrimary)
            Text(message)
                .font(.caption)
                .foregroundColor(Color.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private func formatMs(_ ms: Int) -> String {
        String(format: "%.2fs", Double(ms) / 1000.0)
    }
}

/// SwimmerAnalyticsHeader — the top section of the swimmer analytics
/// view. Shows initials, name, and the headline numbers (best PB,
/// last time, trend). Mirrors the visual hierarchy of the existing
/// `SwimmerDetailView.headerSection` but in analytics terms.
private struct SwimmerAnalyticsHeader: View {
    let swimmer: Swimmer
    let summary: SwimmerAnalyticsSummary?

    var body: some View {
        VStack(spacing: 12) {
            Circle()
                .fill(Color.bgInset)
                .frame(width: 56, height: 56)
                .overlay(
                    Text(initials)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(Color.accentAction)
                )
            Text(swimmer.fullName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(Color.textPrimary)
            HStack(spacing: 16) {
                statPair("Best", value: formatMs(summary?.bestTimeMs))
                statPair("Last", value: formatMs(summary?.lastTimeMs))
                statPair("Trend", value: trendLabel(summary?.trend))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private var initials: String {
        let first = swimmer.firstName.prefix(1)
        let last = (swimmer.lastName ?? "").prefix(1)
        if last.isEmpty { return String(swimmer.firstName.prefix(2)).uppercased() }
        return "\(first)\(last)".uppercased()
    }

    private func statPair(_ label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(Color.accentAction)
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundColor(Color.textMuted)
        }
    }

    private func trendLabel(_ trend: SwimmerAnalyticsSummary.Trend?) -> String {
        switch trend {
        case .improving: return "↑"
        case .regressing: return "↓"
        case .flat: return "—"
        case .insufficientData, .none: return "—"
        }
    }

    private func formatMs(_ ms: Int?) -> String {
        guard let ms = ms else { return "—" }
        return String(format: "%.2fs", Double(ms) / 1000.0)
    }
}

/// TrainingBandView — a horizontal range visualization. Shows the
/// swimmer's mean ± 1σ as a bar, with the PB marked as a vertical
/// line. Helps the coach answer "is the PB typical or a one-off?"
/// — per the v1 §1.4 of the coach-analytics brainstorm.
private struct TrainingBandView: View {
    let mean: Int
    let stddev: Int
    let personalBestMs: Int?

    private var minMs: Int { max(mean - stddev, 0) }
    private var maxMs: Int { mean + stddev }

    var body: some View {
        // Simple bar: the mean is the midpoint, ±1σ is the band
        VStack(spacing: 8) {
            HStack {
                Text(formatMs(minMs))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color.textMuted)
                Spacer()
                Text(formatMs(mean))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color.accentAction)
                Spacer()
                Text(formatMs(maxMs))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color.textMuted)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Bar
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.bgInset)
                        .frame(height: 16)
                    // ±1σ range
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accentAction.opacity(0.3))
                        .frame(width: geo.size.width, height: 16)
                    // PB marker (if it's within the visible range)
                    if let pb = personalBestMs, pb >= minMs, pb <= maxMs {
                        let xRatio = Double(pb - minMs) / Double(maxMs - minMs)
                        Rectangle()
                            .fill(Color.accentAmber)
                            .frame(width: 2, height: 24)
                            .offset(x: geo.size.width * CGFloat(xRatio) - 1, y: -4)
                    }
                }
            }
            .frame(height: 24)
            HStack {
                Label("±1σ", systemImage: "ruler")
                    .font(.system(size: 9))
                    .foregroundColor(Color.textFaint)
                Spacer()
                if personalBestMs != nil {
                    Label("PB", systemImage: "flag.fill")
                        .font(.system(size: 9))
                        .foregroundColor(Color.accentAmber)
                }
            }
        }
    }

    private func formatMs(_ ms: Int) -> String {
        String(format: "%.2fs", Double(ms) / 1000.0)
    }
}