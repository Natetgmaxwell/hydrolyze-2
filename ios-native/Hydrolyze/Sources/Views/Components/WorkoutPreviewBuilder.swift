import Foundation

/// WorkoutPreviewBuilder — maps a DB-row `Workout` + its `WorkoutSet`s
/// into the `ParsedWorkout` shape that `WorkoutPreview` consumes.
///
/// V0.54 S2.1 (2026-09-08, jodie-09 user feedback): the Session
/// Console's PRE + LIVE bodies now render the full `WorkoutPreview`
/// (rep cards × modes, fragment rows, captions, send-offs) instead
/// of flat set-row one-liners. The Console needs the same parsed-
/// workout tree `WorkoutDetailView` builds for its preview surface.
///
/// Extracting this helper here means:
///
///   - The Console and `WorkoutDetailView` cannot drift in how they
///     map DB rows to ParsedRepGroup/ParsedFragment. A parser-side
///     field rename (e.g. `intensity_type → intensity_kind`) needs
///     exactly one site to change.
///   - The mapping logic stays with the consumer view that owns the
///     visual contract, not buried in a service.
///   - Other callers (e.g. future POST summary) can reuse the same
///     builder without re-implementing the fragment-mapping rules.
///
/// The function is a static helper — no state, no DI. The legacy
/// V0.55 S1: WorkoutDetailView + WorkoutBuilderView both render
/// through `WorkoutStructureView` (Views/Workouts/
/// WorkoutStructureView.swift), which calls this static helper for
/// the DB-row → ParsedWorkout projection. The two surfaces cannot
/// drift — there's exactly one projection site, one renderer. Before
/// S1 the detail view used a private `buildParsedWorkout(from:sets:)`
/// wrapper here; S1 deleted that wrapper in favour of routing
/// through the shared render component.
enum WorkoutPreviewBuilder {
    /// Build the parsed-workout tree that `WorkoutPreview` renders.
    /// Single section, one named set, one rep group per `WorkoutSet`.
    static func fromWorkoutAndSets(_ workout: Workout, sets: [WorkoutSet]) -> ParsedWorkout {
        ParsedWorkout(
            title: workout.title,
            sections: [
                ParsedSection(
                    title: nil,
                    namedSets: [
                        ParsedNamedSet(
                            label: nil,
                            note: nil,
                            repGroups: sets.map { set in
                                // t_d59998d9 (2026-08-05): map the
                                // WorkoutSet's parsed leaf fragments into
                                // the ParsedRepGroup so FragmentCTARow
                                // renders. nil/empty fragments falls through
                                // to the static label path (unchanged from
                                // t_c74dffbc). The pace target reads from
                                // the parent set's intervalText, which is
                                // what the row's "pace target badge" wants.
                                let parsedFragments: [ParsedFragment]? = set.fragments?.map { f in
                                    let intensityType = ParsedIntensityType(rawValue: f.intensity) ?? .easy
                                    let intensity: ParsedIntensity? = (f.intensity == "unknown" || f.intensity.isEmpty)
                                        ? nil
                                        : ParsedIntensity(type: intensityType, label: f.intensity)
                                    // V0.54 S2.2 (2026-09-09, jodie-09
                                    // Console parse fidelity): forward
                                    // (a) `distance_label` verbatim
                                    // source-text — round-trips the
                                    // V0.53.3 server fix through the
                                    // DB-row shape so the segment
                                    // renders "12.5m" instead of "13m";
                                    // (b) `intensity_label` (coach's
                                    // verbatim word like "race rhythm")
                                    // — overrides the type-token label
                                    // ("race_pace") that
                                    // `ParsedIntensity(label:)` carries.
                                    return ParsedFragment(
                                        id: f.id,
                                        distance: f.distanceMeters,
                                        distanceLabel: f.distanceLabel,
                                        stroke: set.stroke,
                                        instruction: nil,
                                        intensity: intensity,
                                        intensityType: intensityType.rawValue,
                                        // V0.54 S2.2: prefer the coach's
                                        // verbatim word; fall back to the
                                        // parser type token when the
                                        // server didn't emit the verbatim
                                        // label. The segment renderer
                                        // (WorkoutPreview.segmentLabel)
                                        // picks `intensityLabel` first
                                        // when non-nil/non-empty.
                                        intensityLabel: f.intensityLabel ?? (f.intensity == "unknown" ? nil : f.intensity),
                                        startType: f.startType,
                                        suit: nil,
                                        gear: nil,
                                        descriptor: nil,
                                        confidence: f.confidence
                                    )
                                }
                                return ParsedRepGroup(
                                    reps: set.reps,
                                    distance: set.distance,
                                    stroke: set.stroke,
                                    interval: set.intervalText,
                                    intensity: set.intensityLabel.map {
                                        ParsedIntensity(
                                            type: ParsedIntensityType(rawValue: set.intensityType ?? "easy") ?? .easy,
                                            label: $0
                                        )
                                    },
                                    pacing: nil,
                                    pattern: [],
                                    patternType: nil,
                                    connectors: nil,
                                    // V0.54 S2.2: forward the
                                    // set-level note ("Each: 50 @
                                    // 65% / 70% / 75%") — the existing
                                    // WorkoutPreview header HStack
                                    // renders it in italic at line 461
                                    // once it lands.
                                    note: set.note,
                                    gear: set.gear,
                                    gearOptional: false,
                                    // V0.54 S2.2: forward the build/
                                    // descend descriptor and per-rep
                                    // targets so the Mode 3
                                    // ProgressionRepCard ladder fires
                                    // (WorkoutPreview.swift:2882 + the
                                    // `perRepTargets(for:)` helper).
                                    descend: set.descend,
                                    details: nil,
                                    dive: set.dive,
                                    suit: set.suit,
                                    ambiguousTerm: nil,
                                    fragments: parsedFragments,
                                    // V0.41 (2026-08-18): round-trip the
                                    // persisted set-level zone term so the
                                    // builder preview (Slice 3) and timing
                                    // flow (Slice 2) read it back.
                                    zoneTerm: set.zoneTerm,
                                    // V0.54 S2.2: forward per-rep
                                    // target labels so the Mode 3
                                    // ProgressionRepCard ladder fires
                                    // (WorkoutPreview.swift:2882 + the
                                    // `perRepTargets(for:)` helper).
                                    perRepTargets: set.perRepTargets,
                                    // V0.54 S2.1 (2026-09-08, jodie-09
                                    // Console elevation): forward the parent
                                    // WorkoutSet.id so the Session Console's
                                    // LIVE body can identify the current set
                                    // (border + scale + accent bg) and the
                                    // completed sets (reduced opacity) by
                                    // their DB identity, not by display
                                    // position.
                                    setId: set.id
                                )
                            }
                        )
                    ]
                )
            ]
        )
    }
}
