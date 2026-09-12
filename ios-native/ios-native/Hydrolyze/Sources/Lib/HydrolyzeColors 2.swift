import SwiftUI

/// Hydrolyze color vocabulary. Every color in the app must come from here.
/// Rule: don't use raw hex at the call site. The semantic name carries intent.
///
/// V0.46 deep-teal system (V0.46_SPEC.md §Design tokens): pool-water
/// monochrome surfaces, one coral action per screen state. Teal mid is
/// structure only — never text (fails 3:1 on dark, WCAG 2.2).
///
/// How to add a new color: only if it represents a NEW semantic role.
/// Don't add 'actionLight' variants — adjust the existing token's opacity
/// at the call site (.accentAction.opacity(0.5)) instead.

extension Color {
    // Surfaces
    static let bgBase        = Color(hex: "083133")  // window background — the water at 5am
    static let bgRaised      = Color(hex: "1A4345")  // cards, chips (mist @10% over abyss)
    static let bgSunken      = Color(hex: "0E3A3C")  // popovers, dropdowns
    static let bgInset       = Color(hex: "254D4F")  // pill/chip resting (mist @16%)
    static let bgSelected    = Color(hex: "31595B")  // selected tab background (mist @22%)
    static let bgDeep        = Color(hex: "1B484A")  // elevated panels, timing backdrop

    // Hairlines & dividers
    static let divider       = Color(hex: "2E5355")  // hairline rules between sections

    // Text (WCAG on bgBase)
    static let textPrimary   = Color(hex: "C0E2E4")  // main copy (10.2:1)
    static let textMuted     = Color(hex: "86AEB0")  // secondary copy, captions (5.8:1)
    static let textFaint     = Color(hex: "5F8789")  // eyebrows, data labels only (2.9:1 — never body)
    static let textOnAccent  = Color(hex: "081A2B")  // copy on coral filled surfaces

    // Accent — THE CTA (≤20% of any screen)
    static let accentAction     = Color(hex: "FF6B4A")  // coral: START/LAP/primary Save (5.0:1 on abyss)
    static let accentActionDim  = Color(hex: "D9583C")  // pressed/border states
    static let accentAmber      = Color(hex: "F5B34B")  // warnings, variance hints — NOT a CTA

    // Status (brightened for teal bg)
    static let statusSuccess = Color(hex: "4ADE80")  // green: success indicators
    static let statusError   = Color(hex: "F87171")  // red: error indicators
}
