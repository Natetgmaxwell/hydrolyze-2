import Foundation

/// RPEParser — parses RPE strings ("RPE6-7", "RPE10", "RPE6") into
/// numeric ranges. Also detects ambiguous terms ("moderate",
/// "hard", "easy", etc.) in a workout description and looks up
/// the coach's vocabulary.
///
/// PHASE 2.6 v1.14.0: introduced per the user's RPE direction
/// (2026-06-16). The parser is the single function that asks
/// "what's this ambiguous term mean for this coach?" — it's the
/// entry point for the `SessionStartView` parser sheet.
struct RPEParser {
    /// A numeric RPE range. Avoid `Range<Int>` because Foundation's
    /// `NSRange` shadows the type name in many contexts — using
    /// a named tuple keeps the parse unambiguous.
    typealias RPERange = (low: Int, high: Int)

    /// Parse an RPE string into a numeric range.
    ///
    /// Examples:
    ///   "RPE6-7"  → (low: 6, high: 7)
    ///   "RPE10"   → (low: 10, high: 10)
    ///   "RPE6"    → (low: 6, high: 6)
    ///   "moderate" → falls back to the legacy table → (low: 6, high: 7)
    ///   "max"     → falls back to the legacy table → (low: 10, high: 10)
    ///   nil       → unrecognized string
    ///
    /// Single values parse to a degenerate range (n, n). The 5-way
    /// match uses range OVERLAP, so "RPE6-7" matches "RPE7" (the 7
    /// overlaps) and "RPE6-7" matches "RPE6" (the 6 overlaps).
    static func parse(_ rpe: String?) -> RPERange? {
        guard let rpe = rpe else { return nil }
        let trimmed = rpe.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // New RPE syntax: "RPE6-7" or "RPE10"
        if trimmed.hasPrefix("RPE") {
            let numbersPart = trimmed.dropFirst(3)
            return parseRangeString(String(numbersPart))
        }

        // Legacy terms (v1.13 and earlier). Map to RPE ranges.
        return legacyFallback(trimmed.lowercased())
    }

    /// Parse "6-7" or "10" into a range. Returns nil if malformed.
    private static func parseRangeString(_ s: String) -> RPERange? {
        if s.contains("-"), let dashIdx = s.firstIndex(of: "-") {
            let lowStr = String(s[..<dashIdx])
            let highStr = String(s[s.index(after: dashIdx)...])
            guard let low = Int(lowStr), let high = Int(highStr),
                  low >= 1, low <= 10, high >= 1, high <= 10,
                  low <= high
            else { return nil }
            return (low: low, high: high)
        }
        if let n = Int(s), n >= 1, n <= 10 {
            return (low: n, high: n)
        }
        return nil
    }

    /// Map legacy v1.13-era intensity values to RPE ranges. These
    /// are the canonical mappings the user proposed (RPE6-7 =
    /// zone 2 = moderate).
    ///
    /// PHASE 2.6 v1.14.1: added T-code (training zone) handling.
    /// T1-T5 are a swim-coaching convention (sometimes "Z1-Z5"
    /// or "UT1-UT5"). The user types "T2" / "T4" in the workout
    /// parser; the engine maps to RPE. The T-code ↔ RPE mapping
    /// is the standard swim-coaching equivalence:
    ///   T1 / Z1 = recovery = RPE4-5
    ///   T2 / Z2 = aerobic = RPE6-7
    ///   T3 / Z3 = tempo = RPE7-8
    ///   T4 / Z4 = threshold = RPE8-9
    ///   T5 / Z5 = VO2 max = RPE10
    /// Also handles "Z2", "Z3", "UT2", "EN3" (EN = endurance) etc.
    private static func legacyFallback(_ term: String) -> RPERange? {
        // T-codes and Z-codes (training zones). Most common first.
        switch term {
        case "t1", "z1", "ut1", "en1":
            return (low: 4, high: 5)
        case "t2", "z2", "ut2", "en2":
            return (low: 6, high: 7)
        case "t3", "z3", "ut3", "en3":
            return (low: 7, high: 8)
        case "t4", "z4", "ut4", "en4":
            return (low: 8, high: 9)
        case "t5", "z5", "ut5", "en5":
            return (low: 10, high: 10)
        // v1.13-era legacy terms (still supported for back-compat)
        case "max", "sprint", "all-out":
            return (low: 10, high: 10)
        case "threshold", "hard", "tempo":
            return (low: 8, high: 9)
        case "moderate", "cruise":
            return (low: 6, high: 7)
        case "easy", "recovery":
            return (low: 4, high: 5)
        default:
            return nil
        }
    }

    /// Format a numeric range back to RPE syntax. Used by the UI
    /// to display the resolved RPE inline.
    static func format(_ range: RPERange) -> String {
        if range.low == range.high {
            return "RPE\(range.low)"
        }
        return "RPE\(range.low)-\(range.high)"
    }

    /// Detect ambiguous terms in a workout description. Returns
    /// the list of ambiguous terms found, in order. The parser
    /// caller looks up each in the coach's vocabulary and either
    /// uses the RPE silently (if mapped) or prompts (if not).
    ///
    /// Ambiguous terms are the natural-language words coaches use
    /// to describe effort. Hard-coded for v1.14.0; could become
    /// data-driven in v2 (a `ambiguous_terms` table with a per-coach
    /// allowlist).
    ///
    /// PHASE 2.6 v1.14.1: added T-codes (T1-T5) and Z-codes (Z1-Z5)
    /// to the ambiguous set. T-codes are training zones, common in
    /// swim coaching (the user types "T2" / "T4" in the workout
    /// parser). The coach's vocabulary can still override the
    /// default mapping (e.g., "T2 → RPE7-8" for a harder team).
    static let ambiguousTerms: Set<String> = [
        "easy", "recovery", "moderate", "cruise", "tempo",
        "hard", "threshold", "sprint", "all-out", "max",
        "light", "heavy", "fast", "slow", "push", "tough",
        "race", "race-pace",
        "t1", "t2", "t3", "t4", "t5",
        "z1", "z2", "z3", "z4", "z5",
        "ut1", "ut2", "ut3", "ut4", "ut5",
        "en1", "en2", "en3", "en4", "en5"
    ]

    /// Find all ambiguous terms in a workout description. Case-
    /// insensitive. Returns lowercase terms.
    static func findAmbiguousTerms(in description: String) -> [String] {
        let lowered = description.lowercased()
        let tokens = lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        var found: [String] = []
        for token in tokens {
            let str = String(token)
            if ambiguousTerms.contains(str) {
                if !found.contains(str) {
                    found.append(str)
                }
            }
        }
        return found
    }

    /// Check if two RPE ranges overlap. Used by PBService for the
    /// 5-way match's Tier 1.5 (range overlap).
    static func overlaps(_ a: RPERange, _ b: RPERange) -> Bool {
        return a.low <= b.high && b.low <= a.high
    }
}
