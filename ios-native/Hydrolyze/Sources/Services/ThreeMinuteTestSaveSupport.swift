import Foundation

/// ThreeMinuteTestSaveSupport — pure helpers for the V0.38 Slice 4
/// 3MT save flow. Lives in its own file (no UIKit, no @MainActor, no
/// Supabase) so the orchestrator-Mac CLI runner
/// (`build_and_run_3mtsave.sh`) can compile it standalone and
/// regression-gate the trial-number math, split grouping, analyzer
/// wiring, and row assembly without a booted simulator.
///
/// The save flow in `TimingViewModel.save(...)` calls into these
/// helpers after the existing pairing engine finishes. The CLI test
/// exercises the same code paths against synthetic `LapAssignment`s
/// and per-swimmer split groups — the production code, not a copy.
///
/// Spec: V0.38_SPEC.md §Slice 4. Constraint: per-set intensity_type
/// ("3mt") is the source of truth for the 3MT gate; trial_number
/// increments per (swimmer, workout) row in swimmer_test_profiles.

/// Per-swimmer, pool-side row to insert into `swimmer_test_profiles`.
/// The shape mirrors the columns from
/// `supabase/migrations/20260815120000_3mt_mode.sql`; field names are
/// `snake_case` to match the Postgres wire format (the supabase-swift
/// SDK doesn't auto-translate camelCase).
struct TestProfileRow: Encodable, Equatable, Sendable {
    let id: String
    let swimmer_id: String
    let session_id: String?
    let workout_set_id: String?
    let stroke: String
    let pool_length: Int
    let test_date: String
    let trial_number: Int
    let peak_speed_mps: Double
    let critical_speed_mps: Double
    let battery_m: Double
    let quality_flags: [String]
}

/// Group the pairing engine's per-lap `LapAssignment`s into per-swimmer
/// ordered split sequences. The pairing engine emits one
/// `LapAssignment` per LAP touch (not per swimmer); the 3MT analyzer
/// needs one `[Lap]` per swimmer with the splits in tap-time order.
/// Sort key is `lap.lapNumber` (the 1-indexed tap order recorded on
/// the stopwatch) — the assignment ordering itself is not guaranteed
/// monotonic across swimmers.
///
/// - Parameter assignments: the `PairingResult.assignments` from
///   `PairingEngine.pair(...)`. Laps with `confidence == 0`
///   (false-start guard) and dummy-lap columns are filtered out
///   upstream — this helper takes whatever the engine produced.
/// - Returns: `[swimmerId.uuidString: [Lap]]` with each value's laps
///   sorted by `lapNumber`. Swimmers with no assignments simply don't
///   appear in the dictionary.
func groupSplitsPerSwimmer(
    assignments: [LapAssignment]
) -> [String: [Lap]] {
    var groups: [String: [Lap]] = [:]
    for a in assignments {
        let sid = a.swimmerId.uuidString
        groups[sid, default: []].append(a.lap)
    }
    for sid in groups.keys {
        groups[sid]?.sort { $0.lapNumber < $1.lapNumber }
    }
    return groups
}

/// Assemble the `swimmer_test_profiles` rows to insert for a 3MT
/// session. Pure function (no DB, no async, no @MainActor): the CLI
/// test exercises this directly against the real
/// `ThreeMinuteTestAnalyzer`. The save flow calls it with the
/// pre-fetched `existingMaxTrialBySwimmer` map and the analyzer
/// result falls out the other end as a typed row ready for the
/// supabase insert.
///
/// - Parameters:
///   - swimmerAssignments: per-swimmer 25m splits in tap order (from
///     `groupSplitsPerSwimmer(_:)`).
///   - existingMaxTrialBySwimmer: pre-fetched
///     `max(trial_number) FROM swimmer_test_profiles WHERE
///     swimmer_id = $1 [AND workout_set_id = $2]`. Empty dict means
///     "first trial for everyone" → trial_number = 1. The save flow
///     fetches this in one round trip before the pairing engine runs
///     so the analyzer can be invoked with the correct `trialNumber`
///     (which controls the `.learningTrial` quality flag).
///   - workoutSetId: the 3MT set's `workout_sets.id`. Persisted so
///     future review surfaces can join `swimmer_test_profiles` back
///     to the originating set. nil if the flow has no workout set
///     context.
///   - sessionId: the live session's id. nil if the save is running
///     outside an active session (CLI tests, future single-swimmer
///     3MT path).
///   - stroke: the set's stroke ("Free" / "Back" / ...). Default
///     "Free" matches the migration's default.
///   - poolLengthMeters: the pool's split distance. 25 for a 25m
///     pool, 50 for a 50m pool — passed through to the analyzer and
///     the row.
///   - testDate: wall-clock for `test_date`. Defaults to `now()` for
///     the production path; the CLI test pins a fixed date so the
///     ISO8601 round-trip is deterministic.
/// - Returns: one `TestProfileRow` per swimmer with
///   `laps.count >= 3` (the analyzer's data threshold). Swimmers
///   with too few splits are silently skipped — the pairing engine's
///   `confidence == 0` already flagged them as ghost taps in the
///   review surface; persisting a half-formed profile would pollute
///   the trend line.
func assembleTestProfiles(
    swimmerAssignments: [String: [Lap]],
    workoutSetId: String?,
    sessionId: String?,
    stroke: String,
    poolLengthMeters: Int,
    existingMaxTrialBySwimmer: [String: Int],
    testDate: Date = Date()
) -> [TestProfileRow] {
    let isoFmt = ISO8601DateFormatter()
    let isoString = isoFmt.string(from: testDate)
    var rows: [TestProfileRow] = []
    for (swimmerId, laps) in swimmerAssignments {
        // V0.38 Slice 4 (2026-08-16): trial number = existing max + 1.
        // `existingMaxTrialBySwimmer[swimmerId] ?? 0` makes the
        // "first trial for this swimmer" case land on 1 (the
        // migration's default), matching the DB's DEFAULT 1.
        let existingMax = existingMaxTrialBySwimmer[swimmerId] ?? 0
        let trialNumber = existingMax + 1
        guard let result = ThreeMinuteTestAnalyzer.analyze(
            laps: laps,
            poolLengthMeters: poolLengthMeters,
            trialNumber: trialNumber
        ) else {
            continue
        }
        rows.append(TestProfileRow(
            id: UUID().uuidString,
            swimmer_id: swimmerId,
            session_id: sessionId,
            workout_set_id: workoutSetId,
            stroke: stroke,
            pool_length: poolLengthMeters,
            test_date: isoString,
            trial_number: trialNumber,
            peak_speed_mps: result.peakSpeedMps,
            critical_speed_mps: result.criticalSpeedMps,
            battery_m: result.batteryMeters,
            quality_flags: result.qualityFlags.map { $0.rawValue }
        ))
    }
    return rows
}