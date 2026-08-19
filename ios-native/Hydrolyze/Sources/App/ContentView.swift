import SwiftUI
import UIKit

/// PHASE 2.X: CoachTab — destinations for the coach surface.
/// Identity type for the iPad sidebar's selection binding and the
/// ForEach that drives the row list. Case order matches the iPhone
/// TabView order so the sidebar reads top-to-bottom in the same
/// sequence users tap left-to-right on iPhone.
///
/// ponytail 2026-07-18: lifted out of coachTabView so the iPad
/// NavigationSplitView and the iPhone TabView can share one source
/// of truth for tab labels + SF Symbols.
enum CoachTab: String, CaseIterable, Identifiable {
    case today = "Today"
    case swimmers = "Swimmers"
    case workouts = "Workouts"
    case profile = "Profile"

    var id: String { rawValue }
    var title: String { rawValue }

    var systemImage: String {
        switch self {
        case .today:    return "house.fill"
        case .swimmers: return "person.2.fill"
        case .workouts: return "calendar"
        case .profile:  return "gearshape.fill"
        }
    }
}

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
///
/// ponytail 2026-07-18: the coach surface is now adaptive — iPhone
/// gets the existing TabView, iPad gets a NavigationSplitView with
/// a sidebar of destinations. See coachAdaptiveView.
struct ContentView: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var coachTabSelection: CoachTab? = .today
    @State private var hasRequestedOrientation = false

    var body: some View {
        #if DEBUG
        // V0.46 Slice 5: screenshot harness routes (extends Slice 3's
        // `-v46-demo-timing`). Each surface renders standalone with a
        // DEBUG seed branch in its `.task` — headless simctl capture
        // can't sign in or tap through the coach shell. DEBUG-only;
        // a stripped build routes straight to primaryBody.
        if let surface = V46DemoSurface.detect() {
            v46DemoRoot(surface)
        } else {
            primaryBody
        }
        #else
        primaryBody
        #endif
    }

    private var primaryBody: some View {
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
                    coachAdaptiveView
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bgBase)
        .onAppear {
            guard !hasRequestedOrientation,
                  UIDevice.current.userInterfaceIdiom == .pad,
                  horizontalSizeClass == .regular,
                  let windowScene = UIApplication.shared.connectedScenes
                      .compactMap({ $0 as? UIWindowScene })
                      .first(where: { $0.activationState == .foregroundActive })
            else { return }

            hasRequestedOrientation = true
            windowScene.requestGeometryUpdate(
                .iOS(interfaceOrientations: .landscape)
            )
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(Color.textMuted)
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
    #if DEBUG
    /// V0.46 Slice 5: surfaces reachable via `-v46-demo-<surface>` launch
    /// args for the screenshot harness. Each case routes to the real view;
    /// the surface's `.task` seeds DEBUG state (see the per-view seed
    /// branches). `timing` keeps Slice 3's name for continuity.
    private enum V46DemoSurface: String, CaseIterable {
        case today, timing, review, swimmers, workouts, builder, swimmer

        static func detect() -> V46DemoSurface? {
            let args = ProcessInfo.processInfo.arguments
            for surface in allCases where args.contains("-v46-demo-\(surface.rawValue)") {
                return surface
            }
            return nil
        }
    }

    @ViewBuilder
    private func v46DemoRoot(_ surface: V46DemoSurface) -> some View {
        switch surface {
        case .today:     TodayView()
        case .timing:    v46DemoTimingRoot
        case .review:    SessionReviewView(sessionId: "v46-demo")
        case .swimmers:  SwimmersListView()
        case .workouts:  WorkoutsListView()
        case .builder:   WorkoutBuilderView(workoutId: nil)
        case .swimmer:
            SwimmerHomeView()
                .environment(authManager)
                .task { authManager.seedV46DemoStateIfNeeded() }
        }
    }

    /// V0.46 Slice 3 (kept for the timing route): wraps the real
    /// TimingView with a 4-rep 50m Free prefill (single-swimmer +
    /// known reps = the rep-dot path).
    private var v46DemoTimingRoot: some View {
        NavigationStack {
            TimingView(
                prefill: SetPrefill(
                    stroke: "Free",
                    distance: 50,
                    reps: 4,
                    interval: nil,
                    intensityLabel: nil,
                    workoutSetId: nil,
                    intensityType: nil,
                    fragmentContexts: nil,
                    gear: nil
                )
            )
        }
    }
    #endif

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
        .tint(Color.textPrimary)
        // ponytail: tab bar gets a real surface (Color.bgRaised),
        // not transparent-floating. Visually anchors the bottom of
        // the app — the bar feels "on" the surface, not hovering.
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarBackground(Color.bgRaised, for: .tabBar)
        // ponytail: tighter tab icons. Default SF Symbol sizing is
        // generous — small scale reads more professional.
        .imageScale(.small)
    }

    /// PHASE 2.X: Adaptive coach shell — picks the right native
    /// container for the current horizontal size class.
    ///
    /// - iPhone (compact): the existing TabView (`coachTabView`).
    ///   Bottom tab bar, four destinations, tappable.
    /// - iPad (regular): NavigationSplitView with a sidebar list
    ///   of destinations on the left and the active destination's
    ///   view on the right. `.navigationSplitViewStyle(.balanced)`
    ///   would split equally, but on iPad the default is already
    ///   two-up with the sidebar visible — balanced is implicit.
    ///
    /// ponytail 2026-07-18: per user feedback ("ipad os is a
    /// second class citizen"), iPad was rendering the phone TabView
    /// at the bottom of a giant screen — a phone layout on an iPad.
    /// Now iPad gets the native pattern: a permanent sidebar of
    /// destinations, the active one always one tap away. The
    /// `coachTabSelection` state is shared between the iPad
    /// sidebar's `List(selection:)` and the `detail` switch, so
    /// tapping a sidebar row updates the detail pane.
    @ViewBuilder
    private var coachAdaptiveView: some View {
        if horizontalSizeClass == .regular {
            NavigationSplitView(columnVisibility: .constant(.all)) {
                List(selection: $coachTabSelection) {
                    Section {
                        ForEach(CoachTab.allCases) { tab in
                            NavigationLink(value: tab) {
                                // V0.44 Slice 2 (2026-08-18): tell 7 —
                                // generic system-blue icons in sidebar.
                                // V0.46 Slice 4: selected tab = wayfinding state, not an
                                // action — selected reads mist
                                // (textPrimary), unselected textFaint,
                                // and the List tint below pairs with
                                // this so the selection pill is
                                // teal-family too. Coral never appears
                                // in persistent navigation chrome.
                                Label(tab.title, systemImage: tab.systemImage)
                                    .foregroundStyle(
                                        coachTabSelection == tab
                                            ? Color.textPrimary
                                            : Color.textFaint
                                    )
                            }
                        }
                    } header: {
                        // V0.44 Slice 1 (2026-08-18): sidebar wordmark
                        // — JetBrains Mono Bold. Small, quiet, confident
                        // per the spec; replaces the prior
                        // `.navigationTitle("Hydrolyze")` which was SF
                        // bold. The mono is the brand signature: same
                        // font that runs the timing screen numbers,
                        // pulled up into the chrome.
                        Text("Hydrolyze")
                            .font(.jetBrainsMono(size: 20, weight: .bold))
                            .foregroundColor(Color.textPrimary)
                            .textCase(nil)
                    }
                }
                .listStyle(.sidebar)
                // V0.46 Slice 4: selection tint is teal-family (mist), not
                // coral — the tab bar carries wayfinding state, and
                // coral is reserved for the one action per screen.
                // Pairs with the per-Label `.foregroundStyle` switch
                // above (selected = mist, unselected = textFaint).
                .tint(Color.textPrimary)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
            } detail: {
                switch coachTabSelection ?? .today {
                case .today:    TodayView()
                case .swimmers: SwimmersListView()
                case .workouts: WorkoutsListView()
                case .profile:  ProfileView()
                }
            }
        } else {
            coachTabView
        }
    }
}

#Preview {
    ContentView()
        .environment(AuthManager())
}