import Foundation

/// ThreeMTReviewSupport — pure helpers for the V0.38 Slice 5 review surface.
///
/// Coach-vocabulary mapping + pace conversion + signal-color logic for the
/// per-swimmer 3MT panel. Lives in its own file (no UIKit, no @MainActor,
/// no Supabase) so the orchestrator-Mac CLI runner
/// (`build_and_run_3mtcopy.sh`) can compile it standalone and
/// regression-gate the strings the coach sees without a booted simulator.
///
/// Spec: V0.38_SPEC.md §Slice 5. Hard constraints (work order, line 5):
///   - Coach vocabulary ONLY. Three numbers: "Top speed", "Threshold pace",
///     "Battery". NEVER "anaerobic capacity", "D′", "peak speed", "critical speed".
///   - NO confidence percentages anywhere.
///   - Quality flags rendered in coach words; multiple flags joined with " · ".
///
/// The session review VM (`SessionReviewViewModel`) decodes
/// `swimmer_test_profiles` rows into a `[swimmerId: SwimmerTestProfile]`
/// dict and passes each profile into `ThreeMTPanelView` along the
/// existing per-row path. This file owns the *language* and the
/// *pace math*; the view owns the layout.

// MARK: - SwimmerTestProfile

/// Mirrors the columns of `swimmer_test_profiles` (see
/// `supabase/migrations/20260815120000_3mt_mode.sql`). Decoded from
/// the `swimmer_test_profiles` rows fetched in
/// `SessionReviewViewModel.load(sessionId:)`. Field names match the
/// Postgres wire format (snake_case) so the supabase-swift SDK's
/// default decoder picks them up without a custom CodingKeys map.
///
/// `quality_flags` is decoded as `[String]` to mirror the analyzer's
/// `QualityFlag.rawValue` strings ("learning_trial", "paced_start",
/// etc.). The view-side mapping to coach copy lives in `flagCopy(_:)`
/// below.
struct SwimmerTestProfile: Equatable, Sendable {
    let id: String
    let swimmerId: String
    let sessionId: String?
    let workoutSetId: String?
    let stroke: String
    let poolLength: Int
    let testDate: String
    let trialNumber: Int
    let peakSpeedMps: Double
    let criticalSpeedMps: Double
    let batteryMeters: Double
    let qualityFlags: [String]

    /// The raw snake_case flag keys. Use this for the JSON decoder's
    /// CodingKeys (no transformation). The view's copy mapping
    /// (`flagCopy(_:)`) keys off these same strings.
    enum CodingKeys: String, CodingKey {
        case id
        case swimmerId = "swimmer_id"
        case sessionId = "session_id"
        case workoutSetId = "workout_set_id"
        case stroke
        case poolLength = "pool_length"
        case testDate = "test_date"
        case trialNumber = "trial_number"
        case peakSpeedMps = "peak_speed_mps"
        case criticalSpeedMps = "critical_speed_mps"
        case batteryMeters = "battery_m"
        case qualityFlags = "quality_flags"
    }
}

extension SwimmerTestProfile: Codable {}

// MARK: - Flag → coach copy

/// Render the profile's `quality_flags` (the snake_case rawValues from
/// `ThreeMinuteTestAnalyzer.QualityFlag`) as a single line of coach
/// copy, one phrase per flag, joined with " · ". Empty flags → nil
/// (the view hides the line in that case).
///
/// Vocabulary is intentionally short and actionable — the coach reads
/// the line and knows what to do next. No jargon (no "D'", no
/// "anaerobic", no "all-out trial signature"). Multiple flags stack
/// with " · " so the coach sees the full picture at a glance.
///
/// Recognised rawValues (case-sensitive — these match the analyzer's
/// enum rawValues exactly):
///   - "learning_trial"        → "Learning trial — repeat before using for zones"
///   - "paced_start"           → "Started paced — not a true all-out"
///   - "flat_curve"            → "Even pace throughout — sprint the start next time"
///   - "peak_below_expected"   → "Top speed below their usual — check effort"
///
/// Unknown rawValues (future flags) are passed through unchanged so
/// the coach sees something rather than a silent drop. The view
/// still renders the line; the copy stays debuggable.
func flagCopy(qualityFlags: [String]) -> String? {
    let phrases = qualityFlags.map(flagCopy(_:))
    let nonEmpty = phrases.filter { !$0.isEmpty }
    guard !nonEmpty.isEmpty else { return nil }
    return nonEmpty.joined(separator: " · ")
}

