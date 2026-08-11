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
        let inlineNote = extractInlineNote(line)
        let text = inlineNote.cleaned
        let rd = parseRepDist(text)
        if rd.reps == nil && rd.distance == nil { return nil }

        let preAsText: String
        if let asRange = text.range(of: #"\bas[\s:]"#, options: .regularExpression) {
            preAsText = String(text[..<asRange.lowerBound])
        } else {
            preAsText = text
        }
        let stroke = parseStroke(preAsText)
        let interval = parseInterval(text)
        let intensity = parseIntensity(text)
        let pacing = parsePacing(text)
        let gear = parseGear(text)
        let gearOptional = gear != nil && isOptional(text)

        let asRegex = try! NSRegularExpression(pattern: #"\bas[\s:]+(.+)$"#, options: [.caseInsensitive])
        let textRange = NSRange(text.startIndex..., in: text)
        let asMatch = asRegex.firstMatch(in: text, options: [], range: textRange)
        var pattern: [ParsedRep] = []
        var patternType: String?
        var parsedIntensity = intensity
        if let asMatch,
           let asTextRange = Range(asMatch.range(at: 1), in: text) {
            pattern = parseSubReps(String(text[asTextRange]))
            parsedIntensity = parseIntensity(preAsText)
            if !pattern.isEmpty {
                patternType = "simple"
            }
        }

        let rotationMatch = ROTATION_RE.firstMatch(in: text, options: [], range: textRange)
        if asMatch == nil, let rotationMatch,
           let rotationRange = Range(rotationMatch.range, in: text) {
            let rot = String(text[rotationRange]).uppercased()
            let strokeMap: [Character: String] = ["F": "Free", "B": "Back", "K": "Breast", "R": "Fly", "I": "IM", "M": "IM"]
            var subReps: [ParsedRep] = []
            for ch in rot {
                if let rotationStroke = strokeMap[ch] {
                    subReps.append(.simple(ParsedSimpleRep(type: "simple", meters: rd.distance ?? 0, stroke: rotationStroke, note: nil, intensity: nil, pacing: nil)))
                }
            }
            if !subReps.isEmpty {
                pattern = subReps
                patternType = "simple"
            }
        }

        return ParsedRepGroup(
            reps: rd.reps,
            distance: rd.distance,
            stroke: stroke,
            interval: interval,
            intensity: parsedIntensity,
            pacing: pacing,
            // ponytail (2026-08-01): pattern and gearOptional are now optional
            // in the Codable type after the LLM-swap changes. Pass them as
            // values directly — the memberwise init accepts optionals.
            pattern: pattern.isEmpty ? nil : pattern,
            patternType: patternType,
            connectors: nil,
            note: inlineNote.note,
            gear: gear,
            gearOptional: gearOptional,
            descend: nil,
            details: nil
        )
    }

    private static func extractInlineNote(_ text: String) -> (cleaned: String, note: String?) {
        let textRange = NSRange(text.startIndex..., in: text)
        let parentheticalRegex = try! NSRegularExpression(pattern: #"^(.+?)\s*\(([^)]+)\)\s*$"#)
        if let match = parentheticalRegex.firstMatch(in: text, options: [], range: textRange),
           let cleanedRange = Range(match.range(at: 1), in: text),
           let noteRange = Range(match.range(at: 2), in: text) {
            return (String(text[cleanedRange]).trimmingCharacters(in: .whitespaces), String(text[noteRange]).trimmingCharacters(in: .whitespaces))
        }

        let trailingRegex = try! NSRegularExpression(pattern: #"\b(?:fast\s+for\s+time|for\s+time|send[\s-]+off|(?:on[\s:]+(\d+:\d+)\s*)?race\s*pace|build\s+to\s+(?:fast|sprint|max)|negative\s+split(?:\s+1st\s+half\s+faster)?|hold[\s-]+best[\s-]+average|strong\s+finish|no\s+breath(?:ing)?)\b[\s.,;:@\d]*(?:\s*@?\s*\d+:\d+(?:\.\d+)?)?\s*$"#, options: [.caseInsensitive])
        let trailingRange = trailingRegex.rangeOfFirstMatch(in: text, options: [], range: textRange)
        guard trailingRange.location != NSNotFound else {
            return (text, nil)
        }

        let trailingText = (text as NSString).substring(with: trailingRange)
        var capturedInterval: String?
        let capturedRange = trailingRange.length > 0 ? trailingRegex.firstMatch(in: text, options: [], range: textRange)?.range(at: 1) : nil
        if let capturedRange,
           capturedRange.location != NSNotFound {
            capturedInterval = (text as NSString).substring(with: capturedRange)
        }

        let trailingEndRegex = try! NSRegularExpression(pattern: #"\s*@?\s*(\d+:\d+(?:\.\d+)?)\s*$"#)
        let trailingTextRange = NSRange(trailingText.startIndex..., in: trailingText)
        var noteText = trailingEndRegex.stringByReplacingMatches(in: trailingText, options: [], range: trailingTextRange, withTemplate: "")
        let intervalInTrailing: String?
        if let capturedInterval {
            noteText = noteText.replacingOccurrences(of: capturedInterval, with: "")
            noteText = noteText.replacingOccurrences(of: #"^on\s+"#, with: "", options: .regularExpression)
            intervalInTrailing = capturedInterval
        } else {
            noteText = noteText.replacingOccurrences(of: #"^on\s+"#, with: "", options: .regularExpression)
            if let intervalMatch = trailingEndRegex.firstMatch(in: trailingText, options: [], range: trailingTextRange),
               let intervalRange = Range(intervalMatch.range(at: 1), in: trailingText) {
                intervalInTrailing = String(trailingText[intervalRange])
            } else {
                intervalInTrailing = nil
            }
        }

        noteText = noteText.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        let intervalSuffix = intervalInTrailing.map { " @ \($0)" } ?? ""
        let prefixRange = NSRange(location: 0, length: trailingRange.location)
        let prefix = (text as NSString).substring(with: prefixRange).trimmingCharacters(in: .whitespaces)
        let cleaned = (prefix + intervalSuffix).trimmingCharacters(in: .whitespaces)
        return (cleaned, noteText.isEmpty ? nil : noteText)
    }

    private static func parseSubReps(_ text: String) -> [ParsedRep] {
        let asNotationRegex = try! NSRegularExpression(pattern: #"^(\d+)\.\s*(\S+(?:\s+\S+)?)(?:/(?:swim|s))?"#, options: [.caseInsensitive])
        let textRange = NSRange(text.startIndex..., in: text)
        guard let match = asNotationRegex.firstMatch(in: text, options: [], range: textRange),
              let strokeRange = Range(match.range(at: 2), in: text),
              let stroke = parseStroke(String(text[strokeRange])) else {
            return []
        }

        var subReps: [ParsedRep] = [
            .simple(ParsedSimpleRep(type: "simple", meters: 0, stroke: stroke, note: nil, intensity: nil, pacing: nil))
        ]
        let restLocation = match.range.location + match.range.length
        let restRange = NSRange(location: restLocation, length: text.utf16.count - restLocation)
        let moreRegex = try! NSRegularExpression(pattern: #"(\d+)\.\s*(\S+(?:\s+\S+)?)(?:/(?:swim|s))?"#, options: [.caseInsensitive])
        for moreMatch in moreRegex.matches(in: text, options: [], range: restRange) {
            guard let strokeRange = Range(moreMatch.range(at: 2), in: text),
                  let stroke = parseStroke(String(text[strokeRange])) else {
                continue
            }
            subReps.append(.simple(ParsedSimpleRep(type: "simple", meters: 0, stroke: stroke, note: nil, intensity: nil, pacing: nil)))
        }
        return subReps
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
        (#"\b(?:freestyle|free|crawl|front\s*crawl|fists?|catch[\s-]?up|swim)\b"#, "Free"),
        (#"\b(?:backstroke|back)\b"#, "Back"),
        (#"\b(?:breaststroke|breast)\b"#, "Breast"),
        (#"\b(?:butterfly|fly|butter)\b"#, "Fly"),
        (#"\b(?:i\.?m\.?|individual\s+medley|medley)\b"#, "IM"),
        (#"\b(?:form|stroke\s+(?:work|set|drill))\b"#, "Form"),
        (#"\b(?:pull)\b"#, "Pull"),
        (#"\b(?:kick|kick\s+drill|flutter\s+kick|flutter|dolphin\s+kick)\b"#, "Kick"),
        (#"\b(?:drill)\b"#, "Drill"),
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

    private static let ROTATION_RE = try! NSRegularExpression(pattern: #"\b[FBKR]{2,}\b"#)

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