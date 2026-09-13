import Foundation
import SwiftUI

/// V0.55 S0a (2026-09-13): the line-by-line classifier + highlighter for
/// the "As written" surface on `WorkoutDetailView`. Ported from the JS
/// prototype in `sketches/003-respected-raw/index.html` (validated by
/// the 2026-09-12 sketch suite). Lives in its own type so it's
/// unit-testable without SwiftUI.
///
/// Design contract (V0.55 spec §"As-written surface"):
/// - **Rendered AS WRITTEN, never normalised.** `4.30` stays `4.30`.
///   The classifier highlights it amber but does not rewrite the
///   character. No ellipsis anywhere; lines wrap.
/// - **Zero data loss.** Every raw line renders. Un-classified lines
///   just show un-highlighted.
/// - **Pure logic.** No SwiftUI view logic in `highlighted(rawText:)` —
///   it returns `[RawLine]` (class + AttributedString). The SwiftUI
///   view in `RawWorkoutTextView.swift` consumes that array.
enum RawWorkoutLineClass: String, Sendable, Codable, CaseIterable {
    case set
    case note
    case section
    case round
    case blank  // empty line — vertical breathing room only
}

/// One classified line: the original characters (verbatim) + the line
/// class + the attributed rendering used by `Text(attributedString:)`.
struct RawLine: Identifiable, Equatable {
    let id: Int           // index in the source — stable for SwiftUI ForEach
    let original: String  // trimmed source line, exactly as the coach wrote it
    let kind: RawWorkoutLineClass
    /// The styled characters. Numbers bold-white, intervals amber,
    /// strokes coral (accentAction), gear green. The underlying
    /// characters are unchanged — this is purely typographic.
    let attributed: AttributedString

    static func == (lhs: RawLine, rhs: RawLine) -> Bool {
        lhs.id == rhs.id && lhs.original == rhs.original && lhs.kind == rhs.kind && lhs.attributed == rhs.attributed
    }
}

/// V0.55 S0a (2026-09-13): the classification engine + AttributedString
/// builder. Three responsibilities:
///   1. Split raw text into lines, preserving empties (they render as
///   vertical breathing room — never dropped).
///   2. Classify each non-empty line as set / note / section / round
///   using the regex set validated by sketch 003.
///   3. Build an `AttributedString` per line, applying the four
///   highlight categories (number / interval / stroke / gear) WITHOUT
///   rewriting characters.
enum RawWorkoutLineClassifier {

    // MARK: - Section / round / set patterns
    //
    // These mirror the JS classifier in sketches/003-respected-raw. Order
    // matters — round is checked before set so a "3 rounds of:" line
    // doesn't match the generic reps regex.

