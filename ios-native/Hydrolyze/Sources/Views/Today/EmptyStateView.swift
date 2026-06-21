import SwiftUI

/// EmptyStateView — shown when no workout is scheduled today.
///
/// Micro-interaction: the house icon breathes (gentle scale 1.0 →
/// 1.06 → 1.0 on a 1.6s cycle). The breath is intentionally slow
/// and small — it reads as "alive but patient" rather than
/// "pulsing alert." The first impression for an empty state is
/// that the app is waiting for the user, not broken.
struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "house.fill")
                .font(.system(size: 48))
                .foregroundColor(Color(hex: "4a6572"))
                .phaseAnimator([1.0, 1.06, 1.0]) { content, scale in
                    content.scaleEffect(scale)
                } animation: { _ in
                    .easeInOut(duration: 1.6)
                }

            Text("No workout scheduled")
                .font(.system(size: 18))
                .foregroundColor(Color(hex: "7a9bb0"))

            Text("Tap Workouts to schedule one.")
                .font(.system(size: 13))
                .foregroundColor(Color(hex: "4a6572"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    EmptyStateView()
        .background(Color(hex: "060e18"))
}
