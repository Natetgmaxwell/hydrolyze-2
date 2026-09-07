// scripts/parser-bench/_decimal-distance-fix.ts
//
// ponytail (2026-09-08): round fragment distances to integers before
// serializing the parse-workout response.
//
// Why: iOS `ParsedFragment.distance: Int?` cannot decode `12.5` — Swift
// JSONDecoder throws `DecodingError.dataCorrupted("The given data was
// not valid JSON.")` which surfaces to the user as
// "Server parse failed — using on-device fallback. The data couldn't be
// read because it's in the wrong format." The coach's intent (12.5
// fast / 12.5 easy for a 25m rep split) is preserved verbatim in the
// parent repGroup.sourceLine and the fragment's note/instruction; only
// the numeric distance field is rounded.
//
// Why Math.round: 12.5 → 13, 37.5 → 38, 62.5 → 63. Symmetric — keeps
// total distance matching the parent repGroup.distance as closely as
// possible. Banker's rounding would round 12.5 → 12 (even) and 37.5 → 38
// — inconsistent and confusing for the coach.
//
// Scope:
//   - Touches only fragment.distance (Fragment.distance in TS, line 81
//     of index.ts).
//   - Does NOT touch repGroup.distance (always integer — parseRepDist
//     only emits decimals from explicit `Nx D` patterns where D is a
//     recognised half-pool distance; parent set totals are still int).
//   - Does NOT touch fragment arrays at the top-level Workout level
//     (none in the current schema — top-level Workout doesn't carry
//     fragments, only sections.namedSets.repGroups do).
//   - Tolerates null fragments array on a repGroup (the common case
//     for non-composite sets).
//   - Tolerates null fragment.distance (time-based fragments).
//
// Idempotent: running twice yields the same result (no double-rounding).

interface FragmentLike {
  distance: number | null;
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
          if (frag?.distance == null) continue;
          if (Number.isInteger(frag.distance)) continue;
          frag.distance = Math.round(frag.distance);
        }
      }
    }
  }
  return workout;
}
