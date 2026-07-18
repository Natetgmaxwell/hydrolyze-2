import Foundation

/// WorkoutParser — on-device synchronous workout text parser.
///
/// MVP port of `scripts/parser-bench/engine.ts`. Handles the common case:
///   1. Split input text by `\n`
///   2. For each non-blank line, extract (reps, distance, stroke,
///      interval, intensity, pacing, gear) via regex
///   3. Emit `ParsedWorkout` with a single `ParsedSection` (title: nil)
///      and a single `ParsedNamedSet` (label: nil) bundling all
///      extracted RepGroups. Section titles, set labels, and notes-as-
///      labels are NOT preserved in the MVP — those are server-parser
///      territory.
///
/// Out of scope (server-parser territory, see engine.ts):
///   - FBBF pattern rotation
///   - N.X notation (e.g. "as 1.fists/swim, 2. catch up/swim")
///   - "same as above" / "do previous" cross-references
///   - Notes-as-labels for the next set
///   - Odd/even sub-rep pairing
///   - Multi-set-per-line split (`100 free 100 back`)
enum WorkoutParser {

    /// Synchronous entry point. Returns a `ParsedWorkout` containing
    /// every line that matched as a set. Lines that don't look like a
    /// set (notes, headers, blank lines) are skipped.
    static func parse(_ text: String) -> ParsedWorkout {
        let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var repGroups: [ParsedRepGroup] = []
        for raw in rawLines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if let rg = parseRepGroup(from: line) {
                repGroups.append(rg)
            }
        }
        return ParsedWorkout(
            title: nil,
            sections: [
                ParsedSection(
                    title: nil,
                    namedSets: [
                        ParsedNamedSet(
                            label: nil,
                            note: nil,
                            repGroups: repGroups
                        )
                    ]
                )
            ]
        )
    }

    // MARK: - Per-line RepGroup extraction

    private static func parseRepGroup(from line: String) -> ParsedRepGroup? {
        let rd = parseRepDist(line)
        if rd.reps == nil && rd.distance == nil { return nil }

        let stroke = parseStroke(line)
        let interval = parseInterval(line)
        let intensity = parseIntensity(line)
        let pacing = parsePacing(line)
        let gear = parseGear(line)
        let gearOptional = gear != nil && isOptional(line)

        return ParsedRepGroup(
            reps: rd.reps,
            distance: rd.distance,
            stroke: stroke,
            interval: interval,
            intensity: intensity,
            pacing: pacing,
            pattern: [],
            patternType: nil,
            connectors: nil,
            note: nil,
            gear: gear,
            gearOptional: gearOptional,
            descend: nil,
            details: nil
        )
    }

    // MARK: - normalize

    /// Lowercase, swap word numbers to digits, collapse "N and a half"
    /// to a decimal, normalize `<digits>.<two-digits>` dot-separated
    /// times to colon form (e.g. "1.20" -> "1:20"), and convert en-dash
    /// to hyphen. Mirrors engine.ts `normalize()`.
    private static func normalize(_ text: String) -> String {
        var out = text.lowercased()
        for (word, num) in wordNumbers {
            let pattern = "\\b\(word)\\b"
            out = replace(pattern, in: out, with: String(num))
        }
        out = replace(#"(\d+)\s+and\s+a\s+half"#, in: out, with: "$1.5")
        out = replace(#"(\d+)\.(\d{2})\b"#, in: out, with: "$1:$2")
        out = out.replacingOccurrences(of: "–", with: "-")
        return out
    }

    // MARK: - parseRepDist

    /// Extract `NxM` (reps x distance) from a line, or a bare known
    /// distance (returns reps=1, distance=N). Mirrors engine.ts
    /// `parseRepDist()`.
    private static func parseRepDist(_ raw: String) -> (reps: Int?, distance: Int?) {
        let n = normalize(raw)
        if let g = matchGroups(#"(\d+)\s*[x×]\s*(\d+)"#, in: n), g.count >= 3,
           let a = Int(g[1]), let b = Int(g[2]) {
            if knownDistances.contains(b) { return (a, b) }
            if knownDistances.contains(a) { return (b, a) }
            return (min(a, b), max(a, b))
        }
        if let g = matchGroups(#"^(\d+)\b"#, in: n), g.count >= 2,
           let d = Int(g[1]), knownDistances.contains(d) {
            return (1, d)
        }
        return (nil, nil)
    }

    // MARK: - parseStroke

    private static let strokePatterns: [(String, String)] = [
        (#"\b(?:freestyle|free|crawl|front\s*crawl)\b"#, "Free"),
        (#"\b(?:backstroke|back)\b"#, "Back"),
        (#"\b(?:breaststroke|breast)\b"#, "Breast"),
        (#"\b(?:butterfly|fly|butter)\b"#, "Fly"),
        (#"\b(?:i\.?m\.?|individual\s+medley|medley)\b"#, "IM"),
        (#"\b(?:form|stroke\s+(?:work|set|drill))\b"#, "Form"),
        (#"\b(?:pull)\b"#, "Pull"),
        (#"\b(?:choice|free[\s-]?choice)\b"#, "Choice"),
    ]

    private static func parseStroke(_ text: String) -> String? {
        for (pattern, stroke) in strokePatterns {
            if firstMatch(pattern, in: text) != nil { return stroke }
        }
        return nil
    }

    // MARK: - parseInterval

    /// Pull out a `m:ss` interval string. Mirrors engine.ts `parseInterval()`.
    private static func parseInterval(_ text: String) -> String? {
        let n = normalize(text)
        if let g = matchGroups(#"(?:on\s+)?(\d+):(\d{2})(?:\s+(?:interval|rest|i/?)?)?"#, in: n), g.count >= 3 {
            return "\(g[1]):\(g[2])"
        }
        if let g = matchGroups(#"on\s+(\d+)\s*min(?:ute)?s?\s+(\d+)"#, in: n), g.count >= 3 {
            return "\(g[1]):\(pad(g[2]))"
        }
        if let g = matchGroups(#"on\s+(\d+\.5)\s*min(?:ute)?s?"#, in: n), g.count >= 2,
           let total = Double(g[1]) {
            let minutes = Int(total)
            let seconds = Int((total - Double(minutes)) * 60.0)
            return "\(minutes):\(pad(String(seconds)))"
        }
        if let g = matchGroups(#"on\s+(\d+)\s*min(?:ute)?s?(?:\s|$)"#, in: n), g.count >= 2 {
            return "\(g[1]):00"
        }
        if let g = matchGroups(#"on\s+(\d+)\s*s(?:ec(?:ond)?s?)?(?:\s|$)"#, in: n), g.count >= 2,
           let s = Int(g[1]) {
            return "\(s / 60):\(pad(String(s % 60)))"
        }
        return nil
    }

    // MARK: - parseIntensity

    /// Return the first matching intensity. Mirrors engine.ts `parseIntensity()`.
    private static func parseIntensity(_ text: String) -> ParsedIntensity? {
        let n = normalize(text)

        // percent_range: "70-80%" or "~70-80%"
        if let g = matchGroups(#"(~?)(\d+)\s*[-–]\s*(\d+)\s*%"#, in: n), g.count >= 4 {
            let low = Int(g[2]) ?? 0
            let high = Int(g[3]) ?? 0
            let approx = (g[1] == "~")
            let label = "\(low)-\(high)%"
            if approx {
                return ParsedIntensity(type: .percent_range, label: label,
                                       percentLow: low - 5,
                                       percentHigh: high + 5)
            }
            return ParsedIntensity(type: .percent_range, label: label,
                                   percentLow: low,
                                   percentHigh: high)
        }

        // bare percent: "70%" or "~70%"
        if let g = matchGroups(#"(~?)(\d+)\s*%"#, in: n), g.count >= 3 {
            let v = Int(g[2]) ?? 0
            return ParsedIntensity(type: .percent_range,
                                   label: "\(v)%",
                                   percentLow: v - 5,
                                   percentHigh: v + 5)
        }

        // pace_target: "at 100 pace" or "on 50 effort"
        if let g = matchGroups(#"(?:at|on|@)\s*(\d+)\s*m?\s*(?:pace|effort)"#, in: n), g.count >= 2,
           let d = Int(g[1]), knownDistances.contains(d) {
            return ParsedIntensity(type: .pace_target, label: "\(d) pace",
                                   paceDistance: d)
        }

        // descend
        if firstMatch(#"\bdesc(?:end(?:ing)?)?\b"#, in: n) != nil {
            return ParsedIntensity(type: .descend, label: "descend")
        }

        // negative_split
        if firstMatch(#"\bneg(?:ative)?\s*split\b"#, in: text) != nil {
            return ParsedIntensity(type: .negative_split, label: "negative split")
        }

        // build
        if firstMatch(#"\bbuild(?:ing)?\b"#, in: text) != nil {
            return ParsedIntensity(type: .build, label: "build")
        }

        // sprint
        if firstMatch(#"\b(?:sprint|all[\s-]?out|max(?:\s+effort)?|blast|fast|atp)\b"#, in: text) != nil {
            return ParsedIntensity(type: .sprint, label: "ATP")
        }

        // race_pace
        if firstMatch(#"\b(?:race(?:\s+pace)?|r\.?p\.?)\b"#, in: text) != nil {
            return ParsedIntensity(type: .race_pace, label: "race pace")
        }

        // threshold
        if firstMatch(#"\b(?:threshold|css|critical\s+swim\s+speed|t[\s-]?pace)\b"#, in: text) != nil {
            return ParsedIntensity(type: .threshold, label: "threshold")
        }

        // aerobic — preserve original word label
        if let g = matchGroups(#"\b(aerobic|steady|cruise|moderate|hard|maximum|vo2)\b"#, in: text), g.count >= 2 {
            return ParsedIntensity(type: .aerobic, label: g[1].lowercased())
        }

        // easy — preserve original word (EZ, recovery, etc.)
        // engine.ts intentionally has two near-identical easy blocks
        // (one with the "loossen" typo, one with "loosen"). Both fire
        // and produce the same result; we mirror that here.
        if let g = matchGroups(#"\b(easy|recovery|recover|warm[\s-]?up|loossen|ez|hard|maximum)\b"#, in: text), g.count >= 2 {
            return ParsedIntensity(type: .easy, label: g[1].lowercased())
        }
        if let g = matchGroups(#"\b(easy|recovery|recover|warm[\s-]?up|loosen|ez)\b"#, in: text), g.count >= 2 {
            return ParsedIntensity(type: .easy, label: g[1].lowercased())
        }

        return nil
    }

    // MARK: - parsePacing

    /// "build/smooth/strong/moderate" pacing word. Mirrors engine.ts
    /// `extractPacing()`. "moderate" is also an intensity keyword —
    /// engine.ts prefers intensity over pacing when both match, so we
    /// fall through to intensity in that case.
    private static func parsePacing(_ text: String) -> String? {
        guard let g = matchGroups(#"\b(build|smooth|strong|moderate)\b"#, in: text), g.count >= 2 else {
            return nil
        }
        if parseIntensity(text) == nil {
            return g[1].lowercased()
        }
        return nil
    }

    // MARK: - parseGear

    private static let gearPatterns: [(String, String)] = [
        (#"\bfins\b"#, "fins"),
        (#"\bflippers\b"#, "fins"),
        (#"\bpaddles?\b"#, "paddles"),
        (#"\bpull[\s-]?buoy\b"#, "pull_buoy"),
        (#"\bbuoy\b(?!\s*rate)"#, "pull_buoy"),
        (#"\bkickboard\b"#, "kickboard"),
        (#"\bkick\s*board\b"#, "kickboard"),
        (#"\bdrag\s*suit\b"#, "dragSuit"),
    ]

    private static func parseGear(_ text: String) -> [String]? {
        var detected: [String] = []
        for (pattern, gear) in gearPatterns {
            if firstMatch(pattern, in: text) != nil && !detected.contains(gear) {
                detected.append(gear)
            }
        }
        return detected.isEmpty ? nil : detected
    }

    private static func isOptional(_ text: String) -> Bool {
        return firstMatch(#"\boptional\b"#, in: text) != nil
    }

    // MARK: - Constants

    private static let knownDistances: Set<Int> = [
        15, 25, 50, 75, 100, 125, 150, 200, 300, 400, 500, 600, 800, 1000, 1500, 1650,
    ]

    private static let wordNumbers: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
        "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
        "twenty": 20,
    ]

    // MARK: - Regex helpers

    private static func replace(_ pattern: String, in text: String, with replacement: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return re.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, options: [], range: range),
              let r = Range(m.range, in: text) else { return nil }
        return String(text[r])
    }

    private static func matchGroups(_ pattern: String, in text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, options: [], range: range) else { return nil }
        var groups: [String] = []
        for i in 0..<m.numberOfRanges {
            if let r = Range(m.range(at: i), in: text) {
                groups.append(String(text[r]))
            } else {
                groups.append("")
            }
        }
        return groups
    }

    private static func pad(_ s: String) -> String {
        return s.count >= 2 ? s : "0" + s
    }
}