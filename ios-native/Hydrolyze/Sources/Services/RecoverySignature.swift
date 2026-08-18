import Foundation

/// RecoverySignature — V0.42 Slice 1 (2026-08-18) — pure aggregation
/// over `set_rest_events` rows. Lives in its own file (no UIKit, no
/// Supabase, no Combine, no async) so the orchestrator-Mac CLI
/// runner (`build_and_run_recoverysignature.sh`) can compile it
/// standalone and regression-gate the median-at-first-strike math,
/// the revert rate, the weekly bucketing, the coach copy, the
/// revert-flag threshold, and the rep-count approximation without
/// a booted simulator or UIKit.
///
/// Spec: V0.42_SPEC.md §Slice 1 + §Slice 3. The service layer in
/// `RecoveryService.swift` decodes the Supabase response into
/// `[RestEventRecord]` (1:1 with the `set_rest_events` columns) and
/// then runs the aggregator functions here. The view layer reads
/// `RecoverySignature` + `[WeeklyStrainPoint]` through
/// `SwimmerDetailViewModel`.

/// V0.42 Slice 1 (2026-08-18): wire shape of one `set_rest_events`
/// row, mirroring the migration
/// `supabase/migrations/20260818130000_drop_rule_rest_events.sql`
/// (with the V0.39 Slice 4 follow-up making `session_id` nullable).
///
/// Fields are `snake_case` to match the Postgres wire format — the
/// supabase-swift SDK does not auto-translate camelCase, so the
/// `Codable` mapping is the 1:1 lift (same convention as
/// `RestEventRow` in `RestCountdownModel.swift`).
///
/// A row is a `.strike` when `reverted == false` (the engine
/// extended the rest); a row is a `.revert` when `reverted == true`
/// (the coach disagreed; the rest was reverted but the event is
/// recorded so the flywheel learns). Both kinds live in the same
/// table — the `reverted` flag is the discriminator.
struct RestEventRecord: Codable, Equatable, Sendable {
    let id: String
    let session_id: String?
    let workout_set_id: String?
    let swimmer_id: String
    let rep_index: Int
    let rep_time_ms: Int
    let standard_ms: Int
    let base_rest_sec: Int
    let extended_rest_sec: Int
    let delta_sec: Int
    let strike_count: Int
    let standard_source: String
    let reverted: Bool
    let created_at: String
}

/// V0.42 Slice 1 (2026-08-18): per-swimmer aggregate the swimmer
/// detail view renders. `medianRepBeforeDrop` is nil when no strike
/// rows exist (the view hides the section). The revert rate is
/// `reverted / (strike + revert)`, 0 when the denominator is 0.
struct RecoverySignature: Equatable, Sendable {
    /// Median `rep_index` at the FIRST strike across anaerobic sets
    /// for this swimmer, in the look-back window. Nil when no strike
    /// rows exist — the view interprets nil as "section hidden".
    let medianRepBeforeDrop: Int?
    /// Total strike rows in the window (reverts excluded).
    let totalStrikes: Int
    /// Mean `delta_sec` across strike rows (30 for strike 1, 60 for
    /// strike 2+); 0 when `totalStrikes == 0`.
    let avgDeltaSec: Double
    /// Mean `extended_rest_sec` across strike rows (the rest the
    /// engine proposed); 0 when `totalStrikes == 0`.
    let avgExtendedRestSec: Double
    /// `reverted / (strike + revert)` over the window. 0 when the
    /// denominator is 0.
    let revertRate: Double
}

/// V0.42 Slice 1 (2026-08-18): one weekly bucket in the per-swimmer
/// trend. `weekStartISO` is the ISO-8601 string for the Monday of
/// that week (e.g. `"2025-08-11T00:00:00Z"`). `strikes` is the
/// count of strike rows in that week. `reps` is the sum, over the
/// anaerobic sets touched that week, of `max(rep_index)` per set
/// (see `RecoveryAggregator.weeklyTrend(...)` for why — the
/// `set_rest_events` table doesn't store every rep swum, so we
/// approximate by the maximum `rep_index` any strike row hit in
/// that set). `strikesPer100Reps = strikes * 100 / reps` (0 when
/// `reps == 0`); the view surfaces this on the sparkline.
struct WeeklyStrainPoint: Equatable, Sendable, Identifiable {
    let weekStartISO: String
    let strikes: Int
    let reps: Int
    let strikesPer100Reps: Double

