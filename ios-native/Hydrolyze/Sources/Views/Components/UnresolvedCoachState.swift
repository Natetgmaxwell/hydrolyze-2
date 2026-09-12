import SwiftUI

/// V0.55 (2026-09-12): surfaced when `AuthManager.coachId` is nil
/// but the user is signed in. The prior behaviour was a silent
/// early-return inside the list VMs (`loadSwimmers(coachId: nil)`,
/// `loadWorkouts(coachId: nil)`) which produced the misleading
/// "The roster's empty." / "No workouts yet — plan a session." /
/// "No squads yet." empty states for what was actually an unresolved
/// coach profile. Now we render an amber retry surface so the coach
/// can tell the difference between "I have no swimmers yet" and
/// "we couldn't load your account" and force a retry.
struct UnresolvedCoachState: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.exclamationmark.fill")
                .font(.system(size: 40))
                .foregroundColor(Color.accentAmber)

            Text("Couldn't load your account")
                .font(.body)
                .foregroundColor(Color.textMuted)

            Text(message)
                .font(.caption)
                .foregroundColor(Color.textFaint)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button("Retry") { onRetry() }
                .font(.caption)
                .foregroundColor(Color.textMuted)
                .padding(.top, 8)
        }
        .padding(.top, 80)
    }
}