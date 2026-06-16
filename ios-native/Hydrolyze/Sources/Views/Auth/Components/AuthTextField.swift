import SwiftUI

/// Reusable email/password input field — 56pt tall, elevated bg, floating label.
/// FocusState: Swift's way to track which field is active (like useState for focus).
struct AuthTextField: View {
    let label: String
    @Binding var text: String
    var isSecure: Bool = false
    @FocusState private var isFocused: Bool  // tracks if this field has keyboard focus

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.5)
                .foregroundColor(Color(hex: "4a6572"))

            Group {
                if isSecure {
                    SecureField("", text: $text)
                } else {
                    TextField("", text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .background(Color(hex: "1a2d42"))
            .foregroundColor(Color(hex: "e2f4fa"))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isFocused ? Color(hex: "09d4ee") : Color(hex: "2d3e50"), lineWidth: 1)
            )
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        AuthTextField(label: "Email", text: .constant(""))
        AuthTextField(label: "Password", text: .constant("secret"), isSecure: true)
    }
    .padding()
    .background(Color(hex: "060e18"))
}