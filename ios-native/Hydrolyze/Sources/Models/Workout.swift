import Foundation

/// WorkoutStatus — corresponds to the CHECK constraint in Postgres.
enum WorkoutStatus: String, Codable, Sendable {
    case draft
    case scheduled
    case inProgress = "in_progress"
    case complete
}

/// Workout — mirrors workouts table in Postgres.
struct Workout: Codable, Identifiable, Sendable {
    let id: String
    let coachId: String
    var title: String?
    var description: String?
    var scheduledAt: String?
    var amPm: String?
    var completedAt: String?
    var status: WorkoutStatus
    var createdAt: String
    var updatedAt: String?
    /// V0.45 (2026-08-18): first-class session template tag (e.g. "3mt").
    /// Optional — old rows decode clean. The list view renders a badge
    /// when sessionType == "3mt"; the create path accepts the value
    /// when seeding a template workout so the row tag survives the
    /// round-trip to the DB.
    var sessionType: String?
    /// V0.46 (2026-08-21): squad link. Workouts tagged with a `group_id`
    /// are scoped to that squad's swimmers; the session-start picker
    /// reads this to filter the roster to in-squad swimmers only.
    /// Optional — old unscoped rows decode clean (nil).
    var groupId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case coachId = "coach_id"
        case title
        case description = "workout_text"
        case scheduledAt = "scheduled_at"
        case amPm = "am_pm"
        case completedAt = "completed_at"
        case status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case sessionType = "session_type"
        case groupId = "group_id"
    }
}