/// Per-flag copy map. One phrase per rawValue (the analyzer's
/// `QualityFlag.rawValue`). Exposed as a free function so the CLI
/// test can exercise it directly without a UIKit dependency.
///
/// Stable mapping — the spec's "in coach vocabulary" contract is the
/// source of truth. Changing any phrase here is a behavior change the
/// coach will see in the review surface.
func flagCopy(_ flag: String) -> String {
    switch flag {
    case "learning_trial":
        return "Learning trial — repeat before using for zones"
    case "paced_start":
        return "Started paced — not a true all-out"
    case "flat_curve":
        return "Even pace throughout — sprint the start next time"
    case "peak_below_expected":
        return "Top speed below their usual — check effort"
    default:
        // Unknown flag: pass the rawValue through so the coach
        // (and the regression test) sees something instead of a
        // silent drop. Future slices should add a case here.
        return flag
    }
}

// MARK: - Critical-speed pace conversion

/// Convert a critical-speed reading (m/s) to per-100m pace in
/// "m:ss" format, e.g. 1.25 m/s → "1:20/100m". The view renders
/// this as the "Threshold pace" line.
///
/// The app's existing pace format is "m:ss" (see
/// `WorkoutParser.parseInterval` which emits "1:20", and the
/// `formatMs(_:)` family which renders "1:20.55"). For the 3MT
/// review we drop centiseconds — the critical-speed pace is a
/// derived number, not a measured lap, so two decimals is enough
/// resolution and the integer "m:ss" reads cleaner against the
/// chart and the other two numbers (Top speed m/s, Battery m).
///
/// Per-100m pace = 100 / cs (seconds). Rounded to whole seconds
/// so the coach sees "1:20" not "1:19.99" — the precision of the
/// underlying m/s reading is ~0.01 m/s, which corresponds to
/// ~0.8s at 1.25 m/s; rounding to whole seconds matches the
/// input resolution.
///
/// Edge cases:
///   - cs <= 0 or non-finite → returns nil (the view hides the
///     stat when pace conversion is undefined; battery/peak
///     still render).
///   - pace >= 60 minutes → caps at "59:59" — 100m pace never
///     reaches that scale, but the defensive cap keeps the
///     string well-formed at the edge.
func thresholdPaceString(criticalSpeedMps: Double) -> String? {
    guard criticalSpeedMps > 0, criticalSpeedMps.isFinite else { return nil }
    let secondsPer100 = 100.0 / criticalSpeedMps
    let totalSecs = Int(secondsPer100.rounded())
    // Defensive cap — at any realistic CS this never trips; the cap
    // guards the "%d:%02d" format from producing weirdness if the
    // input is unexpectedly small.
    let capped = min(totalSecs, 59 * 60 + 59)
    let mins = capped / 60
    let secs = capped % 60
    return String(format: "%d:%02d/100m", mins, secs)
}

// MARK: - Signal color

/// The signal dot color for a per-swimmer 3MT panel. One dot, top-left
/// of the 3MT section — the coach scans the review rows and the dot
/// tells them at-a-glance whether the trial is usable.
///
/// Deterministic mapping per the work order:
///   - learningTrial alone (any trial number) → gray (neutral, "wait")
///   - any other quality flag present (with or without learningTrial)
///     → amber (the trial ran but the data is suspect)
///   - no flags, profile present              → green (clean trial)
///   - profile row missing for a swimmer with
///     recorded splits (data failure)         → red (do not use)
///
/// "missing" is the failure mode the coach needs to see — the
/// analyzer ran but the save didn't land, or the pairing engine
/// paired a swimmer who didn't actually swim the test. The
/// signal-dot enum keeps this branch separate from the in-profile
/// branch (the profile dict doesn't have a key for the swimmer).
enum ThreeMTSignal {
    case green      // clean trial
    case amber      // any non-learningTrial quality flag (or learningTrial + another flag)
    case gray       // learningTrial alone (familiarisation — repeat before using)
    case red        // data failure: profile row missing
}

/// Resolve the signal for a swimmer given the (optional) profile row.
/// When the profile is nil (no `swimmer_test_profiles` row for this
/// swimmer), the signal is `.red` — the coach should not use the
/// numbers. The view shows a red dot in that case.
///
/// When the profile is present, the flags drive the color:
///   - `.learningTrial` only → gray (the trial ran but is a
///     familiarisation trial; the coach should repeat before using).
///   - `.learningTrial` + another flag → amber (the non-learning
///     flag wins; the coach should check the underlying issue).
///   - any other flag (no learningTrial) → amber.
///   - no flags → green (the trial is clean; ready for use).
func threeMTSignal(profile: SwimmerTestProfile?) -> ThreeMTSignal {
    guard let profile = profile else { return .red }
    let flags = Set(profile.qualityFlags)
    let hasLearning = flags.contains("learning_trial")
    let hasOther = !flags.isDisjoint(with: [
        "paced_start",
        "flat_curve",
        "peak_below_expected"
    ])
    if hasOther { return .amber }
    if hasLearning { return .gray }
    return .green
}
