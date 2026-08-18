import SwiftUI

/// ProfileView — coach profile tab. Shows display name, email, and a
/// sign-out button. Replaces the placeholder `SettingsView` from the
/// initial scaffold. The plan's full ProfileView scope (pool units,
/// coach name edit, etc.) lives in I12; this Phase 4 commit is the
/// rename + minimal content. Follow-ups:
///   - pool_units toggle (m/yards)
///   - coach name edit (SettingsView split per plan section 1.5)
///   - sign-out confirm dialog (currently fires immediately)
struct ProfileView: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool
    @State private var showSignOutConfirm = false
    // ponytail (warmth-through-motion iter 6): on-appear reveal.
    // Same pattern as login reveal (d46c444), today reveal (0a90257),
    // workouts reveal (06c6823), swimmers reveal (61404f1, 1ffa02c),
    // and workouts+swimmers cohesion (19e0e9f). When the Profile tab
    // is selected, the content fades + scales in over
    // Animations.springSoft, gated by Reduce Motion for a11y.
    @State private var animateIn: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {
                    headerSection
                    predictionAlgorithmSection
                }
                .padding(.vertical, 16)
            }
            Spacer()
            signOutButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bgBase)
        // ponytail: profile fade-in on tab appear. Gating by
        // reduceMotion is the standard a11y pattern (matches d46c444,
        // 0a90257, 06c6823, 61404f1, 1ffa02c, 19e0e9f).
        .opacity(animateIn ? 1.0 : 0.0)
        .scaleEffect(animateIn ? 1.0 : 0.98)
        .animation(reduceMotion ? nil : Animations.springSoft, value: animateIn)
        .onAppear { animateIn = true }
        .alert("Sign out?", isPresented: $showSignOutConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) {
                Task { await authManager.signOut() }
            }
        } message: {
            Text("You'll need to sign in again to use Hydrolyze.")
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Profile")
                .font(.titleLarge)
                .foregroundColor(Color.accentCyan)
                .padding(.horizontal, 24)
                .padding(.top, 16)

            VStack(alignment: .leading, spacing: 12) {
                if let coachName = authManager.coachName {
                    Text(coachName)
                        .font(.titleSmall)
                        .foregroundColor(Color.textPrimary)
                }

                if let email = authManager.currentUser?.email {
                    Text(email)
                        .font(.body)
                        .foregroundColor(Color.textMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(Color.bgSunken)
            .cornerRadius(12)
            .padding(.horizontal, 24)
        }
    }

    // MARK: - Phase 2.6 prediction algorithm picker
    // Coach toggles between "Median of last 5" (robust to outliers) and
    // "EMA (trend-aware)" (recent swims weighted higher). The choice
    // persists to coaches.preferences via AuthManager.saveCoachPreferences.
    private var predictionAlgorithmSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Prediction algorithm")
                    .font(.eyebrow)
                    .tracking(1.0)
                    .foregroundColor(Color.textFaint)
                Text("How the pairing engine estimates each swimmer's time")
                    .font(.caption)
                    .foregroundColor(Color.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)

            Picker("Prediction algorithm", selection: algorithmBinding) {
                ForEach(PredictionAlgorithm.allCases, id: \.self) { algo in
                    Text(algo.displayName).tag(algo)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)
            .onChange(of: authManager.coachPreferences.predictionAlgorithm) { _, newValue in
                // Persist to Supabase when the picker changes. The
                // in-memory update happens immediately in the binding
                // setter below; this just saves the new value.
                let updated = CoachPreferences(
                    showConfidencePercent: authManager.coachPreferences.showConfidencePercent,
                    predictionAlgorithm: newValue
                )
                Task { await authManager.saveCoachPreferences(updated) }
            }
        }
    }

    /// Binding that updates the AuthManager's coachPreferences immediately
    /// on change (so the picker feels responsive) and triggers a save in
    /// the .onChange modifier above. Avoids the roundtrip-through-state
    /// pattern that would require a separate @State property.
    private var algorithmBinding: Binding<PredictionAlgorithm> {
        Binding(
            get: { authManager.coachPreferences.predictionAlgorithm },
            set: { newValue in
                authManager.coachPreferences.predictionAlgorithm = newValue
            }
        )
    }

    private var signOutButton: some View {
        Button {
            showSignOutConfirm = true
        } label: {
            Text("Sign Out")
                .font(.titleSmall)
                .foregroundColor(Color.statusError)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.bgInset)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.statusError, lineWidth: 1)
                )
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 40)
    }
}

#Preview {
    ProfileView()
        .environment(AuthManager())
}
