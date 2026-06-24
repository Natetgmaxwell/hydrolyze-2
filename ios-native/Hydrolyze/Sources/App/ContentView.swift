import SwiftUI

/// ContentView — app root with TabView. Routes to LoginView when unauthenticated,
/// tab bar when authenticated.
struct ContentView: View {
    @Environment(AuthManager.self) private var authManager

    var body: some View {
        Group {
            if authManager.currentUser == nil && !authManager.isLoading {
                LoginView()
            } else if authManager.currentUser == nil {
                loadingView
            } else {
                tabView
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

    private var tabView: some View {
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