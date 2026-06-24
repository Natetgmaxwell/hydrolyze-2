import SwiftUI
import Combine

/// SquadAnalyticsView — coach-facing squad-level progress dashboard.
/// Shows every active swimmer in a list with: name, best time across all
/// PBs (the headline number), last recorded time, and a trend arrow (up =
/// improving, down = regressing, flat = ±2% in last 6 weeks). Tap a row
/// to push the SwimmerAnalyticsView with the full per-swimmer detail
/// (PB trajectory, training band, CV, sparkline).
///
/// Per the v1 §7 of the coach-analytics brainstorm:
///   "All swimmers on a single F-V operating-point chart. A scatter
///    where each dot is a swimmer, x = force proxy, y = velocity proxy.
///    The coach can see the squad's distribution, the spread, the
///    outliers. Useful for relay selection, for planning the season,
///    for justifying individual work."
/// This view is the "scan the squad" workflow — the row-level summary
/// before the per-swimmer drilldown. v1 ships the list; v2 adds the
/// F-V scatter (it's the headline squad view per the brainstorm).
///
/// Coach-only for v1 (matches the existing single-role app).
struct SquadAnalyticsView: View {
    @StateObject private var viewModel = SquadAnalyticsViewModel()
    @Environment(AuthManager.self) private var authManager

    private var coachId: String? {
        authManager.coachId
    }

    var body: some View {
        ZStack {
            Color(hex: "060e18").ignoresSafeArea()

            if viewModel.isLoading && viewModel.summaries.isEmpty {
                ProgressView()
                    .tint(Color(hex: "09d4ee"))
            } else if let error = viewModel.errorMessage {
                errorView(error)
            } else if viewModel.summaries.isEmpty {
                emptyState
            } else {
                listView
            }
        }
        .navigationTitle("Squad Analytics")
        .navigationBarTitleDisplayMode(.large)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(Color(hex: "060e18"), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task {
            await viewModel.load(coachId: coachId)
        }
        .refreshable {
            await viewModel.load(coachId: coachId)
        }
    }

    private var listView: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                squadHeader
                ForEach(viewModel.summaries) { summary in
                    NavigationLink {
                        SwimmerAnalyticsView(swimmerId: summary.swimmer.id)
                    } label: {
                        SquadAnalyticsRow(summary: summary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private var squadHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(viewModel.summaries.count) swimmers")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(Color(hex: "e2f4fa"))
                Text("Tap a swimmer to drill into their progress")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "7a9bb0"))
            }
            Spacer()
            Button {
                Task { await viewModel.load(coachId: coachId) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color(hex: "09d4ee"))
            }
        }
        .padding(.bottom, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.3")
                .font(.system(size: 32))
                .foregroundColor(Color(hex: "4a6572"))
            Text("No swimmers yet")
                .font(.headline)
                .foregroundColor(Color(hex: "7a9bb0"))
            Text("Add swimmers from the Swimmers tab to start tracking progress.")
                .font(.subheadline)
                .foregroundColor(Color(hex: "4a6572"))
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundColor(Color(hex: "f59e0b"))
            Text("Couldn't load squad analytics")
                .font(.headline)
                .foregroundColor(Color(hex: "e2f4fa"))
            Text(message)
                .font(.caption)
                .foregroundColor(Color(hex: "7a9bb0"))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }
}

/// SquadAnalyticsRow — one row in the squad list. Renders: initials, name,
/// best PB (the headline number), last time (the most recent recorded
/// time), and a trend arrow derived from the last 6 weeks of data.
struct SquadAnalyticsRow: View {
    let summary: SquadAnalyticsSummary

    var body: some View {
        HStack(spacing: 12) {
            // Initials avatar
            Circle()
                .fill(Color(hex: "1a2d42"))
                .frame(width: 40, height: 40)
                .overlay(
                    Text(initials)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(hex: "09d4ee"))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(summary.swimmer.fullName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Color(hex: "e2f4fa"))
                HStack(spacing: 6) {
                    Text("Best: \(formatMs(summary.bestTimeMs))")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "7a9bb0"))
                    if let last = summary.lastTimeMs {
                        Text("·")
                            .foregroundColor(Color(hex: "4a6572"))
                        Text("Last: \(formatMs(last))")
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "7a9bb0"))
                    }
                }
            }

            Spacer()

            trendBadge
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(hex: "0d1f33"))
        .cornerRadius(10)
    }

    private var trendBadge: some View {
        let color: Color
        let icon: String
        let label: String
        switch summary.trend {
        case .improving:
            color = Color(hex: "10b981"); icon = "arrow.down.right"; label = "Improving"
        case .regressing:
            color = Color(hex: "ef4444"); icon = "arrow.up.right"; label = "Regressing"
        case .flat:
            color = Color(hex: "7a9bb0"); icon = "minus"; label = "Flat"
        case .insufficientData:
            color = Color(hex: "4a6572"); icon = "circle.dotted"; label = "—"
        }
        return VStack(alignment: .trailing, spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(color)
                .tracking(0.5)
        }
        .frame(width: 60)
    }

    private var initials: String {
        let first = summary.swimmer.firstName.prefix(1)
        let last = (summary.swimmer.lastName ?? "").prefix(1)
        if last.isEmpty { return String(summary.swimmer.firstName.prefix(2)).uppercased() }
        return "\(first)\(last)".uppercased()
    }

    private func formatMs(_ ms: Int?) -> String {
        guard let ms = ms else { return "—" }
        let seconds = Double(ms) / 1000.0
        return String(format: "%.2fs", seconds)
    }
}

#Preview {
    NavigationStack {
        SquadAnalyticsView()
    }
    .environment(AuthManager())
}