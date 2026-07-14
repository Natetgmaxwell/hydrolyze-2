import SwiftUI

/// Reusable email/password input field — 56pt tall, elevated bg, floating label.
///
/// Micro-interactions:
/// - Focus border animates in (cyan stroke slides in via animated
///   overlay RoundedRectangle) instead of just appearing.
/// - Haptic on focus: a soft selection tap when the field gains
///   focus, so the keyboard popping up is matched by a tactile
///   "I am here now" signal.
struct AuthTextField: View {
    let label: String
    @Binding var text: String
    var isSecure: Bool = false
    /// PHASE 2.8.6: optional keyboard type override. Defaults to
    /// `.emailAddress` for non-secure fields (matches the original
    /// design — every non-secure field in the login forms is an
    /// email). Set to `.default` for name fields, `.asciiCapable`
    /// for the invite code field (uppercase letters only).
    var keyboardType: UIKeyboardType = .emailAddress
    /// PHASE 2.8.6: SF Symbol name drawn as a leading icon. The
    /// original component was label-only; Phase 2.8.4's
    /// SwimmerLoginFlow needed per-field icons to disambiguate
    /// First name / Last name / Invite code. Backwards compatible:
    /// when nil, no icon is drawn.
    var icon: String? = nil
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    /// Slice 4: breathing pulse on empty unfocused fields — the
    /// border softly invites a tap. The text inside stays steady;
    /// only the overlay stroke's opacity oscillates (0.6 → 1.0 →
    /// 0.6 on a 2s easeInOut cycle). Suppressed when Reduce Motion
    /// is on (handled in the phaseAnimator trigger).
    private var shouldPulse: Bool {
        text.isEmpty && !isFocused
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.5)
                .foregroundColor(Color.textFaint)
                // Slight label color shift on focus so the user
                // knows which field is the active one without
                // having to look at the border.
                .foregroundColor(isFocused ? Color.accentCyan : Color.textFaint)
                .animation(Animations.snap, value: isFocused)

            HStack(spacing: 12) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(isFocused ? Color.accentCyan : Color.textFaint)
                        .frame(width: 18)
                }
                Group {
                    if isSecure {
                        SecureField("", text: $text)
                    } else {
                        TextField("", text: $text)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(keyboardType)
                    }
                }
                .foregroundColor(Color.textPrimary)
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .background(Color.bgInset)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isFocused ? Color.accentCyan : Color.divider,
                        lineWidth: isFocused ? 1.5 : 1.0
                    )
                    .animation(Animations.snap, value: isFocused)
                    .phaseAnimator([0.6, 1.0, 0.6], trigger: shouldPulse && !reduceMotion) { content, alpha in
                        content.opacity(alpha)
                    } animation: { _ in
                        .easeInOut(duration: 2.0)
                    }
            )
        }
        .focused($isFocused)
        .onChange(of: isFocused) { _, focused in
            if focused { Haptics.selection() }
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        AuthTextField(label: "Email", text: .constant(""), icon: "envelope.fill")
        AuthTextField(label: "Password", text: .constant("secret"), isSecure: true, icon: "lock.fill")
        AuthTextField(label: "First name", text: .constant(""), keyboardType: .default, icon: "person.fill")
        AuthTextField(label: "Invite code", text: .constant(""), keyboardType: .asciiCapable, icon: "key.fill")
    }
    .padding()
    .background(Color.bgBase)
}
