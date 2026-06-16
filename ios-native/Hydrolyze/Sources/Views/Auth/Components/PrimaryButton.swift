import SwiftUI

/// Primary action button — 56pt tall, cyan fill, black text, glow shadow.
/// Loading state replaces label with a ProgressView spinner.
struct PrimaryButton: View {
    let title: String
    var isLoading: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isLoading {
                    ProgressView()
                        .tint(.black)
                } else {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.black)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(Color(hex: "09d4ee"))
            .cornerRadius(12)
            .shadow(color: Color(hex: "09d4ee").opacity(0.3), radius: 20, x: 0, y: 0)
        }
        .disabled(isLoading)
    }
}

#Preview {
    VStack(spacing: 20) {
        PrimaryButton(title: "SIGN IN", isLoading: false) {}
        PrimaryButton(title: "SIGN UP", isLoading: true) {}
    }
    .padding()
    .background(Color(hex: "060e18"))
}