import SwiftUI

/// Hydrolyze type roles. Every text in the app picks a role, never a size.
/// Sizes are tuned together: change one and the rhythm breaks. Pick from the role.
/// Add a new role only if it represents a NEW semantic meaning; don't add
/// 'bodySmall2' variants — adjust the existing role's size or use the role with
/// a weight modifier at the call site.

extension Font {
    // Display — the stopwatch, big numbers. JetBrains Mono only.
    static let displayHuge   = Font.jetBrainsMono(size: 86, weight: .bold)   // TimingView stopwatch
    static let displayLarge  = Font.jetBrainsMono(size: 56, weight: .bold)   // Analytics headers

    // Headings — section titles, screen titles, names.
    static let titleLarge    = Font.system(size: 28, weight: .bold)           // full name (SwimmerDetailView hero)
    static let titleMedium   = Font.system(size: 22, weight: .bold)           // date 'Today' header
    static let titleSmall    = Font.system(size: 17, weight: .semibold)       // row titles, list items

    // Body — most copy.
    static let body          = Font.system(size: 15)
    static let bodyEmphasis  = Font.system(size: 15, weight: .medium)

    // Captions & hints.
    static let caption       = Font.system(size: 13)
    static let captionStrong = Font.system(size: 13, weight: .medium)

    // Eyebrows — section labels, all-caps taglines above content.
    // JetBrains Mono gives the brand a typographic signature.
    static let eyebrow       = Font.jetBrainsMono(size: 11, weight: .semibold)
    static let eyebrowLarge  = Font.jetBrainsMono(size: 13, weight: .semibold)

    // Numeric — lap times, PBs, distances, counts.
    // JetBrains Mono digits don't shift width, so '32.4' and '31.8' align.
    static let numericLarge  = Font.jetBrainsMono(size: 22, weight: .bold)    // PB display
    static let numeric       = Font.jetBrainsMono(size: 15)                  // inline PB refs
    static let numericSmall  = Font.jetBrainsMono(size: 11)                  // micro numbers

    // Mono inline — already monospaced by context (chips, badges, code-like labels).
    static let monoChip      = Font.system(size: 11, design: .monospaced)
    static let monoChipBold  = Font.system(size: 11, weight: .semibold, design: .monospaced)
}