    /// Section keywords (warm-up, main set, cool-down, drill, etc).
    /// Anchored to start of line so a phrase like "...main set in the
    /// first 200..." doesn't get classified as a section.
    private static let sectionExact: NSRegularExpression = {
        let pattern = #"^(warm[\s-]?up|warm[\s-]?down|cool[\s-]?down|main set|drill(ing)?|technique|kick set|pull set|sprint|activation)\s*:?\s*$"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Section keywords that may appear with a non-empty suffix
    /// (e.g. "Drill Progression", "Option 1: ..."). Match start of
    /// line; require no `\d x \d` rep pattern on the same line.
    private static let sectionContains: NSRegularExpression = {
        let pattern = #"^(warm[\s-]?up|main set|drill progression|technique set|cool[\s-]?down|optional speed activation)\b"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Round headers: "3 rounds of:" / "3× through" / "3 rounds".
    private static let round: NSRegularExpression = {
        let pattern = #"^\d+\s*(?:x|×)?\s*(?:rounds?\s+of|through)\s*:?\s*$"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Rep pattern: `\d+ [x×] \d+(\.\d+)?` — e.g. "3 x 300", "8×50".
    private static let reps: NSRegularExpression = {
        let pattern = #"\d+\s*[x×]\s*\d+(?:\.\d+)?"#
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    /// Bare-distance set: a number (optionally suffixed "m") at the
    /// start of line. E.g. "400 kick" / "200 free" → set. But "Two
    /// 400s" doesn't match (word-number prefix, out of Phase 1 scope).
    private static let bareDistance: NSRegularExpression = {
        let pattern = #"^\d+(?:\.\d+)?\s*(?:m\b)?"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Reject "30 sec extra rest" / "30 sec rest" — `^\d+\s*sec`.
    private static let secPrefix: NSRegularExpression = {
        let pattern = #"^\d+\s*sec"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    // MARK: - Highlight patterns

    /// Intervals: @ 4:30, @ 4.30, on 2:50, 10–15 s rest, :30, @:50,
    /// 30 sec rest. Mirrors JS `ivRe` in sketch 003.
    private static let interval: NSRegularExpression = {
        let pattern = #"(?:@|on\s+)?\s*\d?\d[:.]\d\d(?:\s*[–-]\s*\d?\d[:.]\d\d)?|@\s*:?\d\d|\d+[–-]\d+\s*s(?:\s*rest)?|\d+\s*s\b\s*rest"#
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    /// Stroke vocabulary. `\b` boundaries so "free" matches but
    /// "freedom" doesn't.
    private static let stroke: NSRegularExpression = {
        let pattern = #"\b(?:free|freestyle|back|breast|fly|IM|kick|pull|drill|choice)\b"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Gear vocabulary. "paddles" / "fins" / "snorkel" / "buoy" /
    /// "kickboard" etc.
    private static let gear: NSRegularExpression = {
        let pattern = #"\b(?:fins|paddles?|pull\s+buoy|buoy|kickboard|snorkel|band|parachute|tennis\s+balls|board|noodle)\b"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    // MARK: - Public API

    /// Classify every line in `rawText`, build the attributed
    /// rendering, return the array consumed by `RawWorkoutTextView`.
    /// The view never sees the raw string again.
    static func highlighted(rawText: String) -> [RawLine] {
        // Preserve the coach's line breaks verbatim. `split(separator:
        // "\n", omittingEmptySubsequences: false)` is the only way to
        // keep the empty lines (which become visual breathing room).
        let lines = rawText.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.enumerated().map { idx, rawSubstring -> RawLine in
            let original = String(rawSubstring).trimmingCharacters(in: .whitespaces)
            if original.isEmpty {
                return RawLine(id: idx, original: original, kind: .blank, attributed: AttributedString(""))
            }
            let kind = classify(line: original)
            let attributed = style(line: original)
            return RawLine(id: idx, original: original, kind: kind, attributed: attributed)
        }
    }

    /// Classify a single non-empty line. Order of checks is load-bearing
    /// (round beats set; section beats set on short lines; set beats
    /// note).
    static func classify(line: String) -> RawWorkoutLineClass {
        let nsLine = line as NSString
        let fullRange = NSRange(location: 0, length: nsLine.length)
        if round.firstMatch(in: line, options: [], range: fullRange) != nil {
            return .round
        }
        if sectionExact.firstMatch(in: line, options: [], range: fullRange) != nil {
            return .section
        }
        // "Section-but-with-trailing-copy" (e.g. "Drill Progression"):
        // short line, matches a section keyword, no rep pattern.
        if line.count < 34,
           sectionContains.firstMatch(in: line, options: [], range: fullRange) != nil,
           reps.firstMatch(in: line, options: [], range: fullRange) == nil {
            return .section
        }
        if reps.firstMatch(in: line, options: [], range: fullRange) != nil {
            return .set
        }
        // Bare distance at start (e.g. "400 kick for body/head ..."):
        // reject Capitalised-sentence starters ("Two 400s" → note),
        // and reject "30 sec extra rest" → note.
        if bareDistance.firstMatch(in: line, options: [], range: fullRange) != nil {
            guard let first = line.first else { return .note }
            let firstIsUpperWord = first.isUppercase && first.isLetter
            if !firstIsUpperWord,
               secPrefix.firstMatch(in: line, options: [], range: fullRange) == nil {
                return .set
            }
        }
        return .note
    }

    /// Build the AttributedString for one non-empty line. Numbers get
    /// bold + textPrimary (per spec — "numbers bold white"), intervals
    /// amber, strokes coral (accentAction), gear green. Same colour
    /// grammar the `WorkoutPreview` structured view uses.
    static func style(line: String) -> AttributedString {
        var attributed = AttributedString(line)
        attributed.foregroundColor = Color.textPrimary
        attributed.font = .system(size: 14, design: .monospaced)

        // Collect every numeric span as substrings (UTF-16 fragments),
        // dedup by content. The reps pass covers "3 x 100" as a block
        // and the bareDistance pass covers a leading "400" alone.
        // Dedup is needed because the leading "3" of "3 x 100" is
        // matched by both — without dedup we'd bold it twice
        // (harmless visually but wasteful). We KEEP both passes
        // because a line like "400 kick" only has a bareDistance
        // match, not a reps match.
        var boldedSubstrings: [String] = []
        var boldedSet: Set<String> = []
        forEachMatch(reps, in: line) { r in
            let s = nsSubstring(r, from: line)
            if !boldedSet.contains(s) {
                boldedSet.insert(s)
                boldedSubstrings.append(s)
            }
        }
        forEachMatch(bareDistance, in: line) { r in
            let s = nsSubstring(r, from: line)
            // Reject if this substring is already covered by a
            // longer reps match (e.g. "3" ⊂ "3 x 100").
            let covered = boldedSet.contains(where: { existing in existing.range(of: s) != nil })
            if !covered {
                boldedSet.insert(s)
                boldedSubstrings.append(s)
            }
        }
        for s in boldedSubstrings {
            applyStyleOnAll(to: &attributed, substring: s) { container in
                container.font = .system(size: 14, weight: .bold, design: .monospaced)
                container.foregroundColor = Color.textPrimary
            }
        }

        // Colour passes: each regex match gets its own foreground
        // colour, applied independently. The number-bold spans get
        // re-asserted as textPrimary above so digits remain white;
        // here we let the colour overwrites win on the non-number
        // span (intervals amber, strokes blue, gear green).
        forEachMatch(interval, in: line) { r in
            applyStyleOnAll(to: &attributed, substring: nsSubstring(r, from: line)) { c in
                c.foregroundColor = .accentAmber
            }
        }
        forEachMatch(stroke, in: line) { r in
            applyStyleOnAll(to: &attributed, substring: nsSubstring(r, from: line)) { c in
                c.foregroundColor = .accentAction
            }
        }
        // Gear: spec says "green token or textSecondary — use existing
        // Color tokens only; if no green exists use textMuted". The
        // app has `statusSuccess` (4ADE80), an existing semantic
        // green for positive indicators. Gear is a success-state-
        // positive concept ("this set uses gear"), so we map it there
        // rather than dropping to textMuted. If a future design
        // review demotes gear to muted, swap this one token.
        forEachMatch(gear, in: line) { r in
            applyStyleOnAll(to: &attributed, substring: nsSubstring(r, from: line)) { c in
                c.foregroundColor = .statusSuccess
            }
        }
        return attributed
    }

    // MARK: - Span helpers

    /// Iterate non-overlapping matches of `regex` over `line` and call
    /// `body` for each NSRange.
    private static func forEachMatch(
        _ regex: NSRegularExpression,
        in line: String,
        _ body: (NSRange) -> Void
    ) {
        let nsLine = line as NSString
        regex.enumerateMatches(in: line, options: [], range: NSRange(location: 0, length: nsLine.length)) { result, _, _ in
            guard let m = result else { return }
            body(m.range)
        }
    }

    /// Extract the substring of `line` at `range` (UTF-16).
    private static func nsSubstring(_ range: NSRange, from line: String) -> String {
        let nsLine = line as NSString
        return nsLine.substring(with: range)
    }

    /// Apply `style` to every occurrence of `substring` in
    /// `attributed`. `attributed.range(of:)` only finds the FIRST
    /// match — so we iterate manually from the start position to
    /// cover all occurrences (e.g. "free" appearing twice in
    /// "free/free by round").
    private static func applyStyleOnAll(
        to attributed: inout AttributedString,
        substring: String,
        style: (inout AttributeContainer) -> Void
    ) {
        guard !substring.isEmpty else { return }
        var searchStart = attributed.startIndex
        while searchStart < attributed.endIndex,
              let found = attributed[searchStart...].range(of: substring) {
            var container = AttributeContainer()
            style(&container)
            attributed[found].mergeAttributes(container)
            searchStart = found.upperBound
        }
    }
}