import SwiftUI

/// AnalyticsTabView — the tab container for the new coach-facing
/// Analytics feature. Hosts a NavigationStack with SquadAnalyticsView
/// as the root; tapping a swimmer pushes the SwimmerAnalyticsView.
///
/// Coach-only for v1 (matches the existing single-role app).
/// Permission gating comes in a later v when admin/member roles
/// are properly split.
struct AnalyticsTabView: View {
    var body: some View {
        NavigationStack {
            SquadAnalyticsView()
        }
        .tint(Color(hex: "09d4ee"))
    }
}

#Preview {
    AnalyticsTabView()
        .environment(AuthManager())
}