    /// `Identifiable` id matches `weekStartISO` — buckets are unique
    /// by Monday so this is stable.
    var id: String { weekStartISO }
}

/// V0.42 Slice 1 (2026-08-18): pure static aggregation functions
/// over `[RestEventRecord]`. Kept as an `enum` (no instances) so
/// the namespace cannot be misused as a value type — every helper
/// here is a transformation, not state. Mirrors the
/// `RecoveryService` fetch shape 1:1 so the service layer just
/// fetches then calls these.
enum RecoveryAggregator {
    /// V0.42 Slice 1 (2026-08-18): per-swimmer signature. Empty
    /// input → zeroed signature with `medianRepBeforeDrop = nil`
    /// (the "data absent → hidden" contract — see
    /// `SwimmerDetailView.recoverySection`).
    static func signature(events: [RestEventRecord]) -> RecoverySignature {
        let strikeRows = events.filter { !$0.reverted }
        if strikeRows.isEmpty {
            return RecoverySignature(
                medianRepBeforeDrop: nil,
                totalStrikes: 0,
                avgDeltaSec: 0,
                avgExtendedRestSec: 0,
                revertRate: 0
            )
        }
        // Grouping key for the median: the set that produced the
        // strike trail — `session_id` (multi-swimmer session path)
        // or `workout_set_id` (single-swimmer path; session_id is
        // nil per the V0.39 Slice 4 follow-up migration). A set is
        // ONE drop-rule event trail; only the FIRST strike in it
        // counts toward the median (later strikes in the same set
        // are escalation, not a fresh "drop"). Falling back to the
        // row `id` is the defensive last resort (no set key at all)
        // — every row would be its own set, so the median would
        // degrade to "median rep_index across all strike rows".
        let firstStrikeBySet = firstStrikeRepIndexBySet(strikeRows: strikeRows)
        let median = median(Array(firstStrikeBySet.values))
        let totalStrikes = strikeRows.count
        let avgDelta = Double(strikeRows.map(\.delta_sec).reduce(0, +)) / Double(strikeRows.count)
        let avgExtended = Double(strikeRows.map(\.extended_rest_sec).reduce(0, +)) / Double(strikeRows.count)
        let revertCount = events.filter(\.reverted).count
        let rate: Double = events.isEmpty ? 0 : Double(revertCount) / Double(events.count)
        return RecoverySignature(
            medianRepBeforeDrop: median,
            totalStrikes: totalStrikes,
            avgDeltaSec: avgDelta,
            avgExtendedRestSec: avgExtended,
            revertRate: rate
        )
    }

