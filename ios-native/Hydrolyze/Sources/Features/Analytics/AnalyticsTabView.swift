import SwiftUI

/// AnalyticsTabView — placeholder for the v2 Analytics feature.
///
/// PHASE 0.3 (2026-06-23): The v1.14 squad/swimmer analytics views
/// (SquadAnalyticsView, SwimmerAnalyticsView, ProgressionChart,
/// ChartDataService, ISO8601DateParser) were deferred to v2 per the
/// user's MVP-first directive. The squad-level design captured at
/// `originals/hydrolyze-squad-level-progression-design-v1` (resistance
/// as F-v proxy, one-screen one-signal list, gear-capture mechanic)
/// is the v2 reference. The Phase 2.1-2.7 swimmer login + Phase 2.8
/// invite-code onboarding are the MVP focus.
///
/// The `SquadAnalyticsView` and `SwimmerAnalyticsView` files have
/// been deleted; this placeholder preserves the ContentView reference
/// at ContentView.swift:63 so the build doesn't break. The v2 work
/// (Phase 2.5+ in the periodised plan) will replace this with the
/// real squad-level view.
///
/// Why this is the right shape:
/// - The ContentView routing (coach/swimmer/unauthenticated) needs
///   AnalyticsTabView's type to exist for the coach path's tab bar.
/// - v2 ships SquadSignalsView + SwimmerDetailView's gear comparison
///   + the Bu load model sparkline for endurance swimmers.
/// - The `ChartDataService` + `ISO8601DateParser` + `ProgressionChart`
///   files are KEPT because `SwimmerHomeViewModel` and
///   `SwimmerDetailViewModel` still consume them (per precheck).
struct AnalyticsTabView: View {
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 56))
                .foregroundStyle(Color(hex: "09d4ee").opacity(0.6))
            Text("Analytics — Coming in v2")
                .font(.title2.weight(.semibold))
            Text("Squad-level progression view + per-swimmer F-V\nlens + Bu load model for endurance swimmers.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Text("MVP focus: live stopwatch + set parser + swimmer login.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(Color(.systemGroupedBackground))
    }
}

#Preview {
    AnalyticsTabView()
        .environment(AuthManager())
}