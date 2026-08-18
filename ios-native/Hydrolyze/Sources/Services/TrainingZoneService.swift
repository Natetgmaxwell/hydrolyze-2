import Foundation

// MARK: - PacePer100m

/// A per-100m pace for a single zone boundary. Carries both the
/// raw boundary speed (m/s, the source of truth) and the rendered
/// "m:ss/100m" string the coach reads on the 3MT panel and
/// swimmer detail.
///
/// `paceString` is nil iff the boundary m/s is non-finite or
/// non-positive — `thresholdPaceString` guards against these and
/// returns nil rather than rendering "0:00/100m" or "59:59/100m"
/// for nonsense input. In normal use, with a valid critical
/// speed, the boundaries are always finite and positive, so
/// `paceString` is always populated. The Optional is here for
/// type safety, not for the happy path.
struct PacePer100m: Equatable, Sendable {
    let mps: Double
    let paceString: String?
}

// MARK: - TrainingZones

/// The four per-100m zone boundaries derived from a 3MT critical
/// speed, in coach vocabulary. The properties are named after the
/// zone (`easy` / `steady` / `hard` / `sprint`) so the view code
/// reads naturally (`zones.steady.paceString`), and each value
/// carries both the m/s and the rendered pace string so the
/// downstream display surface can pick whichever it needs without
/// re-running the conversion.
///
/// `criticalSpeedMps` is the input that produced these zones —
/// the source of truth, surfaced for callers that need to show
/// the underlying reading alongside the derived paces.
///
/// `sourceTrialNumber` is the 3MT trial number these zones came
/// from. Trials 1–2 are familiarisation per Piatrikova 2019; the
/// resolver in V0.40 Slice 2 will gate the display on a usable
/// profile (trial ≥ 2, no learning flag), but the service itself
/// stays pure and just passes the trial number through.
struct TrainingZones: Equatable, Sendable {
    let easy: PacePer100m
    let steady: PacePer100m
    let hard: PacePer100m
    let sprint: PacePer100m
    let criticalSpeedMps: Double
    let sourceTrialNumber: Int
}

// MARK: - TrainingZoneService

/// TrainingZoneService — pure zone-derivation service for V0.40
/// Slice 1. Derives the four per-100m zone boundaries from a
/// critical-speed reading (m/s) plus the observed peak speed, in
/// coach vocabulary: **Easy / Steady / Hard / Sprint**.
///
/// Math (research doc §5.1, approved decisions table #1):
///   - Easy/Steady boundary  = 0.89 × CS
///   - Steady/Hard boundary  = 1.0  × CS (= CS itself)
///   - Hard/Sprint boundary  = 1.035 × CS
///   - Peak speed            = top of Sprint (observed)
///
/// When the observed peak is below 1.035×CS the swimmer has not
/// demonstrated a Sprint — peak is data, not a reason to invert
/// the pace order. Sprint is clamped to the boundary
/// (`max(peak, 1.035×CS)`), so the sprint pace string is never
/// slower than the hard pace string. When peak is nil / non-finite
/// / non-positive, sprint falls back to the boundary itself (no
/// infinity leak into the rendered pace string).
///
/// Paces are rendered via the existing `thresholdPaceString` from
/// `ThreeMTReviewSupport.swift` (m/s → "m:ss/100m"). The /100m
/// unit suffix is part of the coach-facing contract — without it,
/// "1:15" would be ambiguous against the 25m split pace the
/// coach reads on the same row.
///
/// Same pattern as `ThreeMinuteTestAnalyzer` / `WaveAllocator`:
/// pure function, no DB, no async, no SwiftUI, no Combine, no
/// Supabase. The view layer (Slice 3) is responsible for the
/// "is this profile usable?" gate; the service is the math.
struct TrainingZoneService {

    /// Easy/Steady boundary as a constant of critical speed.
    /// Research doc §5.1, Piatrikova 2019. // why: pinned by the
    /// approved decisions table — change requires spec edit, not
    /// a code edit.
    static let easyMultiplier: Double = 0.89

    /// Hard/Sprint boundary as a constant of critical speed.
    /// Research doc §5.1, Piatrikova 2019. // why: pinned by the
    /// approved decisions table — change requires spec edit, not
    /// a code edit.
    static let hardMultiplier: Double = 1.035

    /// Derive the four zone boundaries from a critical speed and
    /// an observed peak speed.
    ///
    /// - Parameters:
    ///   - criticalSpeedMps: the 3MT critical-speed reading (m/s).
    ///     Must be finite and positive; nil is returned otherwise.
    ///   - peakSpeedMps: the observed peak speed (m/s). May be
    ///     zero / negative / NaN / +∞ — invalid values are treated
    ///     as "no data" and the sprint boundary falls back to
    ///     `1.035 × CS`.
    ///   - sourceTrialNumber: the 3MT trial number these zones
    ///     came from. Pass-through; the service does not gate on
    ///     trial number (that's the Slice 2 resolver's job).
    /// - Returns: `TrainingZones` with the four boundaries +
    ///     rendered pace strings, or nil iff `criticalSpeedMps`
    ///     is non-finite or non-positive. Never crashes.
    static func derive(
        criticalSpeedMps: Double,
        peakSpeedMps: Double,
        sourceTrialNumber: Int
    ) -> TrainingZones? {
        // Defensive: bad CS → no zones. Easy/hard multipliers
        // times a finite, positive CS are always finite and
        // positive, so the boundaries downstream are well-formed.
        guard criticalSpeedMps > 0, criticalSpeedMps.isFinite else {
            return nil
        }

        let cs = criticalSpeedMps
        let easyBoundary = easyMultiplier * cs
        let steadyBoundary = cs
        let hardBoundary = hardMultiplier * cs

        // Sprint boundary: the observed peak when it's both valid
        // (finite, positive) and at or above the hard/sprint line
        // (the swimmer has demonstrated a Sprint). Otherwise clamp
        // to the hard boundary — this is the "never invert" rule
        // and also the "invalid peak → boundary" fallback in one
        // expression.
        let sprintBoundary: Double
        if peakSpeedMps.isFinite, peakSpeedMps > 0, peakSpeedMps >= hardBoundary {
            sprintBoundary = peakSpeedMps
        } else {
            sprintBoundary = hardBoundary
        }

        return TrainingZones(
            easy: PacePer100m(
                mps: easyBoundary,
                paceString: thresholdPaceString(criticalSpeedMps: easyBoundary)
            ),
            steady: PacePer100m(
                mps: steadyBoundary,
                paceString: thresholdPaceString(criticalSpeedMps: steadyBoundary)
            ),
            hard: PacePer100m(
                mps: hardBoundary,
                paceString: thresholdPaceString(criticalSpeedMps: hardBoundary)
            ),
            sprint: PacePer100m(
                mps: sprintBoundary,
                paceString: thresholdPaceString(criticalSpeedMps: sprintBoundary)
            ),
            criticalSpeedMps: cs,
            sourceTrialNumber: sourceTrialNumber
        )
    }

