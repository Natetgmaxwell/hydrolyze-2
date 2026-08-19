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

/// PHASE 2.4 + 2.8.4: AuthMode — the 3 modes for the coach login
/// flow (Sign In / Sign Up / Reset). The SwimmerLoginFlow has its
/// own nested Mode enum (signIn / createAccount) because the
/// swimmer flow uses a 2-mode pill picker instead of a 3-mode
/// inline toggle; the swimmer flow doesn't reset their own
/// password through the iOS app, so Reset is not a swimmer mode.
enum AuthMode {
    case signIn
    case signUp
    case reset
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
    @State private var animateIn: Bool = false

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
        .background(Color.bgBase)
        .onTapGesture { hideKeyboard() }
        .animation(.easeInOut(duration: 0.18), value: role)
        .onAppear { animateIn = true }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 8) {
            Text("HYDROLYZE")
                .font(.displayLarge)
                .foregroundColor(Color.accentAction)
                .opacity(animateIn ? 1.0 : 0.0)
                .scaleEffect(animateIn ? 1.0 : 0.95)
                .animation(Animations.springSoft, value: animateIn)

            Text("Sign in to your account")
                .font(.caption)
                .foregroundColor(Color.textFaint)
                .opacity(animateIn ? 1.0 : 0.0)
                .animation(Animations.gentle.delay(0.15), value: animateIn)
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
                        .foregroundColor(role == tab ? Color.textOnAccent : Color.textMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(role == tab ? Color.accentAction : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color.bgDeep)
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
                label: "Email",
                text: $email,
                isSecure: false,
                keyboardType: .emailAddress,
                icon: "envelope.fill"
            )
            AuthTextField(
                label: "Password",
                text: $password,
                isSecure: true,
                icon: "lock.fill"
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
                    ProgressView().tint(Color.textOnAccent)
                } else {
                    Text(submitButtonText)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color.textOnAccent)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.accentAction)
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
                    .font(.caption)
                    .foregroundColor(Color.accentAction)
            }
            .buttonStyle(.plain)

            Button {
                Haptics.tap()
                withAnimation(.easeInOut(duration: 0.18)) {
                    mode = .reset
                }
            } label: {
                Text("Forgot password?")
                    .font(.caption)
                    .foregroundColor(Color.textMuted)
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

/// PHASE 2.4 + 2.8.4: SwimmerLoginFlow — Sign In + Create Account + Reset.
///
/// PHASE 2.4 (SwimmerLoginFlow): swimmers don't self-signup —
/// the coach creates the account via the Create Swimmer Account
/// sheet. The swimmer just enters the email + password the coach
/// gave them.
///
/// PHASE 2.8.4 (this update): adds a "Create Account" mode where
/// swimmers can self-signup using an invite code the coach gives
/// them. The redemption flow (AuthService.redeemInviteCode)
/// creates the auth.users row + links swimmers.auth_id, then
/// the swimmer signs in immediately. The data-porting question
/// (the user's explicit ask) is structurally answered by the
/// Phase 2.1 schema: swimmer_id is permanent, setting
/// swimmers.auth_id turns on data visibility via the existing
/// swimmer_own_* RLS policies. No data migration script needed.
///
/// Mode is toggled by tapping "Create Account" / "I already have
/// an account" link below the submit button. The mode toggle
/// resets the form fields so each mode starts clean.
struct SwimmerLoginFlow: View {
    @Environment(AuthManager.self) private var authManager

    // Shared state
    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showSuccessAlert = false
    @State private var successMessage = ""

    // PHASE 2.8.4: create-account mode state
    @State private var mode: Mode = .signIn
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var inviteCode = ""

    private var authService: AuthService { AuthService() }

    enum Mode { case signIn, createAccount }

    var body: some View {
        VStack(spacing: 24) {
            // PHASE 2.8.4: mode picker — 2 pills at the top of the
            // form so the swimmer knows which flow they're in.
            modePicker
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

    // MARK: - Mode picker

    private var modePicker: some View {
        HStack(spacing: 0) {
            modePill(title: "Sign In", isActive: mode == .signIn) {
                switchMode(.signIn)
            }
            modePill(title: "Create Account", isActive: mode == .createAccount) {
                switchMode(.createAccount)
            }
        }
        .background(Color.bgInset)
        .cornerRadius(10)
        .padding(.bottom, 8)
    }

    private func modePill(title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                .foregroundColor(isActive ? Color.textOnAccent : Color.textMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(isActive ? Color.accentAction : Color.clear)
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .padding(2)
    }

    private func switchMode(_ newMode: Mode) {
        mode = newMode
        // Reset form fields on mode switch so each flow starts clean
        email = ""
        password = ""
        firstName = ""
        lastName = ""
        inviteCode = ""
        errorMessage = nil
    }

    // MARK: - Form

    @ViewBuilder
    private var formSection: some View {
        VStack(spacing: 16) {
            AuthTextField(
                label: "Email",
                text: $email,
                isSecure: false,
                keyboardType: .emailAddress,
                icon: "envelope.fill"
            )
            AuthTextField(
                label: mode == .signIn ? "Password" : "Password (min 8 chars)",
                text: $password,
                isSecure: true,
                icon: "lock.fill"
            )
            if mode == .createAccount {
                AuthTextField(
                    label: "First name",
                    text: $firstName,
                    isSecure: false,
                    keyboardType: .default,
                    icon: "person.fill"
                )
                AuthTextField(
                    label: "Last name (optional)",
                    text: $lastName,
                    isSecure: false,
                    keyboardType: .default,
                    icon: "person"
                )
                AuthTextField(
                    label: "Invite code (from your coach)",
                    text: $inviteCode,
                    isSecure: false,
                    keyboardType: .asciiCapable,
                    icon: "key.fill"
                )
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            }
        }
    }

    private var submitButton: some View {
        Button {
            Haptics.tap()
            Task {
                switch mode {
                case .signIn: await handleSignIn()
                case .createAccount: await handleCreateAccount()
                }
            }
        } label: {
            HStack {
                if isLoading {
                    ProgressView().tint(Color.textOnAccent)
                } else {
                    Text(mode == .signIn ? "Sign In" : "Create Account")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color.textOnAccent)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.accentAction)
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
        .disabled(isLoading || !canSubmit)
    }

    private var canSubmit: Bool {
        switch mode {
        case .signIn:
            return !email.isEmpty && !password.isEmpty
        case .createAccount:
            return !email.isEmpty && password.count >= 8 &&
                   !firstName.trimmingCharacters(in: .whitespaces).isEmpty &&
                   inviteCode.trimmingCharacters(in: .whitespaces).count == 6
        }
    }

    private var footerLinks: some View {
        VStack(spacing: 8) {
            Button {
                Haptics.tap()
                Task { await handleReset() }
            } label: {
                Text("Forgot password?")
                    .font(.caption)
                    .foregroundColor(Color.textMuted)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Actions

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

    /// PHASE 2.8.4: redeem the invite code, then sign in with
    /// the same credentials. On success, the authManager's
    /// session restoration picks up the new auth user and
    /// ContentView's role routing puts the swimmer on
    /// SwimmerHomeView.
    private func handleCreateAccount() async {
        let trimmedCode = inviteCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedFirst = firstName.trimmingCharacters(in: .whitespaces)
        let trimmedLast = lastName.trimmingCharacters(in: .whitespaces).isEmpty
            ? nil
            : lastName.trimmingCharacters(in: .whitespaces)

        // Local validation (the server validates too, but we
        // can give a faster error message)
        guard trimmedEmail.contains("@") else {
            errorMessage = "Please enter a valid email."
            Haptics.error()
            return
        }
        guard password.count >= 8 else {
            errorMessage = "Password must be at least 8 characters."
            Haptics.error()
            return
        }
        guard !trimmedFirst.isEmpty else {
            errorMessage = "Please enter your first name."
            Haptics.error()
            return
        }
        guard trimmedCode.count == 6 else {
            errorMessage = "Invite code must be exactly 6 characters."
            Haptics.error()
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            // Step 1: redeem the code (creates auth.users + links auth_id)
            _ = try await authService.redeemInviteCode(
                code: trimmedCode,
                email: trimmedEmail,
                password: password,
                firstName: trimmedFirst,
                lastName: trimmedLast
            )
            // Step 2: sign in (the auth.users row exists now)
            try await authManager.signIn(email: trimmedEmail, password: password)
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