    /// V0.42 Slice 1 (2026-08-18): per-swimmer weekly trend, ISO
    /// weeks starting on Monday. Returns one `WeeklyStrainPoint` per
    /// week that has at least one strike row (empty weeks are
    /// omitted — `hasEightWeeksOfData` in the VM gates the
    /// sparkline on `count >= 8`, so the swimmer needs 8 distinct
    /// weeks of data for the sparkline to render).
    ///
    /// `weeks` is the look-back window length in weeks; the
    /// caller (the VM) passes the same value (8) it used for the
    /// `since` cutoff in the Supabase query, so the window in the
    /// query and the window in the aggregation agree.
    ///
    /// `weeks` is not used to enforce a cutoff here — the caller
    /// already filtered events to the window in the fetch. It is
    /// accepted to keep the API symmetric with `RecoveryService`
    /// and to leave room for a future "always emit N weeks even
    /// when empty" change without breaking the signature.
    static func weeklyTrend(events: [RestEventRecord], weeks: Int = 8) -> [WeeklyStrainPoint] {
        let strikeRows = events.filter { !$0.reverted }
        guard !strikeRows.isEmpty else { return [] }

        // Group strike rows by their ISO week (Monday-start). Keyed
        // by the formatted Monday string so the bucket identity is
        // a stable string the view can sort + render.
        var strikesByWeek: [String: Int] = [:]
        var repsByWeek: [String: Int] = [:]
        // Per-week per-set max(rep_index) — the rep-count
        // approximation (see below). Keyed by (weekISO, setKey).
        var maxRepIndexBySetByWeek: [String: [String: Int]] = [:]

        for event in strikeRows {
            guard let date = parseISODate(event.created_at) else { continue }
            let weekISO = formatISODate(mondayOfISOWeek(of: date))
            let setKey = setKey(for: event)

            strikesByWeek[weekISO, default: 0] += 1
            var perSet = maxRepIndexBySetByWeek[weekISO] ?? [:]
            let prev = perSet[setKey] ?? 0
            perSet[setKey] = max(prev, event.rep_index)
            maxRepIndexBySetByWeek[weekISO] = perSet
        }

        // Sum per-set max(rep_index) per week → that week's reps.
        for (weekISO, perSet) in maxRepIndexBySetByWeek {
            repsByWeek[weekISO] = perSet.values.reduce(0, +)
        }

        return strikesByWeek.keys.sorted().map { weekISO in
            let strikes = strikesByWeek[weekISO] ?? 0
            let reps = repsByWeek[weekISO] ?? 0
            // 0 when reps == 0 — division-by-zero guard. A week with
            // strikes but no reps shouldn't happen (every strike row
            // has a rep_index), but the guard keeps the contract
            // explicit.
            let rate: Double = reps == 0 ? 0 : Double(strikes) * 100.0 / Double(reps)
            return WeeklyStrainPoint(
                weekStartISO: weekISO,
                strikes: strikes,
                reps: reps,
                strikesPer100Reps: rate
            )
        }
    }

    /// V0.42 Slice 1 (2026-08-18): revert rate over all event
    /// rows (strike + revert). 0 when the denominator is 0.
    /// Matches `signature(...).revertRate` exactly.
    static func revertRate(events: [RestEventRecord]) -> Double {
        if events.isEmpty { return 0 }
        let reverted = events.filter(\.reverted).count
        return Double(reverted) / Double(events.count)
    }

    /// V0.42 Slice 2 (2026-08-18): coach-facing one-line summary
    /// of the recovery signature. Nil when the signature has no
    /// median (data absent — the view hides the section).
    ///
    /// We commit to the REDUCED form
    /// `"Drops on rep \(median) of hard sets."` (no
    /// "— recovers in one rep" clause). The full clause is only
    /// justified when the typical strikes-per-set is 1 — a strike
    /// is followed by a standard-hit, not a second strike — and we
    /// can't reliably derive that from the rows we have (a strike
    /// row carries the swimmer's `rep_index` at strike time, not
    /// the next rep's outcome). Inventing a recovery claim the data
    /// doesn't support is exactly the spec's anti-pattern
    /// ("never silently extends" / "coach vocabulary, no statistical
    /// jargon"). The reduced form is honest.
    static func coachSignatureLine(_ s: RecoverySignature) -> String? {
        guard let median = s.medianRepBeforeDrop else { return nil }
        return "Drops on rep \(median) of hard sets."
    }

    /// V0.42 Slice 3 (2026-08-18): coach-facing flag when the
    /// coach reverts > 30% of this swimmer's extensions. Nil
    /// otherwise.
    ///
    /// The `> 0.30` threshold is a LOCKED decision (V0.42 spec
    /// §Decisions row 3 — 2026-08-18) — hard-coded here, not
    /// parameterized. The engine NEVER auto-adjusts standards; the
    /// flag is advisory only — one inline line in the coach UI.
    static func coachRevertFlag(_ rate: Double, firstName: String) -> String? {
        // Strict `>` (not `>=`) — the spec uses >30% as the
        // threshold, so rate == 0.30 is NOT flagged. Verified by
        // TEST 8 in the CLI runner.
        guard rate > 0.30 else { return nil }
        return "\(firstName)'s extensions are usually wrong — check the standard."
    }

