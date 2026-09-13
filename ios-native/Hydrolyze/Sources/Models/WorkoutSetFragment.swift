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
//   4. V0.55 S1: WorkoutStructureView (Views/Workouts/
//      WorkoutStructureView.swift) routes each fragment into a
//      ParsedFragment on the ParsedRepGroup via the single
//      WorkoutPreviewBuilder.fromWorkoutAndSets projection so
//      WorkoutPreview's FragmentCTARow renders it. The single
//      shared render surface means WorkoutDetailView and
//      WorkoutBuilderView cannot drift in fragment mapping.
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
    // V0.54 S2.2 (2026-09-09, jodie-09 Console parse fidelity):
    // verbatim source-text distance (e.g. "12.5", "37.5", "25") the
    // server sets right before serialization. Display-only — the int
    // `distanceMeters` is still the wire/timing value (V0.51 contract).
    // nil-tolerant decode so old DB rows / pre-V0.53.3 server builds
    // stay coherent; render surfaces fall back to int distance when
    // nil. Same contract as `ParsedFragment.distanceLabel`.
    let distanceLabel: String?
    // V0.54 S2.2 (2026-09-09, jodie-09 Console parse fidelity):
    // the coach's verbatim intensity word ("race rhythm", "easy",
    // "strong") — what the segment label should render. Distinct from
    // `intensity` (the parser type token like "race_pace" / "easy"
    // that drives `isTimable` + the colour mapping). nil-tolerant
    // decode so old rows keep working; the segment renderer falls
    // back to `intensity` when nil.
    let intensityLabel: String?

    enum CodingKeys: String, CodingKey {
        case id
        case orderIndex = "order_index"
        case distanceMeters = "distance_meters"
        case reps, intensity
        // V0.35 (2026-08-12): snake_case to match the documented JSONB
        // shape (migration comment) and the parser's start_type key.
        case startType = "start_type"
        case paceTargetSec = "pace_target_sec", confidence
        // V0.54 S2.2: optional display-fidelity fields. Mirror the
        // `ParsedFragment` snake_case keys so the WorkoutPreviewBuilder
        // mapping is a straight pass-through (no rename, no fallback
        // string-massaging at the boundary).
        case distanceLabel = "distance_label"
        case intensityLabel = "intensity_label"
    }

    // V0.54 S2.2: custom decoder so the new optional display-fidelity
    // fields use decodeIfPresent and old DB rows (pre-V0.53.3 server,
    // pre-S2.2 client) decode without throwing on missing keys. Swift's
    // auto-synthesized init(from:) calls decode(_:forKey:) (not
    // decodeIfPresent), which throws DecodingError.keyNotFound on any
    // missing key — fatal for every WorkoutSetFragment without the new
    // fields. Mirrors the defensive pattern `ParsedFragment` already
    // uses for the same reason (see WorkoutPreview.swift:1379).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        orderIndex = try c.decode(Int.self, forKey: .orderIndex)
        distanceMeters = try c.decode(Int.self, forKey: .distanceMeters)
        reps = try c.decode(Int.self, forKey: .reps)
        intensity = try c.decode(String.self, forKey: .intensity)
        startType = try c.decode(String.self, forKey: .startType)
        paceTargetSec = try c.decodeIfPresent(Int.self, forKey: .paceTargetSec)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence)
        distanceLabel = try c.decodeIfPresent(String.self, forKey: .distanceLabel)
        intensityLabel = try c.decodeIfPresent(String.self, forKey: .intensityLabel)
    }

    // Memberwise init (default — required for seed fixtures + previews).
    init(
        id: String,
        orderIndex: Int,
        distanceMeters: Int,
        reps: Int,
        intensity: String,
        startType: String,
        paceTargetSec: Int?,
        confidence: Double?,
        distanceLabel: String? = nil,
        intensityLabel: String? = nil
    ) {
        self.id = id
        self.orderIndex = orderIndex
        self.distanceMeters = distanceMeters
        self.reps = reps
        self.intensity = intensity
        self.startType = startType
        self.paceTargetSec = paceTargetSec
        self.confidence = confidence
        self.distanceLabel = distanceLabel
        self.intensityLabel = intensityLabel
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