/// WorkoutSet — ordered set components within a workout.
/// Corresponds to workout_sets table.
struct WorkoutSet: Codable, Identifiable, Sendable {
    let id: String
    let workoutId: String
    var orderIndex: Int
    var reps: Int?
    var distance: Int?
    var stroke: String?
    var intervalText: String?
    var intensityType: String?
    var intensityLabel: String?
    /// V0.41 (2026-08-18): the set-level zone term
    /// ("easy" | "steady" | "hard" | "sprint"). Mirrors the parser's
    /// `zone_term` on workout_sets. The timing flow (Slice 2) reads
    /// this to resolve each swimmer's zone pace; the builder preview
    /// (Slice 3) shows it as a chip.
    var zoneTerm: String?
    var paceTargetDistance: Int?
    var gear: [String]?  // Phase 1: upgraded from String? to [String]? for multi-gear sets
    /// Whether the swimmer wore a suit for this set (T1 schema, 2026-06-20).
    /// Default false (no suit, the common training case). Engine reads
    /// this to apply the suit calibration delta in
    /// `HistoricalTimePredictor.predict()`.
    var suit: Bool?
    /// Start type for this set (T1 schema, 2026-06-20). Default
    /// 'in_water' (the common training case, covers push start).
    /// Engine reads this to apply the start calibration delta.
    var startType: String?
    /// Whether this set is dive-started (Phase 1, 2026-07-25).
    /// Denormalized from start_type='dive' and/or parser detection.
    var dive: Bool?
    /// t_d59998d9 (2026-08-05): parsed leaf fragments for this set.
    /// nil for non-composite sets or for rows where the parser did
    /// not emit fragments. Decoded if present so the iOS app renders
    /// the parsed tree when the server's parse-workout Edge Function
    /// ships fragments to the DB. Until that server-side change
    /// lands, fragments is nil and the FragmentCTARow does not
    /// render — this is the documented follow-up from t_c74dffbc.
    var fragments: [WorkoutSetFragment]?
    // V0.54 S2.2 (2026-09-09, jodie-09 Console parse fidelity):
    // verbatim coach-language note ("Each: 50 @ 65% / 70% / 75%",
    // "Build 1-4") rendered above or below the rep card as the
    // caption. nil-tolerant decode — old rows keep working; the
    // WorkoutPreview header falls back to the bare ×N + parent
    // distance when nil. Mirrors the `note` field that the parser
    // emits on `RepGroup` for the same reason (WorkoutPreview.swift
    // header HStack renders it in italic at line 461).
    var note: String?
    // V0.54 S2.2: build/descend (increasing intensity) descriptor
    // ("1-4", "1=70% 2=75% 3=80% 4=~85%"). Drives the Mode 3
    // ProgressionRepCard ladder — without this field the renderer
    // has no way to know it's a per-rep progression and falls back
    // to a flat percent-range one-liner. nil-tolerant decode; the
    // Mode 3 ladder only fires when both `descend` AND
    // `perRepTargets` are populated (per the existing
    // `perRepTargets(for:)` helper in WorkoutPreview.swift).
    var descend: String?
    // V0.54 S2.2: explicit per-rep target labels for the Mode 3
    // ladder chevrons + per-rep targets. Server emits when the
    // parser detected an explicit per-rep progression (e.g.
    // Descend: 1=N% 2=N% ...). When nil, the renderer synthesises
    // from `descend` + intensity percent range, or falls back to
    // chevron-only (WorkoutPreview's `perRepTargets(for:)` helper).
    // Key is `per_rep_targets` to match the existing ParsedRepGroup
    // decoder convention (WorkoutPreview.swift:1174).
    var perRepTargets: [String]?
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case workoutId = "workout_id"
        case orderIndex = "order_index"
        case reps
        case distance
        case stroke
        case intervalText = "interval_text"
        case intensityType = "intensity_type"
        case intensityLabel = "intensity_label"
        case zoneTerm = "zone_term"
        case paceTargetDistance = "pace_target_distance"
        case gear
        case suit
        case startType = "start_type"
        case dive
        case fragments
        // V0.54 S2.2: optional display-fidelity + Mode 3 ladder fields.
        // Same snake_case convention as the existing keys above; the
        // builder maps them straight into ParsedRepGroup.
        case note, descend
        case perRepTargets = "per_rep_targets"
        case createdAt = "created_at"
    }

    /// Human-readable label, e.g. "4×100 Free @ threshold"
    var label: String {
        var parts: [String] = []
        if let reps = reps, let distance = distance {
            parts.append("\(reps)×\(distance)m")
        } else if let distance = distance {
            parts.append("\(distance)m")
        }
        if let stroke = stroke { parts.append(stroke) }
        if let intensityLabel = intensityLabel { parts.append("@ \(intensityLabel)") }
        return parts.isEmpty ? "Set" : parts.joined(separator: " ")
    }

    // V0.54 S2.2 (2026-09-09, jodie-09 Console parse fidelity):
    // explicit memberwise init with defaults for the new optional
    // fields. Swift's auto-synthesized memberwise init would NOT
    // have defaults (it always emits `var` / `let` storage as
    // required parameters), which would break the 6+ existing
    // WorkoutSet construction sites that don't pass note/descend/
    // perRepTargets (SessionConsoleViewModel's set() helper,
    // TimingViewModel.syntheticWorkoutSet, TodayView.WorkoutCard
    // fixture, etc). Defining this init shadows the auto-synth
    // — every existing call site continues to compile (the new
    // fields default to nil), and the four jodie-09 seed call sites
    // can pass them when they need to.
    init(
        id: String,
        workoutId: String,
        orderIndex: Int,
        reps: Int? = nil,
        distance: Int? = nil,
        stroke: String? = nil,
        intervalText: String? = nil,
        intensityType: String? = nil,
        intensityLabel: String? = nil,
        zoneTerm: String? = nil,
        paceTargetDistance: Int? = nil,
        gear: [String]? = nil,
        suit: Bool? = nil,
        startType: String? = nil,
        dive: Bool? = nil,
        fragments: [WorkoutSetFragment]? = nil,
        note: String? = nil,
        descend: String? = nil,
        perRepTargets: [String]? = nil,
        createdAt: String
    ) {
        self.id = id
        self.workoutId = workoutId
        self.orderIndex = orderIndex
        self.reps = reps
        self.distance = distance
        self.stroke = stroke
        self.intervalText = intervalText
        self.intensityType = intensityType
        self.intensityLabel = intensityLabel
        self.zoneTerm = zoneTerm
        self.paceTargetDistance = paceTargetDistance
        self.gear = gear
        self.suit = suit
        self.startType = startType
        self.dive = dive
        self.fragments = fragments
        self.note = note
        self.descend = descend
        self.perRepTargets = perRepTargets
        self.createdAt = createdAt
    }
}