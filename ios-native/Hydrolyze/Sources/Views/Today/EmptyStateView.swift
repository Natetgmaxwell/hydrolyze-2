import SwiftUI

/// EmptyStateView — shown when no workout is scheduled today.
///
/// V0.46 Slice 4: the house icon is static. Breathing is reserved
/// for idle CTAs (spec: "Breathing stays on idle CTAs only") — an
/// empty state carries no state to animate, so motion here was
/// ornamental and fails the "does it carry state?" test.
struct EmptyStateView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "house.fill")
                .font(.system(size: 48))
                .foregroundColor(Color.textFaint)

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
