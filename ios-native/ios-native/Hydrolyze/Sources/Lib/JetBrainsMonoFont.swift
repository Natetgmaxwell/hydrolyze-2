import SwiftUI
import UIKit

/// JetBrains Mono Nerd Font — robust loader that tries multiple naming
/// variants before falling back to system monospaced.
///
/// Why: the nerd-fonts project ships font files with slightly different
/// naming conventions across releases. Some use the file-name-style
/// "JetBrainsMonoNerdFont-Bold" (no spaces, hyphenated) for the font's
/// POSTSCRIPT name; others use the human-readable "JetBrainsMono Nerd Font
/// Bold" (spaces, no hyphen). iOS looks fonts up by POSTSCRIPT name, so
/// the wrong name means silent fallback to whatever SwiftUI's Font.custom
/// does internally — which is usually a system font, not the user's font.
///
/// This helper tries every common variant in order and uses the first one
/// that resolves. If none match, it falls back to .system monospaced —
/// the app still builds and runs, just without the custom font.
///
/// If the font still doesn't show up after the user has dropped the .ttf
/// files in Resources/Fonts/ and regen'd the project, the likely cause is
/// the file names don't match Info.plist UIAppFonts. Check both match
/// exactly. The README in Resources/Fonts/ has the expected names.
enum JetBrainsMonoFont {
    /// Tries to find a UIFont matching the requested weight. Returns nil if
    /// no JetBrains Mono Nerd Font variant is available, in which case
    /// callers should fall back to .system monospaced.
    static func uiFont(size: CGFloat, weight: Font.Weight = .regular) -> UIFont? {
        for name in candidateNames(for: weight) {
            if let font = UIFont(name: name, size: size) {
                return font
            }
        }
        return nil
    }

    private static func candidateNames(for weight: Font.Weight) -> [String] {
        let isBold: Bool
        switch weight {
        case .bold, .heavy, .semibold:
            isBold = true
        default:
            isBold = false
        }
        let weightName = isBold ? "Bold" : "Regular"
        // Try in this order: hyphenated-no-spaces → spaced → NF short form.
        // First match wins. Common nerd-fonts naming variations covered.
        return [
            "JetBrainsMonoNerdFont-\(weightName)",         // hyphenated
            "JetBrainsMono Nerd Font \(weightName)",     // spaced
            "JetBrainsMonoNF-\(weightName)",             // NF short, hyphenated
            "JetBrainsMono NF \(weightName)",            // NF short, spaced
        ]
    }
}

extension Font {
    /// JetBrains Mono Nerd Font at the given size and weight. Falls back to
    /// `.system` monospaced at the same size/weight if the custom font
    /// isn't bundled (e.g., Xcode preview, or the .ttf files haven't been
    /// dropped in yet).
    static func jetBrainsMono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if let uiFont = JetBrainsMonoFont.uiFont(size: size, weight: weight) {
            return Font(uiFont)
        }
        return .system(size: size, weight: weight, design: .monospaced)
    }
}
