// _decimal-distance-fix.ts — ponytail (2026-09-08)
//
// Normalize fragment distances to integers before the parse-workout
// response leaves the edge function.
//
// Why: iOS `ParsedFragment.distance: Int?` cannot decode a JSON number
// with a fractional part (12.5, 37.5, 62.5, 87.5). The Swift
// JSONDecoder throws `DecodingError.dataCorrupted("The given data was
// not valid JSON.")` which the iOS app surfaces as
// "Server parse failed — using on-device fallback. The data couldn't
// be read because it is in the wrong format." The user saw this when
// entering a Jodie's threshold workout that contained a half-pool
// fragment (`4 x 25: 12.5 fast / 12.5 easy`).
//
// What this does:
//   - Walks every section → namedSet → repGroup → fragments[].
//   - Rounds each fragment.distance to the nearest integer using
//     Math.round (12.5 → 13, 37.5 → 38, 62.5 → 63, 87.5 → 88).
//   - Leaves null and already-integer distances untouched.
//   - Leaves repGroup.distance alone (always integer by construction).
//   - Leaves top-level Workout fields alone (none carry fragments).
//   - Tolerates null fragments arrays on repGroups (common case).
//
// Why Math.round (not banker's rounding, not floor, not trunc):
//   - Symmetric: 12.5 → 13 and 37.5 → 38 stay close to the half-pool
//     distance the coach wrote. Banker's rounding rounds 12.5 → 12
//     (to the nearest even) which reads as "the floor dropped a meter"
//     to a coach.
//   - Total fragment distance still sums to roughly the parent
//     repGroup.distance (within ±1m per fragment).
//
// The coach's exact wording ("12.5 fast / 12.5 easy") survives verbatim
// in the parent repGroup.sourceLine and the fragment's
// note/instruction — only the numeric distance field is rounded. The
// UI renders the source line, not the rounded number, so the coach
// reads back exactly what they typed.
//
// 4-place sync invariant (V0.47 §3): the canonical helper lives here
// (the deploy source). The bench re-uses it via a sibling
// _decimal-distance-fix.ts in scripts/parser-bench/. iOS continues to
// decode Int?; no Swift change is required by this fix.

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

export interface NormalizableWorkout {
  sections: SectionLike[];
}

export function normalizeFragmentDistances(workout: NormalizableWorkout): NormalizableWorkout {
  if (!workout?.sections) return workout;
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
