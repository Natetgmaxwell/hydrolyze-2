import SwiftUI

enum AuthMode {
    case signIn
    case signUp
    case reset
}

/// LoginView — email/password auth screen with three inline modes (Sign In / Sign Up / Reset).
/// Calls AuthManager.signIn / signUp / resetPassword directly.
/// @State: Swift's equivalent of useState — local component state.
/// @FocusState: tracks which field has keyboard focus for border highlight.
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
            Text("HYDROLYZE")
                .font(.system(size: 44, weight: .bold, design: .monospaced))
                .foregroundColor(Color(hex: "09d4ee"))

            Text(subtitleText)
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "4a6572"))
        }
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
            }
        }
    }

    private var submitButton: some View {
        PrimaryButton(
            title: buttonTitle,
            isLoading: isLoading
        ) {
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
                    Button("Sign Up") { withAnimation { mode = .signUp } }
                        .foregroundColor(Color(hex: "09d4ee"))
                    Spacer()
                    Button("Forgot Password?") { withAnimation { mode = .reset } }
                        .foregroundColor(Color(hex: "09d4ee"))
                }
                .font(.system(size: 12))
            case .signUp, .reset:
                Button("Back to Sign In") { withAnimation { mode = .signIn; email = ""; password = "" } }
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
            case .signUp:
                try await authManager.signUp(email: email, password: password)
                successMessage = "Check your email to confirm your account."
                showSuccessAlert = true
                mode = .signIn
                password = ""
            case .reset:
                try await authManager.resetPassword(email: email)
                successMessage = "Check your email for a reset link."
                showSuccessAlert = true
                mode = .signIn
            }
        } catch {
            errorMessage = "Authentication Error: \(error.localizedDescription)"
        }

        isLoading = false
    }

    private func validateInput() -> Bool {
        if email.isEmpty {
            errorMessage = "Please enter your email address."
            return false
        }
        if mode != .reset && password.isEmpty {
            errorMessage = "Please enter your password."
            return false
        }
        if mode == .signUp && password.count < 6 {
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