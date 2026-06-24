import SwiftUI

/// Shared animation curves for the app. Use these instead of
/// `.easeInOut(duration: 0.2)` at call sites — keeps the motion
/// language coherent and lets us tune it in one place.
///
/// The vocabulary:
/// - `Animations.snap` — quick, decisive (filter tab switch,
///   toggle, button press). 0.18s.
/// - `Animations.gentle` — softer, for things that should feel
///   like they "settle" (rows fading in, filter list updates,
///   empty state appearing). 0.35s.
/// - `Animations.springSnappy` — spring with a small overshoot
///   for things that should "pop" (LAP flash, row insert,
///   success state). response 0.3, damping 0.6.
/// - `Animations.springSoft` — spring with no overshoot for
///   things that should "settle without bounce" (state
///   transitions, page-level animations). response 0.45,
///   damping 0.8.
enum Animations {
    static let snap: Animation = .easeInOut(duration: 0.18)
    static let gentle: Animation = .easeInOut(duration: 0.35)

    static let springSnappy: Animation = .spring(response: 0.30, dampingFraction: 0.60)
    static let springSoft: Animation = .spring(response: 0.45, dampingFraction: 0.80)

    /// Breathing animation for "I exist, tap me" invitations
    /// (the 200pt START button in the .ready state, etc.).
    static let breathing: Animation = .easeInOut(duration: 1.2)
}
