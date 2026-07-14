import SwiftUI
import UIKit

/// PHASE 2.8.3: Coach-side "Invite Swimmer" sheet.
///
/// Opened from the SwimmerDetailView header toolbar (the
/// share-style icon next to Edit). Generates a 6-character
/// invite code via AuthService.generateInviteCode and displays
/// it for the coach to share with the swimmer (text, email,
/// in person — however they want).
///
/// The 3-step flow inside the sheet:
/// 1. Confirmation: "Invite {Name} to Hydrolyze?"
/// 2. Code display: large monospaced code + copy-to-clipboard
///    + regenerate option
/// 3. Done: "Code copied" or "Done — swimmer can sign up now"
///
/// Why this is a sheet (not a push): the coach is already on
/// the SwimmerDetailView; the sheet preserves their place while
/// they generate + share the code. Closing the sheet returns
/// to the swimmer's profile with no navigation loss.
///
/// Coach-side flow per the user's "I" answer (Phase 2.8
/// spec open question #4): "SwimmerDetailView header toolbar"
struct InviteSwimmerSheet: View {
    let swimmerId: String
    let swimmerName: String
    let onDismiss: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AuthManager.self) private var authManager
    @State private var inviteCode: String?
    @State private var generatedAt: Date?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var didCopy = false

    private var authService: AuthService { AuthService() }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                header
                if let code = inviteCode {
                    codeDisplay(code: code)
                } else if isLoading {
                    loadingState
                } else {
                    confirmState
                }
                if let errorMessage {
                    errorBanner(errorMessage)
                }
                Spacer()
                if inviteCode != nil {
                    regenerateButton
                    doneButton
                } else {
                    cancelButton
                }
            }
            .padding(24)
            .background(Color.bgBase.ignoresSafeArea())
            .navigationTitle("Invite to Hydrolyze")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .foregroundColor(Color.accentCyan)
                }
            }
        }
        .task {
            // Auto-generate the code on first appear (per spec:
            // coach shouldn't need to tap a "Generate" button —
            // it's part of the invitation gesture)
            await generateCode()
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.badge.plus")
                .font(.system(size: 44))
                .foregroundColor(Color.accentCyan)
            Text("Invite \(swimmerName)")
                .font(.title2.weight(.semibold))
                .foregroundColor(Color.textPrimary)
            Text("Generate a 6-character code so \(swimmerName) can sign in to see their times.")
                .font(.callout)
                .foregroundColor(Color.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 16)
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(Color.accentCyan)
            Text("Generating code…")
                .font(.footnote)
                .foregroundColor(Color.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private var confirmState: some View {
        VStack(spacing: 12) {
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.displayLarge)
                .foregroundColor(Color.accentCyan.opacity(0.6))
            Text("Ready to invite")
                .font(.headline)
                .foregroundColor(Color.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private func codeDisplay(code: String) -> some View {
        VStack(spacing: 16) {
            // The code, large and monospaced — the hero of the sheet
            HStack(spacing: 6) {
                ForEach(Array(code), id: \.self) { char in
                    Text(String(char))
                        .font(.system(size: 36, weight: .bold, design: .monospaced))
                        .foregroundColor(Color.accentCyan)
                        .frame(width: 44, height: 56)
                        .background(Color.bgInset)
                        .cornerRadius(8)
                }
            }

            if let generatedAt {
                Text("Code generated \(generatedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundColor(Color.textFaint)
            }

            // Copy button
            Button(action: { copy(code) }) {
                HStack {
                    Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                    Text(didCopy ? "Copied!" : "Copy code")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.accentCyan.opacity(0.2))
                .foregroundColor(Color.accentCyan)
                .cornerRadius(10)
            }

            Text("Share this code with \(swimmerName). They'll enter it when signing up. The code expires in 7 days.")
                .font(.footnote)
                .foregroundColor(Color.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 8)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .font(.footnote)
        }
        .foregroundColor(.orange)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.15))
        .cornerRadius(8)
    }

    private var regenerateButton: some View {
        Button {
            Task { await generateCode() }
        } label: {
            HStack {
                Image(systemName: "arrow.clockwise")
                Text("Regenerate code")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.bgInset)
            .foregroundColor(Color.textPrimary)
            .cornerRadius(10)
        }
    }

    private var doneButton: some View {
        Button {
            onDismiss()
            dismiss()
        } label: {
            Text("Done")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.accentCyan)
                .foregroundColor(Color.bgBase)
                .cornerRadius(10)
        }
    }

    private var cancelButton: some View {
        Button("Cancel") { dismiss() }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundColor(Color.textMuted)
    }

    // MARK: - Actions

    private func generateCode() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let code = try await authService.generateInviteCode(
                swimmerId: swimmerId,
                expiresInDays: 7
            )
            self.inviteCode = code
            self.generatedAt = Date()
            self.didCopy = false
        } catch {
            self.errorMessage = "Couldn't generate code: \(error.localizedDescription)"
        }
    }

    private func copy(_ code: String) {
        UIPasteboard.general.string = code
        didCopy = true
        // Reset the checkmark after 2 seconds for a subtle haptic-like feedback
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { didCopy = false }
        }
    }
}

#Preview {
    InviteSwimmerSheet(
        swimmerId: "preview-id",
        swimmerName: "Mock Alice",
        onDismiss: {}
    )
    .environment(AuthManager())
    .preferredColorScheme(.dark)
}