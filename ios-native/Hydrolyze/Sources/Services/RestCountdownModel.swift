import Foundation

/// RestCountdownModel — V0.39 Slice 2 (2026-08-18) — the drop-rule
/// state machine for anaerobic sets. Lives in its own file (no
/// UIKit, no @MainActor, no Combine, no async, no Supabase) so the
/// orchestrator-Mac CLI runner (`build_and_run_restcountdown.sh`)
/// can compile it standalone and regression-gate the strike math,
/// maturity gate, intensity gate, threshold scaling, escalation
/// caps, strike reset, revert, tick, and multi-swimmer common-clock
/// behavior without a booted simulator.
///
/// Spec: V0.39_SPEC.md §Slice 2 + §4.1 of
/// `docs/research/2026-08-15-3mt-drop-rule-zones.md`. This file is
/// the pure-function piece; the VM (Slice 3) drives it via
/// `tick()` from its existing 10ms timer and calls `evaluate(...)`
/// on each rep completion. The model does NOT call the predictor
/// or touch the DB.

/// Where the current standard came from. Surfaced in the
/// `set_rest_events` row so the recovery-signature analytics can
/// distinguish predicted-time standards from rep-1 fallbacks
/// (V0.39 §Contract + §4.2 of the research doc).
enum RestStandardSource: String, Equatable, Sendable {
    /// The standard came from `HistoricalTimePredictor.predict(...)`
    /// at this set's (distance, intensity, gear) — only used when
    /// `Prediction.maturity` ≥ .reliable (6+ samples).
    case predicted
    /// The standard came from the swimmer's rep-1 time. The
    /// fallback path: maturity < .reliable, or the predictor
    /// returned nil, or the VM chose to pass rep1 explicitly.
    case rep1
}

/// One drop-rule decision for a single rep completion. Returned by
/// `RestCountdownModel.evaluate(...)`. Mirrors the column shape of
/// `set_rest_events` (V0.39 §Slice 1) so the save path in Slice 4
/// can encode this struct 1:1 into a row.
struct DropEvaluation: Equatable, Sendable {
    let swimmerId: String
    let repIndex: Int            // 1-indexed rep within the set
    let repTimeMs: Int
    let standardMs: Int          // the standard used for THIS evaluation
    let standardSource: RestStandardSource
    let baseRestSec: Int         // round-trip of the model's base
    let extendedRestSec: Int     // AFTER this evaluation (post any strike)
    let deltaSec: Int            // 30 (strike 1), 60 (strike 2+), or 0
    let strikeCount: Int         // current strike count for this swimmer after evaluation
    let struck: Bool             // true iff this rep was a strike
}

/// Result of a `revert(swimmerId:)` call. The VM records this as a
/// `set_rest_events` row with `reverted = true` so the recovery
/// flywheel (V0.39 acceptance + §Contract) learns the coach
/// disagreed — the engine never silently extends.
struct RevertResult: Equatable, Sendable {
    let swimmerId: String
    let newExtendedRestSec: Int
    let reverted: Bool           // always true; the type is shaped so
                                 // the future "no-op revert" path
                                 // (e.g. swimmer never struck) can
                                 // be a separate case without
                                 // breaking the save-path encode.
}

/// The drop-rule state machine. Pure: no DB, no async, no UIKit,
/// no Combine — only its own internal state mutates. The VM owns
/// the model and drives it from its existing 10ms timer.
///
/// The model is the source of truth for THREE clocks + flags:
///   - `remainingSec`: the LIVE common countdown (the one shown
///     in the timing UI between reps). Decremented by `tick()`.
///   - `extendedRestSec`: the common rest AFTER extensions
///     (`baseRestSec + max(currentExtensionSec.values)`).
///     Recomputed on every extension change (strike, reset, or
///     revert). The VM displays `max(remainingSec, extendedRestSec
///     - elapsed)` so the coach sees the extension land immediately
///     on the strike, not after the next tick.
///   - `currentExtensionSec[swimmer]`: the per-swimmer extension
///     flag (0 / 30 / 60). Surfaced in the inline badge
///     ("Ariana +30s, Jack holding").
final class RestCountdownModel {
    /// The set's base interval parsed from `workout_sets.interval_text`
    /// to seconds. The rest countdown is anchored here.
    let baseRestSec: Int

