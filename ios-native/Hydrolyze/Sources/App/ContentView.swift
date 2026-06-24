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
        .background(Color(hex: "060e18"))
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(Color(hex: "09d4ee"))
            Text("Loading...")
                .font(.system(.body, design: .default))
                .foregroundColor(Color(hex: "7a9bb0"))
        }
    }

    /// PHASE 2.6: The coach's tab bar. Extracted into a private
    /// computed view so the three-way routing in `body` stays
    /// readable. The 5 tabs match the prior ContentView —
    /// Analytics is still here for v1, will be demoted in Phase 4.
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

            AnalyticsTabView()
                .tabItem {
                    Label("Analytics", systemImage: "chart.line.uptrend.xyaxis")
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
        .tint(Color(hex: "09d4ee"))
    }
}

#Preview {
    ContentView()
        .environment(AuthManager())
}