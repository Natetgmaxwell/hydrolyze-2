import Foundation

/// V0.49 Slice 1 (2026-08-22) — snapshot of the most-recent session
/// roster for a workout, returned by
/// `WorkoutService.fetchLatestSessionRoster(workoutId:)`. Used by
/// `WorkoutDetailViewModel` to cache whether the workout already has a
/// locked roster, so the per-fragment timing launcher can skip the
/// swimmer-picker sheet on a roster hit.
///
/// Carries enough state to drive the skip path:
///   - `sessionId`: the existing session to reuse. The timing flow
///     keys all writes (recorded_times, wave_assignments) off this id,
///     so reusing it preserves the cluster across multiple fragment
///     launches in the same workout.
///   - `entries`: the roster as (swimmerId, names, lane, positionInLane).
///     Names are populated so the eventual "roster strip" (Slice 2) can
///     render without a second DB round-trip.
///
/// Loaded via at most 2 round trips: one for the most-recent session id
/// (and its roster count), one for the joined swimmer names. Fail-open
/// to nil on any error — the caller falls back to today's picker.
struct SessionRosterSnapshot: Sendable {
    let sessionId: String
    let entries: [Entry]

    struct Entry: Sendable {
        let swimmerId: String
        let firstName: String?
        let lastName: String?
        let lane: Int?
        let positionInLane: Int?
    }
}