    /// True iff the set is anaerobic (intensity hard/race). The
    /// V0.39 zone gate (approved decision §3 of the spec): aerobic
    /// sets get NO individualized rest. The VM derives this from
    /// `IntensityLevel` on the active set at construction.
    let setIsAnaerobic: Bool

    /// Per-swimmer strike count (1st or 2nd). Absent for swimmers
    /// who haven't been evaluated yet.
    var strikes: [String: Int] = [:]

    /// Per-swimmer current extension (0, 30, or 60). The inline badge
    /// reads this for the per-swimmer flag. 0 means "currently
    /// holding" — the spec's "Ariana +30s, Jack holding" surface.
    var currentExtensionSec: [String: Int] = [:]

    /// Per-swimmer current standard (ms) — the value used for the
    /// most recent evaluation. Updated on EVERY evaluation, not
    /// just strikes (spec §Slice 2 rule 1: "always update these,
    /// even on a non-strike — the standard is per-evaluation").
    var standardMs: [String: Int] = [:]

    /// Per-swimmer source for the current standard. Same lifetime
    /// as `standardMs` — written together.
    var standardSource: [String: RestStandardSource] = [:]

    /// Live common countdown. Starts at `baseRestSec`; the VM
    /// calls `tick()` once per second from its existing 10ms
    /// timer (Slice 3).
    var remainingSec: Int

    /// Common rest after extensions. Recomputed on every extension
    /// change (strike / reset / revert). The timing UI uses this to
    /// extend the countdown — `remainingSec` catches up via
    /// `max(remainingSec, extendedRestSec - elapsedFromExtension)`.
    var extendedRestSec: Int

    init(baseRestSec: Int, setIsAnaerobic: Bool) {
        self.baseRestSec = baseRestSec
        self.setIsAnaerobic = setIsAnaerobic
        self.remainingSec = baseRestSec
        self.extendedRestSec = baseRestSec
    }

    /// Evaluate one rep completion for one swimmer. Returns nil iff
    /// the set is aerobic (zone gate closed) — no evaluation, no
    /// state mutation. Returns a `DropEvaluation` on every other
    /// path so the VM always knows the current standard/strikes
    /// (spec: "return a non-nil evaluation on EVERY rep completion
    /// so the VM always knows the current standard/strikes").
    ///
    /// The model does NOT call `HistoricalTimePredictor`. The VM
    /// has already done that and passes the predicted standard +
    /// maturity in. The maturity gate decides whether the
    /// predicted standard is used (maturity ≥ .reliable) or the
    /// rep-1 fallback is used (maturity < .reliable, or no
    /// prediction available).
    func evaluate(
        swimmerId: String,
        repIndex: Int,
        repTimeMs: Int,
        distanceMeters: Int,
        predictedStandardMs: Int?,
        predictionMaturity: Prediction.Maturity?,
        rep1TimeMs: Int
    ) -> DropEvaluation? {
        // V0.39 zone gate (approved §3): aerobic sets → no
        // individualized rest. The VM derives setIsAnaerobic from
        // IntensityLevel (hard/race). Returning nil here is the
        // single source of truth — the VM never sees an
        // evaluation, so no badge, no revert button.
        guard setIsAnaerobic else { return nil }

        // Maturity gate: predicted wins iff maturity is reliable
        // (6-15 samples) or excellent (16+) AND the VM supplied a
        // predicted standard. Any other combination (none /
        // learning / reliable-but-nil-predicted) falls back to
        // rep1. The asymmetry with the predictor's sigmaMs floor
        // is intentional — the drop standard is a fixed delta, not
        // a sigma multiple (research doc §4.2).
        let usePredicted: Bool
        switch predictionMaturity {
        case .some(.reliable), .some(.excellent):
            usePredicted = (predictedStandardMs != nil)
        case .some(.learning), .some(Prediction.Maturity.none), nil:
            usePredicted = false
        }
        let standard: Int
        let source: RestStandardSource
        if usePredicted, let p = predictedStandardMs {
            standard = p
            source = .predicted
        } else {
            standard = rep1TimeMs
            source = .rep1
        }
        // Standard is per-evaluation — always update, even on a
        // non-strike. The VM may display "current standard:
        // 60.0s" between reps.
        standardMs[swimmerId] = standard
        standardSource[swimmerId] = source

        // Threshold scales linearly with distance (Eva's rule,
        // research doc §4.1 transcript 27:07–27:12): 0.5s per 50m,
        // 0.25s per 25m → 10ms per meter. The 25/50 special cases
        // are kept for the spec's named values; odd distances use
        // the linear formula. Threshold is in ms (rep times are in
        // ms) so the comparison is integer-only.
        let threshold = Self.thresholdMs(distanceMeters: distanceMeters)

        if repTimeMs > standard + threshold {
            // Strike. Increment (cap at 2 — spec: "Strike count
            // caps at 2 (no further escalation)"). Strike 1 →
            // +30s; strike 2+ → +60s. The per-swimmer extension
            // REPLACES (does not stack) — Eva's Dressel rule
            // (research doc §4.1 transcript 19:56).
            let previous = strikes[swimmerId] ?? 0
            let next = min(previous + 1, 2)
            let delta: Int = (next == 1) ? 30 : 60
            strikes[swimmerId] = next
            currentExtensionSec[swimmerId] = delta
            extendedRestSec = baseRestSec + maxExtension()

            return DropEvaluation(
                swimmerId: swimmerId,
                repIndex: repIndex,
                repTimeMs: repTimeMs,
                standardMs: standard,
                standardSource: source,
                baseRestSec: baseRestSec,
                extendedRestSec: extendedRestSec,
                deltaSec: delta,
                strikeCount: next,
                struck: true
            )
        } else {
            // Within threshold — the swimmer "hits the standard
            // again" (Eva: "he's allowed two strikes again"). Reset
            // their strike count + extension so the NEXT strike
            // lands as strike 1 (+30s), not strike 3 (capped at
            // 2). Setting to 0 unconditionally is safe: a
            // never-struck swimmer was already 0/nil; we're making
            // the absence explicit so the inline badge shows
            // "holding" rather than no flag.
            strikes[swimmerId] = 0
            currentExtensionSec[swimmerId] = 0
            extendedRestSec = baseRestSec + maxExtension()

            return DropEvaluation(
                swimmerId: swimmerId,
                repIndex: repIndex,
                repTimeMs: repTimeMs,
                standardMs: standard,
                standardSource: source,
                baseRestSec: baseRestSec,
                extendedRestSec: extendedRestSec,
                deltaSec: 0,
                strikeCount: 0,
                struck: false
            )
        }
    }

