import SwiftUI

@main
struct HydrolyzeApp: App {
    /// AuthManager is created once and injected into the view tree.
    /// Views that `@Environment(AuthManager.self)` will share this single instance.
    @State private var authManager = AuthManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(authManager)
        }
    }
}