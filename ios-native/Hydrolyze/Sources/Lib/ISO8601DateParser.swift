import Foundation

/// ISO8601DateParser — robust ISO8601 date parser for timestamps
/// from PostgreSQL / Supabase / Python isoformat().
///
/// WHY THIS EXISTS
/// The default iOS `ISO8601DateFormatter` only accepts the `Z`
/// suffix (UTC zulu), not `+00:00` or `+0000` (the forms Python's
/// `datetime.isoformat()` and PostgreSQL's `to_char(timestamptz)`
/// produce). The seeder's `created_at` is a Python isoformat
/// string like `"2026-06-18T08:01:38.318857+00"`, which iOS
/// can't parse with the default formatter. The result: dates
/// silently fail to parse, the trend-window filter drops every
/// row, and views like "Last 5 Times" show "No recent times"
/// even though the data is in the chart.
///
/// USAGE
///   let date = ISO8601DateParser.parse("2026-06-18T08:01:38.318857+00")
///   // -> 2026-06-18 08:01:38 UTC
///
/// Tries 3 forms in order:
///   1. ISO8601DateFormatter (the default, handles `Z`)
///   2. ISO8601DateFormatter with `[.withFractionalSeconds]`
///      (handles `.318857` and `Z`)
///   3. Manual string replacement `+00:00` -> `Z` and `+0000` -> `Z`
///      then re-try form 1 and 2
enum ISO8601DateParser {
    /// Parse an ISO8601 date string. Returns nil if the string
    /// can't be parsed in any of the supported forms. The fallback
    /// for callers is to treat nil as "keep the row" (don't
    /// silently drop data on a parse error).
    static func parse(_ string: String) -> Date? {
        // Form 1: default ISO8601 (Z suffix only)
        if let d = defaultFormatter.date(from: string) {
            return d
        }
        // Form 2: with fractional seconds
        if let d = fractionalFormatter.date(from: string) {
            return d
        }
        // Form 3: replace +00:00 / +0000 with Z, retry
        let normalized = string
            .replacingOccurrences(of: "+00:00", with: "Z")
            .replacingOccurrences(of: "+0000", with: "Z")
        if let d = defaultFormatter.date(from: normalized) {
            return d
        }
        if let d = fractionalFormatter.date(from: normalized) {
            return d
        }
        return nil
    }

    private static let defaultFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
