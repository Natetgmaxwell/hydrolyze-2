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
            Color(hex: "060e18").ignoresSafeArea()

            if viewModel.isLoading && viewModel.swimmer == nil {
                ProgressView()
                    .tint(Color(hex: "09d4ee"))
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
        .toolbarBackground(Color(hex: "060e18"), for: .navigationBar)
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
                    .foregroundColor(Color(hex: "7a9bb0"))
            }
        }
        .padding(14)
        .background(Color(hex: "0d1f33"))
        .cornerRadius(10)
    }

    private var progressionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Progression", subtitle: "PB trajectory over the last 6 weeks")
            if !viewModel.progressionTimes.isEmpty {
                ProgressionChart(
                    times: viewModel.progressionTimes,
                    personalBestMs: viewModel.summary?.bestTimeMs
                )
                .frame(height: 180)
            } else {
                Text("No recorded times in the last 6 weeks.")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "7a9bb0"))
            }
        }
        .padding(14)
        .background(Color(hex: "0d1f33"))
        .cornerRadius(10)
    }

    private var lastFiveSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Last 5 Times", subtitle: "Most recent recorded times across all events")
            if viewModel.lastFive.isEmpty {
                Text("No recent times.")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "7a9bb0"))
            } else {
                VStack(spacing: 4) {
                    ForEach(viewModel.lastFive) { entry in
                        HStack {
                            Text(formatMs(entry.timeMs))
                                .font(.system(size: 14, weight: .medium, design: .monospaced))
                                .foregroundColor(Color(hex: "e2f4fa"))
                            Spacer()
                            Text(entry.label)
                                .font(.system(size: 11))
                                .foregroundColor(Color(hex: "7a9bb0"))
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .padding(14)
        .background(Color(hex: "0d1f33"))
        .cornerRadius(10)
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
                .foregroundColor(Color(hex: "e2f4fa"))
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "7a9bb0"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metricTile(label: String, value: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundColor(Color(hex: "7a9bb0"))
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(Color(hex: "09d4ee"))
            Text(hint)
                .font(.system(size: 9))
                .foregroundColor(Color(hex: "4a6572"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(hex: "0d1f33"))
        .cornerRadius(8)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundColor(Color(hex: "f59e0b"))
            Text("Couldn't load swimmer analytics")
                .font(.headline)
                .foregroundColor(Color(hex: "e2f4fa"))
            Text(message)
                .font(.caption)
                .foregroundColor(Color(hex: "7a9bb0"))
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
                .fill(Color(hex: "1a2d42"))
                .frame(width: 56, height: 56)
                .overlay(
                    Text(initials)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(Color(hex: "09d4ee"))
                )
            Text(swimmer.fullName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(Color(hex: "e2f4fa"))
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
                .foregroundColor(Color(hex: "09d4ee"))
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundColor(Color(hex: "7a9bb0"))
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
                    .foregroundColor(Color(hex: "7a9bb0"))
                Spacer()
                Text(formatMs(mean))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(hex: "09d4ee"))
                Spacer()
                Text(formatMs(maxMs))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(hex: "7a9bb0"))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Bar
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(hex: "1a3050"))
                        .frame(height: 16)
                    // ±1σ range
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(hex: "09d4ee").opacity(0.3))
                        .frame(width: geo.size.width, height: 16)
                    // PB marker (if it's within the visible range)
                    if let pb = personalBestMs, pb >= minMs, pb <= maxMs {
                        let xRatio = Double(pb - minMs) / Double(maxMs - minMs)
                        Rectangle()
                            .fill(Color(hex: "f59e0b"))
                            .frame(width: 2, height: 24)
                            .offset(x: geo.size.width * CGFloat(xRatio) - 1, y: -4)
                    }
                }
            }
            .frame(height: 24)
            HStack {
                Label("±1σ", systemImage: "ruler")
                    .font(.system(size: 9))
                    .foregroundColor(Color(hex: "4a6572"))
                Spacer()
                if personalBestMs != nil {
                    Label("PB", systemImage: "flag.fill")
                        .font(.system(size: 9))
                        .foregroundColor(Color(hex: "f59e0b"))
                }
            }
        }
    }

    private func formatMs(_ ms: Int) -> String {
        String(format: "%.2fs", Double(ms) / 1000.0)
    }
}