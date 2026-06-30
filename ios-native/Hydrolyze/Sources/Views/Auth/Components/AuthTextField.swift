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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.5)
                .foregroundColor(Color(hex: "4a6572"))
                // Slight label color shift on focus so the user
                // knows which field is the active one without
                // having to look at the border.
                .foregroundColor(isFocused ? Color(hex: "09d4ee") : Color(hex: "4a6572"))
                .animation(Animations.snap, value: isFocused)

            HStack(spacing: 12) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(isFocused ? Color(hex: "09d4ee") : Color(hex: "4a6572"))
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
                .foregroundColor(Color(hex: "e2f4fa"))
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .background(Color(hex: "1a2d42"))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isFocused ? Color(hex: "09d4ee") : Color(hex: "2d3e50"),
                        lineWidth: isFocused ? 1.5 : 1.0
                    )
                    .animation(Animations.snap, value: isFocused)
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
    .background(Color(hex: "060e18"))
}
