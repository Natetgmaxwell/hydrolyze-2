import SwiftUI

/// EmptyStateView — shown when no workout is scheduled today.
///
/// Micro-interaction: the house icon breathes (gentle scale 1.0 →
/// 1.06 → 1.0 on a 1.6s cycle). The breath is intentionally slow
/// and small — it reads as "alive but patient" rather than
/// "pulsing alert." The first impression for an empty state is
/// that the app is waiting for the user, not broken.
struct EmptyStateView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "house.fill")
                .font(.system(size: 48))
                .foregroundColor(Color.textFaint)
                .phaseAnimator([1.0, 1.06, 1.0]) { content, scale in
                    content.scaleEffect(scale)
                } animation: { _ in
                    reduceMotion ? .linear(duration: 0.01) : .easeInOut(duration: 1.6)
                }

            Text("The week's clear — plan a session.")
                .font(.eyebrowLarge)
                .foregroundColor(Color.textMuted)

            Text("Head to Workouts to build one.")
                .font(.caption)
                .foregroundColor(Color.textFaint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    EmptyStateView()
        .background(Color.bgBase)
}
