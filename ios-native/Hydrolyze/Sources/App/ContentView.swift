import SwiftUI

/// ContentView — app root with three-way routing based on the
/// signed-in user's role:
/// - .unauthenticated → LoginView
/// - .swimmer → SwimmerHomeView (My Swims / My PBs / My Coach / Profile)
/// - .coach → CoachHomeView (Today / Swimmers / Workouts / Profile)
///
/// The role signal comes from AuthManager.role (Phase 2.2).
/// Per VISION.md "coach is the authority," the coach is the
/// primary surface. Swimmers see their own data; the coach sees
/// the squad.
struct ContentView: View {
    @Environment(AuthManager.self) private var authManager

    var body: some View {
        Group {
            if authManager.isLoading {
                loadingView
            } else if authManager.currentUser == nil {
                LoginView()
            } else {
                switch authManager.role {
                case .unauthenticated:
                    LoginView()
                case .swimmer:
                    SwimmerHomeView()
                case .coach:
                    coachTabView
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bgBase)
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(Color.accentCyan)
            Text("Loading...")
                .font(.system(.body, design: .default))
                .foregroundColor(Color.textMuted)
        }
    }

    /// PHASE 2.6: The coach's tab bar. Extracted into a private
    /// computed view so the three-way routing in `body` stays
    /// readable.
    ///
    /// ponytail 2026-07-15: Analytics tab removed while the squad-
    /// level progression view is still in development. The
    /// AnalyticsTabView.swift file (with its "Coming in v2"
    /// placeholder) is kept intact — when the squad-level design
    /// lands, re-add the tab here between Swimmers and Workouts:
    ///
    ///     AnalyticsTabView()
    ///         .tabItem {
    ///             Label("Analytics", systemImage: "chart.line.uptrend.xyaxis")
    ///         }
    ///
    /// The coach tab bar is now 4 tabs: Today / Swimmers /
    /// Workouts / Profile. Tighter navigation rhythm + one less
    /// "Coming in v2" surface competing for the coach's
    /// attention.
    private var coachTabView: some View {
        TabView {
            TodayView()
                .tabItem {
                    Label("Today", systemImage: "house.fill")
                }

            SwimmersListView()
                .tabItem {
                    Label("Swimmers", systemImage: "person.2.fill")
                }

            WorkoutsListView()
                .tabItem {
                    Label("Workouts", systemImage: "calendar")
                }

            ProfileView()
                .tabItem {
                    Label("Profile", systemImage: "gearshape.fill")
                }
        }
        .tint(Color.accentCyan)
        // ponytail: tab bar gets a real surface (Color.bgRaised),
        // not transparent-floating. Visually anchors the bottom of
        // the app — the bar feels "on" the surface, not hovering.
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarBackground(Color.bgRaised, for: .tabBar)
        // ponytail: tighter tab icons. Default SF Symbol sizing is
        // generous — small scale reads more professional.
        .imageScale(.small)
    }
}

#Preview {
    ContentView()
        .environment(AuthManager())
}