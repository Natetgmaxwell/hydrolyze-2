import Foundation

/// In-memory lap record during a timing session.
/// Each lap records the elapsed time at the moment the lap was triggered.
struct Lap: Identifiable, Sendable {
    let id: String
    let lapNumber: Int      // 1-indexed
    let elapsedMs: Int       // milliseconds since session start
    let splitMs: Int         // milliseconds since previous lap
}

/// In-memory timing session — assembled during active session,
/// persisted to recorded_times on save.
struct TimingSession: Sendable {
    var id: String
    let swimmerId: String
    let stroke: String
    let distance: Int
    let reps: Int?
    let interval: String?
    let intensityLabel: String?
    let workoutSetId: String?
    let gear: String?
    let laps: [Lap]
    let startedAt: String    // ISO8601
    var endedAt: String?     // ISO8601

    var totalElapsedMs: Int {
        laps.last?.elapsedMs ?? 0
    }

    /// Format a millisecond value as "m:ss.SS" (minutes:seconds.centiseconds).
    static func formatMs(_ ms: Int) -> String {
        let totalCentis = ms / 10
        let centis = totalCentis % 100
        let totalSecs = totalCentis / 100
        let secs = totalSecs % 60
        let mins = totalSecs / 60
        return String(format: "%d:%02d.%02d", mins, secs, centis)
    }
}

/// Optional pre-fill from WorkoutDetailView per-rep-group start.
/// When present, stroke/distance pickers are hidden in TimingView.setup.
/// workoutSetId is load-bearing — the future pairing algorithm uses it to
/// join set context (stroke, distance, pace, intensity, PBs).
///
/// t_c74dffbc (2026-08-04): fragmentContexts carries the per-fragment
/// metadata for composite sets (e.g. `4 x (75 fast / 25 easy)`). When
/// non-empty, the save flow keys the prediction per (swimmer, fragment)
/// — not the parent set. The WorkoutDetailView populates this from the
/// parsed `ParsedRepGroup.fragments[]` when the per-fragment CTA is used.
struct SetPrefill: Sendable, Hashable {
    let stroke: String
    let distance: Int
    let reps: Int?
    let interval: String?
    let intensityLabel: String?
    let workoutSetId: String?
    /// V0.38 Slice 4 (2026-08-16): the per-set intensity type rawValue
    /// (e.g. "3mt") mirrored from `WorkoutSet.intensityType`. The
    /// `intensityLabel` above is the human-readable text ("3-minute
    /// all-out"); the rawValue is the structured marker the parser
    /// emits. Slice 4's 3MT detection reads this in preference to the
    /// label so a mixed workout (some 3MT sets, some training sets)
    /// correctly classifies the active set without false-positives
    /// from a workout-level session_type.
    let intensityType: String?
    /// t_c74dffbc (2026-08-04): optional per-fragment contexts. nil for
    /// non-composite sets (the existing prefill path).
    let fragmentContexts: [FragmentContext]?

    /// Rich display label for the setup screen, e.g. "4 × 100 Free @ 1:30"
    var displayLabel: String {
        var parts: [String] = []
        if let r = reps { parts.append("\(r) ×") }
        parts.append("\(distance)m")
        parts.append(stroke)
        if let iv = interval { parts.append("@ \(iv)") }
        if let il = intensityLabel { parts.append(il) }
        return parts.joined(separator: " ")
    }
}

/// Session state — drives TimingView rendering.
enum TimingState: Sendable {
    case setup    // choosing swimmer + set
    case ready    // waiting for start
    case running  // stopwatch active
    case finished  // review + save/discard (single-swimmer flow, or save-failure fallback)
    case saving   // Phase 2.5-c: auto-saving for multi-swimmer session, navigates to pairing on success
}