    // MARK: - Usable-profile resolver (V0.40 Slice 2)

    /// The quality-flag rawValue the analyzer appends for a
    /// familiarisation trial (trials 1–2 per Piatrikova 2019).
    /// Mirrors `ThreeMinuteTestAnalyzer.QualityFlag.learningTrial.rawValue`
    /// and `SwimmerTestProfile.qualityFlags` — same snake_case
    /// string end-to-end. // why: kept here as a constant so the
    /// resolver is self-contained — no analyzer import — and the
    /// spec rule ("learning flag means not usable") is the only
    /// thing the resolver needs to know about flags.
    static let learningTrialFlag = "learning_trial"

    /// The minimum trial number for a profile to be considered
    /// usable. Trials 1–2 are familiarisation; the first real
    /// reading lands on trial 2 (or trial 3 in a conservative
    /// protocol). // why: pinned by the approved decisions table
    /// #3 — change requires spec edit, not a code edit.
    static let usableTrialThreshold = 2

    /// Resolve the latest usable 3MT profile from a set of
    /// `SwimmerTestProfile` rows. The "is this profile usable?"
    /// gate per V0.40 §Slice 2: a usable profile is the latest
    /// per (swimmer, stroke) with `trial_number >= 2` AND no
    /// `learning_trial` quality flag. The downstream display
    /// (Slice 3) and drop-rule gate (Slice 4) both rely on this
    /// resolver to pick the right profile — zones from a
    /// learning trial are hidden, with the "repeat before using"
    /// coach line kept intact.
    ///
    /// Resolution rule (spec §Slice 2, approved decisions #3):
    ///   1. Filter: `trialNumber >= usableTrialThreshold` AND
    ///      `qualityFlags` does NOT contain `learningTrialFlag`.
    ///   2. Pick the profile with the highest `trialNumber`
    ///      among the survivors ("prefers the newest usable
    ///      trial" — trial 3 beats trial 2 when both usable).
    ///   3. Tie-break: if multiple profiles share the same max
    ///      `trialNumber` (rare — should not happen in
    ///      practice), return the one with the most recent
    ///      `testDate`. `testDate` is an ISO8601 string in this
    ///      struct (mirrors the Postgres wire format), and
    ///      ISO8601 strings sort correctly chronologically with
    ///      lexicographic comparison — so plain `>` is the
    ///      right operator.
    ///
    /// - Parameter profiles: the per-(swimmer, stroke) candidate
    ///   rows. The resolver does not group — the caller passes
    ///   the set for a single (swimmer, stroke) pair, or for
    ///   many pairs and asks for the overall newest usable row.
    ///   The spec rule is per-(swimmer, stroke) but the resolver
    ///   shape stays per-row so the caller can chain a groupBy
    ///   in front of it without the resolver importing any
    ///   grouping helper.
    /// - Returns: the most-recent usable profile, or nil when
    ///   no profile in the input clears the gate. Never crashes
    ///   on an empty array or on rows missing fields.
    static func latestUsableProfile(
        profiles: [SwimmerTestProfile]
    ) -> SwimmerTestProfile? {
        // Single-pass filter + max-by (trialNumber, testDate). The
        // sorted pattern (filter → sort → first) reads cleanly
        // but allocates two arrays and an O(n log n) sort; this
        // max-by walks the array once and tracks only the best
        // survivor — same answer, no allocations.
        //
        // "best" = highest trialNumber; on tie, the later
        // testDate wins. lexicographic compare on ISO8601
        // strings gives chronological order.
        var best: SwimmerTestProfile?
        for profile in profiles {
            // Gate: trialNumber must be at or above the
            // familiarisation threshold AND the profile must
            // not carry the learning-trial flag.
            guard profile.trialNumber >= usableTrialThreshold else { continue }
            guard !profile.qualityFlags.contains(learningTrialFlag) else { continue }

            if let current = best {
                if profile.trialNumber > current.trialNumber {
                    best = profile
                } else if profile.trialNumber == current.trialNumber,
                          profile.testDate > current.testDate {
                    // ISO8601 strings sort lexicographically in
                    // chronological order; a later date string
                    // compares greater than an earlier one. The
                    // `>` (not `>=`) is intentional — when the
                    // dates tie (which should not happen given
                    // a UUID id differs), keep the existing
                    // `best` so the resolver is deterministic.
                    best = profile
                }
            } else {
                best = profile
            }
        }
        return best
    }
}
