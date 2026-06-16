import SwiftUI

/// EmptyStateView — shown when no workout is scheduled today.
/// Per spec: centered icon + prose, no CTA button.
struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "house.fill")
                .font(.system(size: 48))
                .foregroundColor(Color(hex: "4a6572"))

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