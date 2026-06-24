import SwiftUI

/// PHASE 2.4: AuthRoleTab — the entry-point chooser at the top of
/// the login screen. The user picks "Coach" or "Swimmer" before
/// seeing the form. The Coach flow is the existing 3-mode flow
/// (Sign In / Sign Up / Reset). The Swimmer flow is just Sign In
/// + Reset — swimmers don't sign themselves up (the coach creates
/// the account via Create Swimmer Account in the swimmers view).
///
/// Per VISION.md "coach is the authority": the swimmer doesn't
/// self-register. They get an email + one-time password from the
/// coach, then sign in. So the Swimmer tab has no Sign Up form.
enum AuthRoleTab: String, CaseIterable, Identifiable {
    case coach = "Coach"
    case swimmer = "Swimmer"
    var id: String { rawValue }
}

/// PHASE 2.4: Top-level LoginView — chooses Coach vs Swimmer flow.
///
/// This replaces the prior single-flow LoginView. The Coach flow
/// is delegated to `CoachLoginFlow` (the existing 3-mode form,
/// extracted into its own struct). The Swimmer flow is a simpler
/// `SwimmerLoginFlow` (Sign In + Reset only). The tab chooser is
/// a thin segmented control at the top of the form.
struct LoginView: View {
    @Environment(AuthManager.self) private var authManager
    @State private var role: AuthRoleTab = .coach

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                headerSection
                rolePicker
                Group {
                    switch role {
                    case .coach:
                        CoachLoginFlow()
                    case .swimmer:
                        SwimmerLoginFlow()
                    }
                }
                .transition(.opacity)
            }
            .padding(.horizontal, 24)
            .padding(.top, 60)
        }
        .background(Color(hex: "060e18"))
        .onTapGesture { hideKeyboard() }
        .animation(.easeInOut(duration: 0.18), value: role)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 8) {
            Text("HYDROLYZE")
                .font(.system(size: 44, weight: .bold, design: .monospaced))
                .foregroundColor(Color(hex: "09d4ee"))

            Text("Sign in to your account")
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "4a6572"))
        }
    }

    // MARK: - Role picker

    private var rolePicker: some View {
        HStack(spacing: 0) {
            ForEach(AuthRoleTab.allCases) { tab in
                Button {
                    role = tab
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(role == tab ? Color(hex: "060e18") : Color(hex: "7a9bb0"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(role == tab ? Color(hex: "09d4ee") : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color(hex: "0d1f33"))
        .cornerRadius(10)
    }
}

// MARK: - Coach flow

/// PHASE 2.4: CoachLoginFlow — extracted from the prior LoginView.
/// Coach has Sign In / Sign Up / Reset (the 3-mode inline flow).
struct CoachLoginFlow: View {
    @Environment(AuthManager.self) private var authManager

    @State private var email = ""
    @State private var password = ""
    @State private var mode: AuthMode = .signIn
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showSuccessAlert = false
    @State private var successMessage = ""

    var body: some View {
        VStack(spacing: 24) {
            formSection
            submitButton
            footerLinks
        }
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

    private var formSection: some View {
        VStack(spacing: 16) {
            AuthTextField(
                icon: "envelope.fill",
                placeholder: "Email",
                text: $email,
                isSecure: false,
                keyboardType: .emailAddress
            )
            AuthTextField(
                icon: "lock.fill",
                placeholder: "Password",
                text: $password,
                isSecure: true,
                keyboardType: .default
            )
        }
    }

    private var submitButton: some View {
        Button {
            Haptics.tap()
            Task { await handleSubmit() }
        } label: {
            HStack {
                if isLoading {
                    ProgressView().tint(Color(hex: "060e18"))
                } else {
                    Text(submitButtonText)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color(hex: "060e18"))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color(hex: "09d4ee"))
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
        .disabled(isLoading || email.isEmpty || password.isEmpty)
    }

    private var footerLinks: some View {
        VStack(spacing: 8) {
            Button {
                Haptics.tap()
                withAnimation(.easeInOut(duration: 0.18)) {
                    mode = mode == .signIn ? .signUp : .signIn
                }
            } label: {
                Text(mode == .signIn ? "Don't have an account? Sign Up" : "Have an account? Sign In")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "09d4ee"))
            }
            .buttonStyle(.plain)

            Button {
                Haptics.tap()
                withAnimation(.easeInOut(duration: 0.18)) {
                    mode = .reset
                }
            } label: {
                Text("Forgot password?")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "7a9bb0"))
            }
            .buttonStyle(.plain)
        }
    }

    private var submitButtonText: String {
        switch mode {
        case .signIn: return "Sign In"
        case .signUp: return "Create Account"
        case .reset: return "Reset Password"
        }
    }

    private func handleSubmit() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            switch mode {
            case .signIn:
                try await authManager.signIn(email: email, password: password)
                Haptics.success()
            case .signUp:
                try await authManager.signUp(email: email, password: password)
                Haptics.success()
                successMessage = "Account created. Check your email to confirm."
                showSuccessAlert = true
            case .reset:
                try await authManager.resetPassword(email: email)
                Haptics.success()
                successMessage = "Password reset email sent."
                showSuccessAlert = true
            }
        } catch {
            Haptics.error()
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Swimmer flow

/// PHASE 2.4: SwimmerLoginFlow — Sign In + Reset only.
/// Swimmers don't sign up — the coach creates the account via
/// Create Swimmer Account. So no Sign Up form, no coach
/// invitation UI here — the swimmer just enters the email +
/// password the coach gave them.
struct SwimmerLoginFlow: View {
    @Environment(AuthManager.self) private var authManager

    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showSuccessAlert = false
    @State private var successMessage = ""

    var body: some View {
        VStack(spacing: 24) {
            formSection
            submitButton
            footerLinks
        }
        .alert("Sign-in Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Check your email", isPresented: $showSuccessAlert) {
            Button("OK") { }
        } message: {
            Text(successMessage)
        }
    }

    private var formSection: some View {
        VStack(spacing: 16) {
            AuthTextField(
                icon: "envelope.fill",
                placeholder: "Email (from your coach)",
                text: $email,
                isSecure: false,
                keyboardType: .emailAddress
            )
            AuthTextField(
                icon: "lock.fill",
                placeholder: "Password (or one-time code)",
                text: $password,
                isSecure: true,
                keyboardType: .default
            )
        }
    }

    private var submitButton: some View {
        Button {
            Haptics.tap()
            Task { await handleSignIn() }
        } label: {
            HStack {
                if isLoading {
                    ProgressView().tint(Color(hex: "060e18"))
                } else {
                    Text("Sign In")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color(hex: "060e18"))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color(hex: "09d4ee"))
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
        .disabled(isLoading || email.isEmpty || password.isEmpty)
    }

    private var footerLinks: some View {
        VStack(spacing: 8) {
            Button {
                Haptics.tap()
                Task { await handleReset() }
            } label: {
                Text("Forgot password?")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "7a9bb0"))
            }
            .buttonStyle(.plain)
        }
    }

    private func handleSignIn() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await authManager.signIn(email: email, password: password)
            Haptics.success()
        } catch {
            Haptics.error()
            errorMessage = error.localizedDescription
        }
    }

    private func handleReset() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await authManager.resetPassword(email: email)
            Haptics.success()
            successMessage = "Password reset email sent."
            showSuccessAlert = true
        } catch {
            Haptics.error()
            errorMessage = error.localizedDescription
        }
    }
}

/// Helper to hide the keyboard on tap.
private func hideKeyboard() {
    #if canImport(UIKit)
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    #endif
}