    /// One-tap revert for a swimmer. Clears their strikes + current
    /// extension and recomputes the common extended rest (now =
    /// base + max of remaining extensions). Coach is authority —
    /// the VM records this with `reverted = true` in
    /// `set_rest_events` (V0.39 §Contract, decision 4).
    func revert(swimmerId: String) -> RevertResult {
        currentExtensionSec[swimmerId] = 0
        strikes[swimmerId] = 0
        extendedRestSec = baseRestSec + maxExtension()
        return RevertResult(
            swimmerId: swimmerId,
            newExtendedRestSec: extendedRestSec,
            reverted: true
        )
    }

    /// Decrement the live common countdown by 1, floor at 0. The
    /// VM calls this once per second from its existing 10ms timer
    /// (Slice 3 — no new timer machinery). Does NOT touch
    /// `extendedRestSec`: the extension lands as a one-shot
    /// recomputation in `evaluate(...)` / `revert(...)`, not as a
    /// ticking offset.
    func tick() {
        if remainingSec > 0 {
            remainingSec -= 1
        }
    }

    /// Clear all per-swimmer state and reset the clock to
    /// `baseRestSec`. Used between sets (the VM calls this when the
    /// active set changes). Removes the per-swimmer keys rather
    /// than zeroing them so the model's per-swimmer state matches
    /// the "no swimmer has been evaluated yet" invariant.
    func reset() {
        strikes.removeAll()
        currentExtensionSec.removeAll()
        standardMs.removeAll()
        standardSource.removeAll()
        remainingSec = baseRestSec
        extendedRestSec = baseRestSec
    }

    // MARK: - Helpers

