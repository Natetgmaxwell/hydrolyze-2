import SwiftUI

/// Hydrolyze color vocabulary. Every color in the app must come from here.
/// Rule: don't use raw hex at the call site. The semantic name carries intent.
///
/// How to add a new color: only if it represents a NEW semantic role.
/// Don't add 'cyanLight' variants — adjust the existing token's opacity at
/// the call site (.accentCyan.opacity(0.5)) instead.

extension Color {
    // Surfaces
    static let bgBase        = Color(hex: "060e18")  // window background
    static let bgRaised      = Color(hex: "111d2b")  // one elevation up: cards, chips
    static let bgSunken      = Color(hex: "0d1b2a")  // popovers, dropdowns
    static let bgInset       = Color(hex: "1a2d42")  // pill/chip resting, group dividers
    static let bgSelected    = Color(hex: "0d2847")  // selected tab background
    static let bgDeep        = Color(hex: "0d1f33")  // deeper background variant (used in nested surfaces)

    // Hairlines & dividers
    static let divider       = Color(hex: "2d3e50")  // hairline rules between sections

    // Text
    static let textPrimary   = Color(hex: "e2f4fa")  // main copy
    static let textMuted     = Color(hex: "7a9bb0")  // secondary copy, captions
    static let textFaint     = Color(hex: "4a6572")  // section labels, eyebrows, hints
    static let textOnAccent  = Color(hex: "060e18")  // copy ON cyan/amber filled surfaces

    // Accents — the brand's active palette
    static let accentCyan    = Color(hex: "09d4ee")  // brand cyan: primary CTAs, focus, links
    static let accentCyanDim = Color(hex: "06b6d4")  // secondary cyan: intent 'in', softer focus
    static let accentAmber   = Color(hex: "f59e0b")  // warning, intensity, intent 'out' mild
    static let accentAmberOn = Color(hex: "3d2a00")  // copy ON amber filled surfaces
    static let accentSlate   = Color(hex: "71717a")  // neutral pills, intent 'out'

    // Status
    static let statusSuccess = Color(hex: "10b981")  // green: success indicators
    static let statusError   = Color(hex: "ef4444")  // red: error indicators
}