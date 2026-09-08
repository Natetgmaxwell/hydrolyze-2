// Hydrolyze — WorkoutSetFragment (t_d59998d9, 2026-08-05)
//
// One leaf fragment of a parsed workout set. A "fragment" is the
// addressable timed unit the coach's stopwatch actually times — the
// smallest piece of the parse tree the pairing engine can match a
// recorded time against. For a `4 x (75 fast / 25 easy)` set, each
// leaf fragment is one of the 8 timed units (4 reps × 2 leaves).
//
// Mirrors the `Fragment` shape from parser-integration.ts (the UI-facing
// projection; NOT the v2 wire schema's `Fragment`). The fields here are
// what the rendered FragmentCTARow needs to display and what the
// recorded-time callback needs to attach back to the row.
//
// Data path (t_d59998d9, this commit):
//   1. The LLM parser (parse-workout Edge Function or future on-device
//      parser) emits one WorkoutSetFragment per leaf fragment, along
//      with the parent WorkoutSet.
//   2. workout_sets.fragments column (JSONB) stores the array.
//   3. WorkoutService.fetchWorkoutSets decodes `fragments` if present.
//   4. WorkoutDetailView.buildParsedWorkout maps each fragment into
//      a ParsedFragment on the ParsedRepGroup so WorkoutPreview's
//      FragmentCTARow renders it.
//
// Until the DB column ships (documented as t_c74dffbc follow-up #3),
// `fragments` is always nil and the FragmentCTARow never renders.
// The UI code is forward-compatible: when fragments start arriving,
// the rows appear automatically.
//
// Why a separate type from ParsedFragment: ParsedFragment is the
// Codable LLM-emitted shape (nested intensity, snake_case keys, etc.).
// WorkoutSetFragment is the decoded DB-row shape the iOS view-model
// layer holds. Mapping is explicit in buildParsedWorkout, mirroring
// the v2 → UI projection in parser-integration.ts projectWorkoutSet().

import Foundation

/// WorkoutSetFragment — one addressable timed leaf of a parsed set.
///
/// `reps` is the parent rep group's repetition count (e.g. 4 for
/// `4 x (75 fast / 25 easy)`); each fragment row represents `reps`
/// repetitions of the same timed unit. The row shows `×N` so the
/// coach reads "4 × 75m fast" not just "75m fast."
///
/// `confidence` is the parser's confidence in the fragment (1.0 for
/// clean regex path, the LLM's per-call value for the LLM path, nil
/// if unknown). The FragmentCTARow renders a confidence badge when
/// < 1.0 so the coach can see "this came from the LLM fallback."
struct WorkoutSetFragment: Codable, Identifiable, Sendable, Hashable {
    let id: String
    let orderIndex: Int
    let distanceMeters: Int
    let reps: Int
    let intensity: String          // "easy" | "moderate" | "firm" | "fast" | "max" | "build" | "descend" | "negative_split" | "unknown"
    let startType: String          // "dive" | "wall" | "push"  (FragmentStartType from parser-integration.ts)
    let paceTargetSec: Int?        // send-off in seconds, nil if open / multi-descending
    let confidence: Double?        // 1.0 = regex, <1.0 = LLM fallback; nil = unknown

    enum CodingKeys: String, CodingKey {
        case id
        case orderIndex = "order_index"
        case distanceMeters = "distance_meters"
        case reps, intensity
        // V0.35 (2026-08-12): snake_case to match the documented JSONB
        // shape (migration comment) and the parser's start_type key.
        case startType = "start_type"
        case paceTargetSec = "pace_target_sec", confidence
    }
}

extension WorkoutSetFragment {
    /// V0.54 (2026-09-08): mirror of the V0.53.1 `isTimableFragment(_:)`
    /// predicate (WorkoutPreview.swift:1519) for the DB-row shape.
    /// The parser maps `easy | recovery | warm-up | ez | relaxed`
    /// → `intensity = "easy"` at _llm.ts:560, so any non-easy value
    /// means the fragment is timable. nil intensity (drills / hold
    /// rates / descriptors without a parsed intensity) stays timable
    /// as in the existing FragmentCTARow contract — coaches time
    /// drills by the clock, not by feel.
    var isTimable: Bool {
        guard !intensity.isEmpty else { return true }
        return intensity.lowercased() != "easy"
    }
}
