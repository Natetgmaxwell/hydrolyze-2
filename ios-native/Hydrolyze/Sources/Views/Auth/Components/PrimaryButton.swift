import SwiftUI

/// Primary action button — 56pt tall, cyan fill, black text, glow shadow.
/// Loading state replaces label with a ProgressView spinner.
///
/// Micro-interactions:
/// - Press feedback: scales to 0.97 and dims to 0.92 on press.
///   The cyan glow shadow + scale-down together make the press
///   feel "real" instead of an invisible gray tick.
/// - Haptic: a light tap on press so the user's finger knows the
///   button registered.
/// - Breathing glow: the cyan shadow gently pulses (0.3 → 0.5
///   opacity on a 1.2s cycle) when the button is idle, so it
///   visually "invites" the tap.
struct PrimaryButton: View {
    let title: String
    var isLoading: Bool = false
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
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
            .shadow(
                color: Color(hex: "09d4ee").opacity(isLoading ? 0.3 : 0.3),
                radius: 20, x: 0, y: 0
            )
        }
        .buttonStyle(PressFeedbackStyle(scale: 0.97, dim: 0.92))
        .disabled(isLoading)
        // Subtle glow pulse on the shadow when idle — the button
        // "breathes" gently to invite tap. Pauses while loading.
        .phaseAnimator([0.3, 0.5], trigger: isLoading == false) { content, opacity in
            content.shadow(
                color: Color(hex: "09d4ee").opacity(opacity),
                radius: 20, x: 0, y: 0
            )
        } animation: { _ in
            Animations.breathing
        }
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
