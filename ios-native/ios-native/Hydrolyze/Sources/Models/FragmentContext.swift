// Hydrolyze — FragmentContext (t_c74dffbc, 2026-08-04)
//
// Per-fragment metadata that flows from the parser's v2 tree → the live
// stopwatch CTA → the recorded_times row → the pairing engine's
// prediction. The fragment is the unit the stopwatch times AND the unit
// the pairing engine evaluates, so the prediction must be keyed on
// (swimmer, fragmentDistance, fragmentIntensity, fragmentStartType) —
// not the parent workout_set's generic PB.
//
// See:
//   - parser workspace stopwatch-pipeline.ts (the load-bearing TS
//     harness; the iOS code matches its shape)
//   - hydrolyze.parse.v2 schema (schema.ts) for the canonical wire shape
//   - WorkoutPreview.swift (the per-fragment CTA) for the UI surface
//
// The minimal correct wiring for the iOS save flow:
//   1. ParsedFragment (WorkoutPreview.swift) is the Swift type the LLM
//      parser produces; each fragment carries distance, intensity, start,
//      suit, gear, descriptor.
//   2. The iOS app's TimingViewModel.save() reads the parsed fragments
//      from the workout and builds a per-(swimmer, fragment) prediction
//      map alongside the existing per-swimmer map.
//   3. The PairingEngine API stays the same for now (single
//      predictions[swimmerId] map); the follow-up slice is to extend
//      PairingEngine.pair() to accept a [String: [String: Prediction]]
//      (swimmerId → fragmentKey → prediction) map and key the cost
//      matrix on the lap's fragmentId.

import Foundation

/// FragmentContext — the per-fragment metadata the pairing engine reads.
/// Mirrors the schema.ts Fragment fields the harness asserts on
/// (distance, intensity, startType) plus a stable fragmentId so the
/// pairing engine can key the prediction per (swimmer, fragment).
///
/// The harness's stopwatch-pipeline.test.ts is the load-bearing proof
/// of the wiring: every assignment's context.distance == 75,
/// context.intensity == "fast", context.startType == "in_water" for
/// the 4 × (75 fast / 25 easy) worked example. The iOS code matches
/// the same shape.
struct FragmentContext: Codable, Sendable, Hashable {
    let fragmentId: String
    let parentIntervalId: String
    let distance: Int
    let intensity: String?  // "firm" | "easy" | "moderate" | "hard" | "race" — schema's normalized label
    let startType: String?  // "in_water" | "dive" | "backstroke_start"
    let suit: Bool?
    let gear: [String]?
    let descriptor: String?

    /// Stable key for grouping predictions. Distance + intensity + start
    /// uniquely identifies the fragment in the pairing context. The
    /// fragmentId is the canonical key for the parse tree; the combo
    /// key is the pairing key (the fragmentId is fragment-unique, the
    /// combo is human-readable for logging).
    var pairingKey: String {
        "\(distance)m@\(intensity ?? "?")@\(startType ?? "?")"
    }
}
