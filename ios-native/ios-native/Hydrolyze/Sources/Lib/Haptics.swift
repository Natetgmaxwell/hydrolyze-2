import UIKit

/// Hydrolyze haptic vocabulary.
///
/// One file, one vocabulary. The rest of the app calls semantic names
/// (`Haptics.tap()`, `Haptics.success()`) instead of constructing
/// `UIImpactFeedbackGenerator` at call sites — that keeps the
/// "tactile language" of the app in one place and makes it easy to
/// tune intensity per surface (e.g., the LAP button gets a medium
/// impact; tab switches get a soft selection).
///
/// All generators are pre-initialized and reused — they're cheap
/// but constructing them per-call is wasteful and can cause the
/// first haptic to feel delayed.
///
/// The vocabulary is intentionally tight. Don't add ad-hoc
/// `UIImpactFeedbackGenerator(style: .rigid)` calls elsewhere —
/// add a named case here so the app's tactile language stays
/// coherent.
enum Haptics {
    /// Softest tap. Use for: filter pills, tab switches, segmented
    /// control changes, picker scroll. Frequent and quiet.
    static func selection() {
        selectionGenerator.selectionChanged()
        selectionGenerator.prepare()
    }

    /// Light physical tap. Use for: button presses in lists,
    /// secondary actions, row taps. The "I tapped a thing" signal.
    static func tap() {
        lightImpact.impactOccurred()
        lightImpact.prepare()
    }

    /// Medium physical tap. Use for: the LAP button, primary CTAs
    /// in modal flows, accept/confirm. The "I did the thing" signal.
    static func action() {
        mediumImpact.impactOccurred()
        mediumImpact.prepare()
    }

    /// Heavy physical tap. Use sparingly: destructive actions
    /// (delete, discard session), STOP during timing.
    static func heavy() {
        heavyImpact.impactOccurred()
        heavyImpact.prepare()
    }

    /// Success notification. Use for: form submission success,
    /// session save complete, profile updated. Plays the
    /// "ding-ding" pattern (tap-tap-rise).
    static func success() {
        notification.notificationOccurred(.success)
        notification.prepare()
    }

    /// Warning notification. Use for: low-confidence row confirmed
    /// (the engine isn't sure but the coach is), paired with the
    /// amber variance hint row.
    static func warning() {
        notification.notificationOccurred(.warning)
        notification.prepare()
    }

    /// Error notification. Use for: save failure, network error,
    /// auth error. The "triple buzz" pattern.
    static func error() {
        notification.notificationOccurred(.error)
        notification.prepare()
    }

    // MARK: - Generators (reused, pre-warmed)

    private static let selectionGenerator: UISelectionFeedbackGenerator = {
        let g = UISelectionFeedbackGenerator()
        g.prepare()
        return g
    }()

    private static let lightImpact: UIImpactFeedbackGenerator = {
        let g = UIImpactFeedbackGenerator(style: .light)
        g.prepare()
        return g
    }()

    private static let mediumImpact: UIImpactFeedbackGenerator = {
        let g = UIImpactFeedbackGenerator(style: .medium)
        g.prepare()
        return g
    }()

    private static let heavyImpact: UIImpactFeedbackGenerator = {
        let g = UIImpactFeedbackGenerator(style: .heavy)
        g.prepare()
        return g
    }()

    private static let notification: UINotificationFeedbackGenerator = {
        let g = UINotificationFeedbackGenerator()
        g.prepare()
        return g
    }()
}
