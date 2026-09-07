// scripts/parser-bench/decimal-distance-fix.test.ts
//
// TDD test for the iOS decode-failure fix (2026-09-08):
//
// The live parse-workout Edge Function emits fragment.distance as a JSON
// number. When the LLM splits a 25m rep into two halves (e.g.
// `4 x 25: 12.5 fast / 12.5 easy`), the fragment distance becomes 12.5.
// Swift's `ParsedFragment.distance: Int?` decoder rejects this with
// `DecodingError.dataCorrupted("The given data was not valid JSON.")` —
// the exact error string the user sees on Jodie's threshold workouts
// that contain half-pool fragments.
//
// Fix: the edge function must normalize fragment distances to integers
// before serializing the response. The coach's exact wording (12.5,
// 37.5) is preserved in note/sourceLine/instruction — only the numeric
// distance field is rounded. The parent repGroup.distance is always
// integer by construction (parseRepDist only emits decimals from the
// distance slot of `Nx D` patterns, and D from `4 x 25` is 25).
//
// This test exercises the normalization helper directly. After the fix
// lands, `normalizeFragmentDistances` is called from parseWithFallback
// (or the response builder) on every parse result before JSON
// serialization.

import assert from "node:assert/strict";
import { normalizeFragmentDistances } from "./_decimal-distance-fix";

function makeFragment(distance: number | null, label: string) {
  return {
    id: `frag-${label}`,
    distance,
    stroke: null,
    instruction: null,
    intensity: null,
    gear: null,
    start_type: null as "dive" | "push" | "wall" | null,
    order: 0,
  };
}

// RED test 1: half-pool fragment gets rounded to integer.
{
  const input = {
    title: null,
    sections: [
      {
        title: "Threshold",
        namedSets: [
          {
            label: null,
            note: null,
            repGroups: [
              {
                reps: 4,
                distance: 25,
                stroke: null,
                interval: "0:45",
                intensity: null,
                zoneTerm: null,
                pacing: null,
                pattern: [],
                patternType: null,
                connectors: [],
                note: null,
                gear: null,
                gearOptional: false,
                descend: null,
                details: null,
                dive: false,
                suit: false,
                ambiguousTerm: null,
                defaultRpe: null,
                fragments: [
                  makeFragment(12.5, "fast"),
                  makeFragment(12.5, "easy"),
                ],
                sourceLine: "4 x 25: 12.5 fast / 12.5 easy",
              },
            ],
          },
        ],
      },
    ],
  };
  const out = normalizeFragmentDistances(input);
  const fragments = out.sections[0].namedSets[0].repGroups[0].fragments!;
  assert.equal(
    fragments[0].distance,
    13,
    "12.5 should round to 13 (Math.round)",
  );
  assert.equal(fragments[1].distance, 13);
  // Source line still carries the precise wording — coach intent preserved.
  assert.equal(
    out.sections[0].namedSets[0].repGroups[0].sourceLine,
    "4 x 25: 12.5 fast / 12.5 easy",
  );
  console.log("OK: half-pool fragment distance rounded to 13");
}

// RED test 2: 37.5 rounds to 38 (banker's rounding NOT applied — Math.round is symmetric).
{
  const input = {
    title: null,
    sections: [
      {
        title: null,
        namedSets: [
          {
            label: null,
            note: null,
            repGroups: [
              {
                reps: 2,
                distance: 75,
                stroke: null,
                interval: null,
                intensity: null,
                zoneTerm: null,
                pacing: null,
                pattern: [],
                patternType: null,
                connectors: [],
                note: null,
                gear: null,
                gearOptional: false,
                descend: null,
                details: null,
                dive: false,
                suit: false,
                ambiguousTerm: null,
                defaultRpe: null,
                fragments: [
                  makeFragment(37.5, "build1"),
                  makeFragment(37.5, "build2"),
                ],
                sourceLine: "2 x 75: 37.5 build / 37.5 easy",
              },
            ],
          },
        ],
      },
    ],
  };
  const out = normalizeFragmentDistances(input);
  const fragments = out.sections[0].namedSets[0].repGroups[0].fragments!;
  assert.equal(fragments[0].distance, 38);
  assert.equal(fragments[1].distance, 38);
  console.log("OK: 37.5 rounds to 38");
}

// RED test 3: already-integer fragment distance is unchanged (no-op for the common case).
{
  const input = {
    title: null,
    sections: [
      {
        title: null,
        namedSets: [
          {
            label: null,
            note: null,
            repGroups: [
              {
                reps: 1,
                distance: 100,
                stroke: null,
                interval: null,
                intensity: null,
                zoneTerm: null,
                pacing: null,
                pattern: [],
                patternType: null,
                connectors: [],
                note: null,
                gear: null,
                gearOptional: false,
                descend: null,
                details: null,
                dive: false,
                suit: false,
                ambiguousTerm: null,
                defaultRpe: null,
                fragments: [
                  makeFragment(75, "fast"),
                  makeFragment(25, "easy"),
                ],
                sourceLine: "100: 75 fast / 25 easy",
              },
            ],
          },
        ],
      },
    ],
  };
  const out = normalizeFragmentDistances(input);
  const fragments = out.sections[0].namedSets[0].repGroups[0].fragments!;
  assert.equal(fragments[0].distance, 75);
  assert.equal(fragments[1].distance, 25);
  console.log("OK: integer fragments unchanged");
}

// RED test 4: null fragment distance stays null (e.g. time-based fragments).
{
  const input = {
    title: null,
    sections: [
      {
        title: null,
        namedSets: [
          {
            label: null,
            note: null,
            repGroups: [
              {
                reps: 1,
                distance: 100,
                stroke: null,
                interval: null,
                intensity: null,
                zoneTerm: null,
                pacing: null,
                pattern: [],
                patternType: null,
                connectors: [],
                note: null,
                gear: null,
                gearOptional: false,
                descend: null,
                details: null,
                dive: false,
                suit: false,
                ambiguousTerm: null,
                defaultRpe: null,
                fragments: [
                  makeFragment(100, "swim"),
                  makeFragment(null, "rest"),
                ],
                sourceLine: "100 swim + rest",
              },
            ],
          },
        ],
      },
    ],
  };
  const out = normalizeFragmentDistances(input);
  const fragments = out.sections[0].namedSets[0].repGroups[0].fragments!;
  assert.equal(fragments[0].distance, 100);
  assert.equal(fragments[1].distance, null);
  console.log("OK: null fragment distance preserved");
}

// RED test 5: nested parse (top-level parse() returns object with
// fragments keyed at the LLM level, not just in repGroups). The function
// must also normalize the top-level Workout.fragments array if present.
{
  const input = {
    title: null,
    sections: [
      {
        title: null,
        namedSets: [
          {
            label: null,
            note: null,
            repGroups: [
              {
                reps: 4,
                distance: 25,
                stroke: null,
                interval: null,
                intensity: null,
                zoneTerm: null,
                pacing: null,
                pattern: [],
                patternType: null,
                connectors: [],
                note: null,
                gear: null,
                gearOptional: false,
                descend: null,
                details: null,
                dive: false,
                suit: false,
                ambiguousTerm: null,
                defaultRpe: null,
                fragments: null,
                sourceLine: "4 x 25",
              },
            ],
          },
        ],
      },
    ],
  };
  const out = normalizeFragmentDistances(input);
  // Should not throw on null fragments array.
  assert.equal(out.sections[0].namedSets[0].repGroups[0].fragments, null);
  console.log("OK: null repGroup.fragments tolerated");
}

console.log("All decimal-distance-fix tests passed.");
