// _decimal-distance-fix.ts — ponytail (2026-09-08)
//
// Normalize fragment distances to integers before the parse-workout
// response leaves the edge function.
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
// Why iOS `ParsedFragment.distance: Int?` cannot decode a JSON number
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
//   - Populates fragment.distance_label with the verbatim string form
//     of the original fragment.distance (e.g. "12.5", "37.5", "25").
//     iOS uses this for display fidelity; the int distance remains the
//     wire type (no floats on the wire).
//   - Leaves null distances alone — no label set when distance is null
//     (time-based fragments have no distance, no label).
//   - Leaves null fragments arrays on repGroups alone.
//   - Leaves repGroup.distance alone (always integer by construction).
//   - Leaves top-level Workout fields alone (none carry fragments).
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
// note/instruction — the round only touches the numeric distance
// field. The new distance_label field carries the same verbatim string
// to iOS for display.
//
// 4-place sync invariant (V0.47 §3): the canonical helper lives here
// (the deploy source). The bench re-uses it via a sibling
// _decimal-distance-fix.ts in scripts/parser-bench/. iOS continues to
// decode Int?; no Swift change is required by this fix.

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