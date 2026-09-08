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
/// `WorkoutDetailView.buildParsedWorkout(from:sets:)` instance
/// method is delegated to this static helper so behaviour stays
/// identical.
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
                                    return ParsedFragment(
                                        id: f.id,
                                        distance: f.distanceMeters,
                                        stroke: set.stroke,
                                        instruction: nil,
                                        intensity: intensity,
                                        intensityType: intensityType.rawValue,
                                        intensityLabel: f.intensity == "unknown" ? nil : f.intensity,
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
                                    note: nil,
                                    gear: set.gear,
                                    gearOptional: false,
                                    descend: nil,
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
