import SwiftUI

enum AuthMode {
    case signIn
    case signUp
    case reset
}

/// LoginView — email/password auth screen with three inline modes (Sign In / Sign Up / Reset).
///
/// Micro-interactions:
/// - Mode switch: the form cross-fades with a slight upward
///   translation (0.18s) instead of the default `withAnimation`
///   swap. The transition tells the user "we're in a different
///   state" without sliding the whole form around.
/// - Submit: light haptic on tap, success haptic on resolve,
///   error haptic on throw. The user gets a tactile signal
///   whether the auth succeeded or failed.
struct LoginView: View {
    @Environment(AuthManager.self) private var authManager

    @State private var email = ""
    @State private var password = ""
    @State private var mode: AuthMode = .signIn
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showSuccessAlert = false
    @State private var successMessage = ""
    @State private var emailFieldFocused = false
    @State private var passwordFieldFocused = false
    // PHASE 2.6 v1.17.0: emotional-design Slice 1 motion change.
    // The HYDROLYZE wordmark reveals on first appear (gentle opacity
    // + scale 0.95 → 1.0 over 0.6s). First-impression warmth through
    // motion, NOT through "Welcome back, Coach." text. See
    // [[concepts/warmth-through-motion]] for the principle.
    @State private var wordmarkAppeared = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                headerSection
                formSection
                submitButton
                footerLinks
            }
            .padding(.horizontal, 24)
            .padding(.top, 60)
        }
        .background(Color(hex: "060e18"))
        .onTapGesture { hideKeyboard() }
        .alert("Authentication Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Success", isPresented: $showSuccessAlert) {
            Button("OK") { }
        } message: {
            Text(successMessage)
        }
    }

    private var headerSection: some View {
        VStack(spacing: 8) {
            // HYDROLYZE wordmark — gentle fade-in + scale-up on
            // first appear, so the first paint of the login screen
            // reads as "the app is alive" rather than "the screen
            // snapped into place." The animation is keyed off
            // wordmarkAppeared, which flips to true in the .task
            // below. The opacity + scale together produce the
            // "reveal" feeling without being theatrical.
            Text("HYDROLYZE")
                .font(.system(size: 44, weight: .bold, design: .monospaced))
                .foregroundColor(Color(hex: "09d4ee"))
                .opacity(wordmarkAppeared ? 1 : 0)
                .scaleEffect(wordmarkAppeared ? 1.0 : 0.95)
                .animation(Animations.gentle, value: wordmarkAppeared)
                .task {
                    // Tiny delay so the user perceives the reveal
                    // rather than it being instantaneous with the
                    // screen paint. 80ms is enough for the brain
                    // to register "something appeared" without
                    // feeling laggy.
                    try? await Task.sleep(for: .milliseconds(80))
                    wordmarkAppeared = true
                }

            Text(subtitleText)
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "4a6572"))
                // Subtitle cross-fades when the mode changes —
                // the "Coach Dashboard" → "Create Account" swap
                // becomes a soft transition, not a hard cut.
                .id("subtitle-\(mode)")
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .top)),
                    removal: .opacity
                ))
        }
        .animation(Animations.gentle, value: mode)
    }

    private var subtitleText: String {
        switch mode {
        case .signIn: return "Coach Dashboard"
        case .signUp: return "Create Account"
        case .reset: return "Reset Password"
        }
    }

    private var formSection: some View {
        VStack(spacing: 16) {
            // Animated swap of the form fields so the password
            // field appears/disappears gracefully when toggling
            // into/out of the reset mode.
            AuthTextField(
                label: "Email",
                text: $email
            )

            if mode != .reset {
                AuthTextField(
                    label: "Password",
                    text: $password,
                    isSecure: true
                )
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .top)),
                    removal: .opacity
                ))
            }
        }
        .animation(Animations.gentle, value: mode)
    }

    private var submitButton: some View {
        PrimaryButton(
            title: buttonTitle,
            isLoading: isLoading
        ) {
            Haptics.tap()
            Task { await submit() }
        }
    }

    private var buttonTitle: String {
        switch mode {
        case .signIn: return "SIGN IN"
        case .signUp: return "SIGN UP"
        case .reset: return "SEND RESET LINK"
        }
    }

    private var footerLinks: some View {
        VStack(spacing: 12) {
            switch mode {
            case .signIn:
                HStack {
                    Text("New coach?")
                        .foregroundColor(Color(hex: "4a6572"))
                    Button("Sign Up") {
                        Haptics.selection()
                        withAnimation(Animations.gentle) { mode = .signUp }
                    }
                    .foregroundColor(Color(hex: "09d4ee"))
                    Spacer()
                    Button("Forgot Password?") {
                        Haptics.selection()
                        withAnimation(Animations.gentle) { mode = .reset }
                    }
                    .foregroundColor(Color(hex: "09d4ee"))
                }
                .font(.system(size: 12))
            case .signUp, .reset:
                Button("Back to Sign In") {
                    Haptics.selection()
                    withAnimation(Animations.gentle) {
                        mode = .signIn; email = ""; password = ""
                    }
                }
                .foregroundColor(Color(hex: "09d4ee"))
                .font(.system(size: 12))
            }
        }
    }

    private func submit() async {
        guard validateInput() else { return }
        isLoading = true
        errorMessage = nil

        do {
            switch mode {
            case .signIn:
                try await authManager.signIn(email: email, password: password)
                Haptics.success()
            case .signUp:
                try await authManager.signUp(email: email, password: password)
                Haptics.success()
                successMessage = "Check your email to confirm your account."
                showSuccessAlert = true
                mode = .signIn
                password = ""
            case .reset:
                try await authManager.resetPassword(email: email)
                Haptics.success()
                successMessage = "Check your email for a reset link."
                showSuccessAlert = true
                mode = .signIn
            }
        } catch {
            Haptics.error()
            errorMessage = "Authentication Error: \(error.localizedDescription)"
        }

        isLoading = false
    }

    private func validateInput() -> Bool {
        if email.isEmpty {
            Haptics.warning()
            errorMessage = "Please enter your email address."
            return false
        }
        if mode != .reset && password.isEmpty {
            Haptics.warning()
            errorMessage = "Please enter your password."
            return false
        }
        if mode == .signUp && password.count < 6 {
            Haptics.warning()
            errorMessage = "Password must be at least 6 characters."
            return false
        }
        return true
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

#Preview {
    LoginView()
        .environment(AuthManager())
}