    // MARK: - Helpers

    /// V0.42 Slice 1 (2026-08-18): for every strike row, find the
    /// minimum `rep_index` within its set — that is the FIRST
    /// strike in the set (later strikes are escalation within the
    /// same set, not a fresh "drop"). Returns `[setKey: firstRep]`.
    private static func firstStrikeRepIndexBySet(strikeRows: [RestEventRecord]) -> [String: Int] {
        var result: [String: Int] = [:]
        for row in strikeRows {
            let key = setKey(for: row)
            let prev = result[key] ?? Int.max
            result[key] = min(prev, row.rep_index)
        }
        return result
    }

    /// V0.42 Slice 1 (2026-08-18): the set identity for grouping.
    /// `session_id` (multi-swimmer session path) wins when present;
    /// otherwise `workout_set_id` (single-swimmer path, session_id
    /// is nil per the V0.39 Slice 4 follow-up migration). Defensive
    /// fallback to `id` so two unrelated rows never collide on the
    /// same key — every row would be its own set in that case
    /// (degrades the median, but never crashes).
    private static func setKey(for event: RestEventRecord) -> String {
        if let s = event.session_id, !s.isEmpty { return "sess:\(s)" }
        if let w = event.workout_set_id, !w.isEmpty { return "ws:\(w)" }
        return "row:\(event.id)"
    }

    /// Median of a non-empty integer array. Odd count → middle
    /// element; even count → average of the two middles, rounded
    /// to nearest integer (Swift's default `.rounded()` is
    /// round-half-to-even, which is the conventional statistics
    /// convention). Returns nil for empty input.
    private static func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let n = sorted.count
        if n % 2 == 1 {
            return sorted[n / 2]
        }
        let lower = Double(sorted[n / 2 - 1])
        let upper = Double(sorted[n / 2])
        return Int((lower + upper) / 2.0)
    }

    // MARK: - ISO-week date math (UTC, Monday-start)

    /// ISO 8601 calendar in UTC — Monday as first weekday, no DST
    /// surprises. Used for deterministic week bucketing across
    /// timezones (the orchestrator-Mac CLI runner must produce the
    /// same buckets regardless of the host's TZ).
    private static let isoCalendarUTC: Calendar = {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        cal.firstWeekday = 2  // Monday
        return cal
    }()

    /// Format a `Date` as ISO-8601 with `Z` suffix (the canonical
    /// `ISO8601DateFormatter` default with `.withInternetDateTime`).
    /// Stable across invocations — used as the `weekStartISO` key.
    private static func formatISODate(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    /// Parse a `created_at` ISO-8601 string from Postgres / Supabase.
    /// Accepts the `Z` suffix form (what the iOS save path writes
    /// via `ISO8601DateFormatter().string(from: Date())`). Returns
    /// nil for unparseable strings — the caller skips the row
    /// rather than silently mis-bucketing.
    private static func parseISODate(_ string: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        if let d = f.date(from: string) { return d }
        // Retry with fractional seconds — some Postgres forms emit
        // `2026-08-18T13:00:00.123+00` (Postgres `to_char` with
        // fractional). The CLI test fixtures use the non-fractional
        // form so this path is exercised in production only.
        let ff = ISO8601DateFormatter()
        ff.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        ff.timeZone = TimeZone(identifier: "UTC")
        return ff.date(from: string)
    }

    /// Monday (00:00 UTC) of the ISO week containing `date`.
    /// `Calendar(identifier: .iso8601)` with `.yearForWeekOfYear` +
    /// `.weekOfYear` + Monday-as-first-weekday reproduces the
    /// "week starts on Monday" bucketing regardless of host TZ
    /// (we pinned `timeZone = UTC` above).
    private static func mondayOfISOWeek(of date: Date) -> Date {
        let comps = isoCalendarUTC.dateComponents(
            [.yearForWeekOfYear, .weekOfYear],
            from: date
        )
        return isoCalendarUTC.date(from: comps) ?? date
    }
}