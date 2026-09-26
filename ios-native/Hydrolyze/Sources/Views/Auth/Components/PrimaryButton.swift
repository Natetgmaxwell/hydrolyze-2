import SwiftUI

/// Primary action button — 56pt tall, cyan fill, black text, flat
/// (no shadow). Loading state replaces label with a ProgressView.
///
/// Micro-interactions:
/// - Press feedback: scales to 0.97 and dims to 0.92 on press so
///   the press feels "real" instead of an invisible gray tick.
/// - Haptic: a light tap on press so the user's finger knows the
///   button registered.
struct PrimaryButton: View {
    let title: String
    var isLoading: Bool = false
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            ZStack {
                if isLoading {
                    ProgressView()
                        .tint(Color.textOnAccent)
                } else {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color.textOnAccent)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(Color.accentAction)
            .cornerRadius(12)
        }
        .buttonStyle(PressFeedbackStyle(scale: 0.97, dim: 0.92))
        .disabled(isLoading)
    }
}

#Preview {
    VStack(spacing: 20) {
        PrimaryButton(title: "SIGN IN", isLoading: false) {}
        PrimaryButton(title: "SIGN UP", isLoading: true) {}
    }
    .padding()
    .background(Color.bgBase)
}
