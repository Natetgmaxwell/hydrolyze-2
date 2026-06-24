import SwiftUI

/// A `ButtonStyle` that gives buttons a tactile press-down feel.
///
/// On iOS, the default `Button` renders a subtle gray opacity change
/// when pressed. For a 200×200 cyan LAP button, that opacity change
/// is invisible — the button is so big the opacity tick is dwarfed
/// by the surface. A scale-down + slight dim is what tells the user
/// "your tap registered" without resorting to a system alert or HUD.
///
/// Usage:
///
/// ```swift
/// Button("LAP") { ... }
///     .buttonStyle(PressFeedbackStyle(scale: 0.92, dim: 0.85))
/// ```
///
/// - Parameters:
///   - scale: the scale factor when pressed (1.0 = no change,
///     0.9 = 10% smaller). Defaults to 0.96 — visible but not "bouncy."
///   - dim: the opacity when pressed (1.0 = no change, 0.7 = 30%
///     dimmer). Defaults to 0.85.
struct PressFeedbackStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    var dim: Double = 0.85

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1.0)
            .opacity(configuration.isPressed ? dim : 1.0)
            .animation(
                configuration.isPressed
                    ? .spring(response: 0.15, dampingFraction: 0.7)
                    : .spring(response: 0.35, dampingFraction: 0.7),
                value: configuration.isPressed
            )
    }
}

/// A more aggressive press feedback for the giant primary CTAs
/// (the 200pt START button, the 160pt LAP button). These buttons
/// dominate the screen and need a more obvious confirmation.
struct StrongPressFeedbackStyle: ButtonStyle {
    var scale: CGFloat = 0.92

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(
                configuration.isPressed
                    ? .spring(response: 0.12, dampingFraction: 0.65)
                    : .spring(response: 0.4, dampingFraction: 0.55),
                value: configuration.isPressed
            )
    }
}

/// View modifier form for places that don't take a `ButtonStyle`
/// directly (e.g., applying to a NavigationLink's label or a custom
/// tap-gesture view).
struct PressFeedbackModifier: ViewModifier {
    @State private var isPressed = false
    var scale: CGFloat = 0.96
    var dim: Double = 0.85

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed ? scale : 1.0)
            .opacity(isPressed ? dim : 1.0)
            .animation(
                isPressed
                    ? .spring(response: 0.15, dampingFraction: 0.7)
                    : .spring(response: 0.35, dampingFraction: 0.7),
                value: isPressed
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isPressed { isPressed = true }
                    }
                    .onEnded { _ in
                        isPressed = false
                    }
            )
    }
}

extension View {
    /// Apply a scale-down + dim-on-press feel to any view. Use when
    /// the view is tappable but isn't a `Button` (e.g., a card with
    /// `.onTapGesture`).
    func pressFeedback(scale: CGFloat = 0.96, dim: Double = 0.85) -> some View {
        modifier(PressFeedbackModifier(scale: scale, dim: dim))
    }
}