    /// Threshold in ms for a given rep distance. Eva's rule
    /// (research doc §4.1, spec §Slice 2 rule 1): 0.5s per 50m,
    /// 0.25s per 25m → 10ms per meter, linear. The 25/50
    /// special-cases are kept so the spec's named values
    /// (250ms, 500ms) match exactly; everything else scales
    /// linearly.
    private static func thresholdMs(distanceMeters: Int) -> Int {
        if distanceMeters == 25 { return 250 }
        if distanceMeters == 50 { return 500 }
        return Int(Double(distanceMeters) * 10.0)
    }

    /// Max of all per-swimmer extensions; 0 if none. The common
    /// extended rest is base + this. Using `.max() ?? 0` because
    /// `currentExtensionSec` may be empty (no swimmers evaluated
    /// yet, or all reverted).
    private func maxExtension() -> Int {
        currentExtensionSec.values.max() ?? 0
    }
}

// MARK: - V0.39 Slice 3 display helpers (2026-08-18)
//
// Pure helpers used by the timing screen's countdown + inline badge.
// Lives in this file (same as the model) so the CLI runner at
// `build_and_run_restcountdown.sh` can compile them without UIKit —
// the UI-side strings are still coach-readable plain text. The
// spec mandates "m:ss" for the rest countdown (NOT "m:ss.SS" — the
// centiseconds format is reserved for the audit-trail stopwatch),
// "Rep N: 27.8, +0.6 → rest 5:00" for the badge, and "no new
// vocabulary" — so the helpers stay in coach words (rest, strike,
// extended) and reuse `TimingSession.formatMs` for the stopwatch
// display.

/// Parse an interval string into seconds. Accepts:
///   - "m:ss" (canonical parser output, e.g. "4:30" → 270)
///   - bare seconds (e.g. "45" → 45)
///   - "m" bare minutes (e.g. "3" → 180, only when accompanied by no colon)
///
/// Returns nil for malformed input. The spec is explicit: "on 4:30"
/// → 270s; the parser emits "m:ss" so that is the common case. The
/// bare-seconds fallback covers the legacy DB rows where the
/// `interval_text` column stores e.g. "60" (60 seconds).
func intervalToSeconds(_ raw: String?) -> Int? {
    guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
        return nil
    }
    // "m:ss" or "m:s" — split on the first colon.
    if let colon = raw.firstIndex(of: ":") {
        let minStr = raw[raw.startIndex..<colon]
        let secStr = raw[raw.index(after: colon)..<raw.endIndex]
        guard let minutes = Int(minStr), let seconds = Int(secStr),
              !secStr.isEmpty else {
            return nil
        }
        return minutes * 60 + seconds
    }
    // Bare digits — interpret as seconds (coaches sometimes write "60"
    // for a 60-second rest, or "3" for 3 minutes). The spec lists "45"
    // → 45s, so the bare-seconds path is the primary fallback.
    if let n = Int(raw) {
        return n
    }
    return nil
}

/// Format a millisecond delta as the over/under standard coach UI
/// string. Spec sample: `(27800 - 27000) / 1000 = 0.8` → `"+0.8"`.
/// Negative when a rep is faster than standard (rendered "-0.4");
/// zero renders as "0.0" (the inline badge line still reads cleanly
/// even when the rep landed exactly on the standard).
func formatRepDelta(repTimeMs: Int, standardMs: Int) -> String {
    let deltaTenths = Double(repTimeMs - standardMs) / 1000.0
    let sign = deltaTenths >= 0 ? "+" : ""
    return String(format: "\(sign)%.1f", deltaTenths)
}

/// Format a rep time (ms) as "27.8" seconds (1 decimal). The single
/// decimal is what Eva's transcript uses ("twenty-seven-eight") and
/// matches the spec's sample ("27.8"). Pads to 1 decimal even when
/// the value is exact ("27.0" rather than "27").
func formatRepTime(_ repTimeMs: Int) -> String {
    return String(format: "%.1f", Double(repTimeMs) / 1000.0)
}

/// Format seconds as the "m:ss" rest-clock string ("5:00", "0:30").
/// The spec mandates this is the common-clock format for the V0.39
/// rest countdown — NOT centiseconds. The audit-trail stopwatch
/// keeps "m:ss.SS" via `TimingSession.formatMs`; the rest clock is
/// the at-a-glance timer the coach reads in peripheral vision.
func formatRestSec(_ seconds: Int) -> String {
    let clamped = max(0, seconds)
    let m = clamped / 60
    let s = clamped % 60
    return String(format: "%d:%02d", m, s)
}
