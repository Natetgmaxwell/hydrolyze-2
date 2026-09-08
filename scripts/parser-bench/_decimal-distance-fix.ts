// scripts/parser-bench/_decimal-distance-fix.ts
//
// ponytail (2026-09-08): round fragment distances to integers before
// serializing the parse-workout response.
//
// V0.53.3 (2026-09-08, jodie-09 display fidelity): also populate an
// optional `distance_label` string that carries the coach's exact
// source-text wording for the fragment's distance. Half-pool
// fragments (12.5, 37.5, 62.5, 87.5) preserve the decimal — the
// segment track reads "12.5m strong | 12.5m easy" instead of the
// rounded "13m strong | 13m easy". Integer fragments get their
// integer's string form ("25", "100"). The label is captured from
// the SAME float the helper rounds, at the round moment, so no
// sourceLine parsing is required.
//
// Why iOS `ParsedFragment.distance: Int?` cannot decode `12.5` — Swift
// JSONDecoder throws `DecodingError.dataCorrupted("The given data was
// not valid JSON.")` which surfaces to the user as
// "Server parse failed — using on-device fallback. The data couldn't be
// read because it's not in the right format." The coach's intent (12.5
// fast / 12.5 easy for a 25m rep split) is preserved verbatim in the
// parent repGroup.sourceLine and the fragment's note/instruction; only
// the numeric distance field is rounded. The label captures the verbatim
//// string for display.
//
// Why Math.round: 12.5 → 13, 37.5 → 38, 62.5 → 63. Symmetric — keeps
// total distance matching the parent repGroup.distance as closely as
// possible. Banker's rounding would round 12.5 → 12 (even) and 37.5 → 38
// — inconsistent and confusing for the coach.
//
// Scope:
//   - Touches only fragment.distance + fragment.distance_label
//     (Fragment.distance in TS, line 81 of index.ts).
//   - Does NOT touch repGroup.distance (always integer — parseRepDist
//     only emits decimals from the distance slot of `Nx D` patterns,
//     where D from `4 x 25` is 25).
//   - Does NOT touch fragment arrays at the top-level Workout level
//     (none in the current schema — top-level Workout doesn't carry
//     fragments, only sections.namedSets.repGroups do).
//   - Tolerates null fragments array on a repGroup (the common case
//     for non-composite sets).
//   - Tolerates null fragment.distance (time-based fragments); the
//     label also stays null in that case.
//
// Idempotent: running twice yields the same result (no double-rounding,
// no double-label).

interface FragmentLike {
  distance: number | null;
  distance_label?: string | null;
}

interface RepGroupLike {
  fragments: FragmentLike[] | null;
}

interface NamedSetLike {
  repGroups: RepGroupLike[];
}

interface SectionLike {
  namedSets: NamedSetLike[];
}

interface WorkoutLike {
  sections: SectionLike[];
}

export function normalizeFragmentDistances(workout: WorkoutLike): WorkoutLike {
  for (const section of workout.sections) {
    if (!section?.namedSets) continue;
    for (const namedSet of section.namedSets) {
      if (!namedSet?.repGroups) continue;
      for (const rg of namedSet.repGroups) {
        if (!rg?.fragments) continue;
        for (const frag of rg.fragments) {
          if (frag?.distance == null) {
            // V0.53.3: when distance is null (time-based fragment),
            // label is also null — keeps the wire shape predictable
            // for the iOS decoder.
            frag.distance_label = null;
            continue;
          }
          // Capture the verbatim label BEFORE rounding. String(12.5)
          // → "12.5", String(37.5) → "37.5", String(25) → "25". The
          // only float values the LLM emits are SWIM_DISTANCES
          // half-pools (12.5, 37.5, 62.5, 87.5) which round-trip
          // cleanly via String().
          frag.distance_label = String(frag.distance);
          if (Number.isInteger(frag.distance)) continue;
          frag.distance = Math.round(frag.distance);
        }
      }
    }
  }
  return workout;
}