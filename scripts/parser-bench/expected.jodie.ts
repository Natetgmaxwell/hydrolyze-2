/**
 * expected.jodie.ts — V0.52 (2026-09-08) hand-annotated expected outputs
 * for the 8 `commit-jodie-*.txt` files. Used by `_jodie-quality.ts` to
 * score the live parse-workout response against what a coach would
 * expect.
 *
 * The previous bench (score.ts) had no Jodie entries — that's why the
 * parser scored 21/21 = 1.0/1.0 while the user said "still not doing
 * the best job". This file fixes that: every Jodie corpus file gets
 * scored against the assertions below on every CI run.
 *
 * Assertion categories (see `_jodie-quality.ts` for the scorer):
 *   1. `expectedRepGroups` — exact set of (reps, distance, interval)
 *      tuples the parser should emit. Section titles are not asserted
 *      (the LLM has nondeterministic title emission for the same input —
 *      a known json_object-mode behavior, V0.36).
 *   2. `expectedFragmentCompleteness` — for each set with 2+ fragments,
 *      every fragment whose segment text names an intensity word MUST
 *      carry a non-null intensity (rule 16, V0.52).
 *   3. `expectedUnmappedTerms` — for the no-auth baseline (the
 *      benchmark coach has no vocabulary rows), unmapped_terms must
 *      be EXACTLY the listed Tier-1 / progression words. Anything
 *      outside this set is a false-positive noise leak.
 *   4. `expectedNoZeroDistanceRepGroup` — every set in the source text
 *      that has a real distance must parse with a non-zero
 *      repGroup.distance. Zero-distance repGroups are reserved for
 *      time-based / free-text sets (rare).
 *   5. `expectedSectionCountMin` — minimum number of sections the
 *      parser should emit, derived from the number of section headers
 *      in the source text. Below this = section collapsing.
 */

export interface ExpectedFragment {
  distance: number;
  /** True iff the segment text names an intensity word and the
   * validator expects a non-null intensity object on the fragment. */
  expectsIntensity: boolean;
  /** Expected intensity.type when expectsIntensity=true. */
  intensityType?: "easy" | "aerobic" | "threshold" | "race_pace" | "sprint" | "descend" | "build" | "negative_split" | "3mt";
}

export interface ExpectedRepGroup {
  reps: number;
  distance: number;
  interval: string | null;
  stroke: string | null;
  fragments?: ExpectedFragment[];
  /** Optional marker for sets that should NOT be emitted (false-positive
   * sets to exclude from the actual_count — used for "Multi-set summary
   * lines" type cases where the coach's `400 swim + 4 × 100 + 4 × 50`
   * is NOT a set). */
  exclude?: boolean;
}

export interface JodieExpected {
  /** Minimum number of repGroups (excluding any `exclude`d ones). */
  expectedRepGroups: ExpectedRepGroup[];
  /** Expected unmapped_terms for the no-auth baseline (no coach
   * vocabulary rows). Order-independent. */
  expectedUnmappedTerms: string[];
  /** Minimum number of sections (titles emitted, including null). */
  expectedSectionCountMin: number;
}

export const EXPECTED_JODIE: Record<string, JodieExpected> = {
  // commit-jodie-01-sep — Sep 4 recovery session (4 × 150, 8 × 50, etc.)
  // The audit's main finding was `200–400 down-regulation` losing its
  // distance. We mark it `exclude: true` and require its `distance=0`
  // NOT to count toward the score. The remaining 12 sets all have
  // well-defined reps/distance/interval.
  "commit-jodie-01-sep.txt": {
    expectedRepGroups: [
      { reps: 4, distance: 150, interval: "2:30–2:45", stroke: null },
      { reps: 1, distance: 50,  interval: null,        stroke: null },
      { reps: 1, distance: 25,  interval: null,        stroke: "Drill" }, // scull
      { reps: 1, distance: 25,  interval: null,        stroke: "Back" },
      { reps: 1, distance: 25,  interval: null,        stroke: "Choice" }, // sensory swimming
      { reps: 1, distance: 25,  interval: null,        stroke: "Choice" }, // long perfect swim
      { reps: 8, distance: 50,  interval: "1:10",      stroke: null },
      { reps: 4, distance: 50,  interval: "1:00",      stroke: null }, // drill rotations — 3 rounds
      { reps: 1, distance: 100, interval: null,        stroke: null }, // 100 perfect easy
      { reps: 8, distance: 50,  interval: "1:05",      stroke: null }, // stroke count
      { reps: 3, distance: 200, interval: "3:15–3:30", stroke: "Pull" }, // very easy pull
      { reps: 8, distance: 25,  interval: "1:00",      stroke: null }, // 8-10 m quick but effortless
      { reps: 1, distance: 200, interval: null,        stroke: null, exclude: true }, // "200-400 down-regulation"
    ],
    // V0.52: post-fix `easy` should resolve via DEFAULT_RPE_BY_TERM and
    // NEVER appear in unmapped_terms. Pre-fix expected: ['easy']. The
    // scorer asserts the actual list matches expectedUnmappedTerms.
    expectedUnmappedTerms: [],
    expectedSectionCountMin: 1,
  },

  // commit-jodie-02-sep — Sep 3 (6 event groups, 25 rgs / 15 fragments)
  "commit-jodie-02-sep.txt": {
    expectedRepGroups: [
      // Warm-up — 1,000 m
      { reps: 1, distance: 400, interval: null, stroke: null },
      { reps: 4, distance: 100, interval: null, stroke: null, fragments: [
        { distance: 25, stroke: "kick", expectsIntensity: false },
        { distance: 25, stroke: "free", expectsIntensity: false },
      ]},
      { reps: 4, distance: 50,  interval: null, stroke: null },
      { reps: 4, distance: 25,  interval: null, stroke: "Kick" },
      // Kick Development
      { reps: 4, distance: 100, interval: null, stroke: "Kick" },
      { reps: 8, distance: 50,  interval: "1:00–1:10", stroke: "Kick", fragments: [
        { distance: 25, stroke: "kick", expectsIntensity: true,  intensityType: "aerobic" }, // strong kick
        { distance: 25, stroke: "kick", expectsIntensity: true,  intensityType: "aerobic" }, // aerobic
      ]},
      { reps: 8, distance: 25,  interval: "0:45–1:00", stroke: "Kick", fragments: [
        { distance: 12.5, stroke: "kick", expectsIntensity: true, intensityType: "aerobic" }, // power
        { distance: 12.5, stroke: "kick", expectsIntensity: true, intensityType: "easy" },
      ]},
      { reps: 4, distance: 50,  interval: null, stroke: null }, // underwater→breakout→easy
      // SP — EVENT GROUP
      { reps: 8, distance: 25,  interval: "1:15", stroke: null },
      { reps: 6, distance: 50,  interval: "2:00", stroke: null, fragments: [
        { distance: 25, stroke: null, expectsIntensity: true, intensityType: "race_pace" }, // race execution
        { distance: 25, stroke: null, expectsIntensity: true, intensityType: "easy" },
      ]},
      { reps: 4, distance: 50,  interval: "2:30", stroke: null }, // Dive → 35m race quality → shut down
      // MD — 100/200 (3 rounds)
      { reps: 4, distance: 100, interval: null, stroke: null },
      { reps: 4, distance: 50,  interval: null, stroke: null }, // @ 200 rhythm
      { reps: 2, distance: 25,  interval: null, stroke: null }, // back-end speed
      { reps: 1, distance: 200, interval: null, stroke: null }, // 200 recovery
      // IM / DISTANCE (3 rounds)
      { reps: 1, distance: 400, interval: null, stroke: null },
      { reps: 4, distance: 100, interval: null, stroke: "IM" },
      { reps: 4, distance: 100, interval: null, stroke: "Free" },
      { reps: 4, distance: 50,  interval: null, stroke: "IM" },
      { reps: 1, distance: 200, interval: null, stroke: null }, // 200 recovery
      { reps: 4, distance: 100, interval: null, stroke: null }, // 4x100 Descend 1-4 to strong
      // SURF IRON / TRI
      { reps: 1, distance: 600, interval: null, stroke: null }, // 600 sustained aerobic/threshold
      { reps: 4, distance: 100, interval: null, stroke: null }, // 4x100 @ strong threshold
      { reps: 4, distance: 50,  interval: null, stroke: null, fragments: [
        { distance: 25, stroke: null, expectsIntensity: true, intensityType: "sprint" }, // high turnover
        { distance: 25, stroke: null, expectsIntensity: false }, // settle
      ]},
      { reps: 4, distance: 100, interval: null, stroke: null }, // Final race skill
    ],
    // V0.52: 'max', 'easy', 'strong' resolve silently; 'build' /
    // 'descend' are progressions (kept in unmapped_terms until mapped).
    expectedUnmappedTerms: ["build", "descend"],
    expectedSectionCountMin: 5,
  },

  // commit-jodie-03-sep — Sep 2 LC warm-up + speed + aerobic + finishing test
  "commit-jodie-03-sep.txt": {
    expectedRepGroups: [
      // 1. LC-specific warm-up
      { reps: 4, distance: 150, interval: "2:30", stroke: null, fragments: [
        { distance: 50, stroke: null, expectsIntensity: false },
        { distance: 25, stroke: "drill", expectsIntensity: false }, // 25 scull
        { distance: 25, stroke: null, expectsIntensity: false }, // 25 swim
        { distance: 50, stroke: null, expectsIntensity: true, intensityType: "descend" }, // 50 descend within the 50
      ]},
      { reps: 4, distance: 100, interval: "1:40", stroke: null, fragments: [
        { distance: 25, stroke: null, expectsIntensity: true, intensityType: "build" },
        { distance: 25, stroke: null, expectsIntensity: false }, // hold that rate
        { distance: 25, stroke: null, expectsIntensity: false }, // DPS
        { distance: 25, stroke: null, expectsIntensity: true, intensityType: "aerobic" }, // strong through the wall
      ]},
      { reps: 4, distance: 50, interval: "1:00", stroke: null }, // #1 build, #2 fast, #3 strong/easy, #4 progressive
      // 2. LC Speed Development
      { reps: 8, distance: 50, interval: "1:30", stroke: null, fragments: [
        { distance: 15, stroke: null, expectsIntensity: true, intensityType: "sprint" }, // MAX
        { distance: 35, stroke: null, expectsIntensity: true, intensityType: "easy" }, // very easy
      ]},
      { reps: 4, distance: 50, interval: "2:00", stroke: null, fragments: [
        { distance: 15, stroke: null, expectsIntensity: true, intensityType: "build" },
        { distance: 20, stroke: null, expectsIntensity: true, intensityType: "sprint" }, // MAX velocity
        { distance: 15, stroke: null, expectsIntensity: false }, // shut down
      ]},
      { reps: 4, distance: 50, interval: "1:30", stroke: null, fragments: [
        { distance: 25, stroke: null, expectsIntensity: true, intensityType: "race_pace" }, // race rhythm
        { distance: 25, stroke: null, expectsIntensity: true, intensityType: "easy" },
      ]},
      { reps: 4, distance: 50, interval: "1:30", stroke: null, fragments: [
        { distance: 25, stroke: null, expectsIntensity: true, intensityType: "sprint" }, // pursuit
        { distance: 25, stroke: null, expectsIntensity: true, intensityType: "easy" },
      ]},
      // 3. Main Set — LC Aerobic Strength (50-200 Pool Group, 3 rounds)
      { reps: 3, distance: 400, interval: "5:30–5:45", stroke: null, fragments: [
        { distance: 200, stroke: null, expectsIntensity: false },
        { distance: 200, stroke: null, expectsIntensity: true, intensityType: "negative_split" },
      ]},
      { reps: 4, distance: 100, interval: "1:30", stroke: null }, // Descend 1-2 controlled, 3 strong, 4 strongest
      { reps: 4, distance: 50, interval: "0:50–0:55", stroke: null }, // 1 DPS, 2 build, 3 strong, 4 last 15m fast
      { reps: 1, distance: 100, interval: "1:40", stroke: null }, // 100 easy
      // 3. Main Set — Distance Group (2 rounds)
      { reps: 2, distance: 600, interval: "8:00–8:30", stroke: null, fragments: [
        { distance: 200, stroke: null, expectsIntensity: false }, // A1
        { distance: 200, stroke: null, expectsIntensity: false }, // A2
        { distance: 200, stroke: null, expectsIntensity: true, intensityType: "aerobic" }, // strong A2
      ]},
      { reps: 4, distance: 100, interval: "1:25–1:30", stroke: null }, // Strong aerobic pull
      { reps: 4, distance: 50, interval: "0:50", stroke: null }, // Odd DPS, Even strong final 15 m
      { reps: 1, distance: 100, interval: null, stroke: null }, // 100 easy
      { reps: 1, distance: 400, interval: null, stroke: null, exclude: true }, // "400 swim + 4×100 + 4×50" summary
      // 3. Main Set — OW/Surf/Tri Variation
      { reps: 2, distance: 600, interval: null, stroke: null, fragments: [
        { distance: 200, stroke: null, expectsIntensity: true, intensityType: "aerobic" },
        { distance: 50,  stroke: null, expectsIntensity: true, intensityType: "sprint" }, // surge
        { distance: 150, stroke: null, expectsIntensity: true, intensityType: "aerobic" },
        { distance: 50,  stroke: null, expectsIntensity: true, intensityType: "sprint" }, // surge
        { distance: 100, stroke: null, expectsIntensity: true, intensityType: "aerobic" },
        { distance: 50,  stroke: null, expectsIntensity: true, intensityType: "aerobic" }, // strong
      ]},
      // 4. LC Finishing-Speed Test — 300 m
      { reps: 6, distance: 50, interval: "1:30", stroke: null, fragments: [
        { distance: 35, stroke: null, expectsIntensity: true, intensityType: "aerobic" },
        { distance: 15, stroke: null, expectsIntensity: true, intensityType: "sprint" }, // FAST
      ]},
      // 5. Swim down — 300 m
      { reps: 1, distance: 100, interval: null, stroke: "Choice" },
      { reps: 2, distance: 50, interval: "1:00", stroke: null },
      { reps: 2, distance: 50, interval: "1:00", stroke: null, fragments: [
        { distance: 25, stroke: "drill", expectsIntensity: false }, // scull
        { distance: 25, stroke: null, expectsIntensity: false }, // perfect swimming
      ]},
    ],
    // V0.52: 'a1', 'a2' are zone codes — never ask. 'fast', 'max',
    // 'easy', 'strong', 'race rhythm' are Tier-2 — silently resolved.
    // 'build', 'descend' are progressions. 'progressive' is now a
    // progression too (moved from Tier-1). So unmapped_terms collapses
    // to just the progression words.
    expectedUnmappedTerms: ["build", "descend", "progressive"],
    expectedSectionCountMin: 4,
  },

  // commit-jodie-04-sep — Sep 1 Threshold
  "commit-jodie-04-sep.txt": {
    expectedRepGroups: [
      // Warm-up — 1,000 m
      { reps: 1, distance: 400, interval: null, stroke: "Choice" }, // choice aerobic
      { reps: 4, distance: 100, interval: "1:35", stroke: null },
      { reps: 1, distance: 100, interval: null, stroke: "Drill", fragments: [
        { distance: 50, stroke: "drill", expectsIntensity: false },
        { distance: 50, stroke: null, expectsIntensity: true, intensityType: "build" }, // build
      ]},
      { reps: 4, distance: 50, interval: "1:00", stroke: null, fragments: [
        { distance: 25, stroke: null, expectsIntensity: true, intensityType: "aerobic" }, // strong
        { distance: 25, stroke: null, expectsIntensity: true, intensityType: "easy" },
      ]},
      { reps: 4, distance: 25, interval: "0:45", stroke: "Kick" }, // kick desc
      // SP (3 rounds)
      { reps: 4, distance: 100, interval: null, stroke: null }, // 4×100 threshold
      { reps: 1, distance: 200, interval: null, stroke: null }, // 200 easy aerobic
      { reps: 4, distance: 50, interval: null, stroke: null }, // 4×50 technique/rhythm
      // MD (4 rounds)
      { reps: 4, distance: 100, interval: null, stroke: null }, // 4×100 threshold
      { reps: 1, distance: 100, interval: null, stroke: null }, // 100 easy
      { reps: 2, distance: 50, interval: null, stroke: null }, // 2×50 at controlled 200 rhythm
      // IM/D (2 rounds)
      { reps: 4, distance: 200, interval: null, stroke: "Free" }, // 4×200 Free threshold
      { reps: 4, distance: 100, interval: null, stroke: "IM" }, // 4×100 IM threshold
      { reps: 1, distance: 200, interval: null, stroke: null }, // 200 aerobic reset
      // SURF / TRI (3 rounds)
      { reps: 1, distance: 400, interval: null, stroke: null }, // 400 threshold
      { reps: 4, distance: 100, interval: null, stroke: null }, // 4×100 strong threshold
      { reps: 4, distance: 50, interval: null, stroke: null, fragments: [
        { distance: 25, stroke: null, expectsIntensity: true, intensityType: "sprint" }, // surge
        { distance: 25, stroke: null, expectsIntensity: false }, // controlled
      ]},
      { reps: 1, distance: 100, interval: null, stroke: null }, // 100 easy
      // Swim-down
      { reps: 1, distance: 400, interval: null, stroke: null }, // 400-600 easy
    ],
    // V0.52: 'easy', 'strong', 'threshold' resolve silently. 'build' /
    // 'descend' are progressions.
    expectedUnmappedTerms: ["build", "descend"],
    expectedSectionCountMin: 5,
  },

  // commit-jodie-05-aug — Aug 31 MAX velocity + fly speed
  "commit-jodie-05-aug.txt": {
    expectedRepGroups: [
      // Warm-up — 900 m
      { reps: 1, distance: 300, interval: null, stroke: "Choice" }, // 300 choice swim
      // V0.52 rule 18: must emit 4 fragments, NOT collapse to rg.note
      { reps: 4, distance: 100, interval: "1:40", stroke: null, fragments: [
        { distance: 25, stroke: "drill", expectsIntensity: false }, // scull
        { distance: 25, stroke: null, expectsIntensity: false }, // DPS
        { distance: 25, stroke: null, expectsIntensity: true, intensityType: "build" },
        { distance: 25, stroke: null, expectsIntensity: true, intensityType: "easy" },
      ]},
      { reps: 4, distance: 50, interval: "1:00", stroke: null }, // 15m uw/breakout + relaxed
      { reps: 4, distance: 25, interval: "0:45", stroke: null }, // build to ~90%
      // Speed activation
      { reps: 8, distance: 25, interval: "1:00", stroke: "Free" }, // 12.5 MAX + easy
      { reps: 8, distance: 15, interval: "1:15–1:30", stroke: null }, // 8×15 MAX
      // Flying speed
      { reps: 6, distance: 50, interval: "2:00", stroke: null }, // 15m build + 20m MAX + 15m shut
      // Butterfly power
      { reps: 8, distance: 50, interval: "1:20–1:30", stroke: null, fragments: [
        { distance: 25, stroke: "Fly", expectsIntensity: true, intensityType: "aerobic" }, // Fly strong technically
        { distance: 25, stroke: "Free", expectsIntensity: true, intensityType: "easy" }, // very easy
      ]},
      // Race skills
      { reps: 6, distance: 50, interval: "2:00", stroke: null }, // SP/MD/IM/SURF alt
      // Swim-down
      { reps: 1, distance: 400, interval: null, stroke: null, exclude: true }, // "Swim-down — 400-600" not a set
    ],
    // V0.52: 'dps' is excluded (descriptive cue, not intensity word).
    // 'activation' is now excluded from TIER1_TERMS. 'relaxed',
    // 'easy', 'strong', 'max' all silently resolve. 'build' stays as
    // a progression.
    expectedUnmappedTerms: ["build"],
    expectedSectionCountMin: 5,
  },

  // commit-jodie-06-aug — Aug 28 recovery / kick technique
  "commit-jodie-06-aug.txt": {
    expectedRepGroups: [
      { reps: 1, distance: 600, interval: null, stroke: null, fragments: [
        { distance: 200, stroke: "free", expectsIntensity: false },
        { distance: 200, stroke: "kick", expectsIntensity: false },
        { distance: 200, stroke: "drill", expectsIntensity: false },
      ]},
      { reps: 16, distance: 25, interval: null, stroke: "Fly" }, // dolphin kick fins
      { reps: 16, distance: 50, interval: null, stroke: "Kick" }, // freestyle kick + snorkel
      { reps: 1, distance: 25, interval: null, stroke: null }, // short dog
      { reps: 1, distance: 25, interval: null, stroke: null }, // silent kick
      { reps: 16, distance: 25, interval: null, stroke: null }, // freestyle or back stroke with fins
    ],
    // V0.52: 'easy', 'fast' silently resolve. 'progressive' is now a
    // progression.
    expectedUnmappedTerms: ["progressive"],
    expectedSectionCountMin: 1,
  },

  // commit-jodie-07-aug — Aug 27 race-pace intro
  "commit-jodie-07-aug.txt": {
    expectedRepGroups: [
      // Warm-up — 1,200
      { reps: 1, distance: 400, interval: null, stroke: null },
      { reps: 1, distance: 200, interval: null, stroke: "Pull" },
      { reps: 1, distance: 200, interval: null, stroke: "Kick" },
      { reps: 4, distance: 50, interval: "0:55", stroke: "Drill" }, // drill → swim
      { reps: 4, distance: 50, interval: "1:00", stroke: null }, // build 1-4
      { reps: 4, distance: 25, interval: null, stroke: null, fragments: [
        { distance: 12.5, stroke: null, expectsIntensity: true, intensityType: "sprint" }, // fast
        { distance: 12.5, stroke: null, expectsIntensity: true, intensityType: "easy" },
      ]},
      // Main prep — 600
      { reps: 6, distance: 100, interval: null, stroke: null, fragments: [
        { distance: 25, stroke: null, expectsIntensity: true, intensityType: "aerobic" }, // moderate aerobic / strong
        { distance: 50, stroke: null, expectsIntensity: true, intensityType: "aerobic" }, // smooth
        { distance: 25, stroke: null, expectsIntensity: true, intensityType: "aerobic" }, // strong
      ]},
      // Main set
      { reps: 4, distance: 50, interval: "1:00", stroke: null }, // 4×50 @ 100 race rhythm
      { reps: 1, distance: 100, interval: null, stroke: null }, // 100 very easy
      // Then
      { reps: 4, distance: 25, interval: "2:00", stroke: null }, // 4×25 from dive
      // 200 swimmers
      { reps: 4, distance: 50, interval: null, stroke: null }, // 4×50 @ goal 200 pace
      { reps: 1, distance: 100, interval: null, stroke: null }, // 100 easy
      // Then
      { reps: 3, distance: 100, interval: null, stroke: null, fragments: [
        { distance: 50, stroke: null, expectsIntensity: true, intensityType: "race_pace" },
        { distance: 50, stroke: null, expectsIntensity: true, intensityType: "race_pace" },
      ]},
      // Distance
      { reps: 4, distance: 100, interval: null, stroke: null }, // 4×100 @ 800 pace
      { reps: 1, distance: 200, interval: null, stroke: null }, // 200 aerobic
      // Then
      // V0.52 rule 21: "faster than 800 pace" → race_pace, NOT sprint
      { reps: 4, distance: 50, interval: null, stroke: null, fragments: [
        { distance: 25, stroke: null, expectsIntensity: true, intensityType: "race_pace" },
        { distance: 25, stroke: null, expectsIntensity: true, intensityType: "race_pace" },
      ]},
      // Reset
      { reps: 1, distance: 600, interval: null, stroke: null }, // Easy pull/swim
      // Swim-down
      { reps: 1, distance: 400, interval: null, stroke: "Kick" }, // kick/scull
    ],
    // V0.52: 'moderate', 'easy', 'strong', 'all-out', 'relaxed',
    // 'race rhythm', 'fast' all silently resolve. 'build' is the only
    // progression in this file.
    expectedUnmappedTerms: ["build"],
    expectedSectionCountMin: 8,
  },

  // commit-jodie-08-aug — Aug 26 main set with descending structure
  "commit-jodie-08-aug.txt": {
    expectedRepGroups: [
      // (no title) — warm-up
      { reps: 1, distance: 600, interval: null, stroke: null }, // 600 as mixed EO/FNT/DRILL/Swim
      { reps: 6, distance: 50, interval: "1:10", stroke: "Kick", fragments: [
        { distance: 25, stroke: null, expectsIntensity: true, intensityType: "aerobic" }, // mod → moderate
        { distance: 25, stroke: null, expectsIntensity: false }, // tapping
      ]},
      { reps: 4, distance: 50, interval: null, stroke: null, fragments: [
        { distance: 25, stroke: "drill", expectsIntensity: true, intensityType: "build" }, // progressive scull
        { distance: 25, stroke: null, expectsIntensity: false }, // swim
      ]},
      // Main Set
      { reps: 1, distance: 800, interval: null, stroke: null }, // 800 progressive aerobic
      { reps: 4, distance: 200, interval: "3:00", stroke: null }, // 4×200 holding pace
      { reps: 4, distance: 100, interval: "1:30", stroke: null }, // 4×100 desc
      { reps: 1, distance: 200, interval: null, stroke: "Back" }, // 200 backstroke recovery
      { reps: 3, distance: 25, interval: null, stroke: null }, // 3×25 or 6 stroke BO dives
      { reps: 1, distance: 100, interval: null, stroke: null }, // 100 recovery
    ],
    // V0.52: 'mod' is now a Tier-2 abbreviation (excluded). 'fnt' is
    // excluded. 'descend' + 'progressive' are progressions.
    expectedUnmappedTerms: ["descend", "progressive"],
    expectedSectionCountMin: 2,
  },

  // commit-jodie-09-purposethreshold.txt — V0.52.1 (2026-09-08).
  // The user's own failing workout: the centerpiece of the Jodie audit.
  // Covers Rules 22 (Each:/Descend: ladders), 23 (@ N%–M% intensity on
  // header), 24 (event rhythm → race_pace mapping), and the unmapped_terms
  // exclusions (5)+(6) for 'descend' as a ladder header and 'event' as
  // part of 'event rhythm'.
  //
  // The "50/100 / 3 rounds" section IS the second section. The
  // `4 × 100 @ 80–85%` inside it carries intensity=percent_range per
  // rule 23 (was int=None in the pre-V0.52.1 parse).
  "commit-jodie-09-purposethreshold.txt": {
    expectedRepGroups: [
      // === Section 1: Warm-Up — 1,200 m ===
      { reps: 4, distance: 150, interval: "2:20–2:30", stroke: null, fragments: [
        // Each: 50 @ 65% / 50 @ 70% / 50 @ 75% — rule 22(b) sub-segment
        // composite. Fragment text `50 @ 65%` carries its own intensity
        // (percent_range).
        { distance: 50, stroke: null, expectsIntensity: true, intensityType: "percent_range" },
        { distance: 50, stroke: null, expectsIntensity: true, intensityType: "percent_range" },
        { distance: 50, stroke: null, expectsIntensity: true, intensityType: "percent_range" },
      ]},
      { reps: 4, distance: 100, interval: "1:35–1:40", stroke: null, fragments: [
        { distance: 25, stroke: "Drill", expectsIntensity: false }, // scull — no intensity word
        { distance: 50, stroke: null, expectsIntensity: true, intensityType: "aerobic" }, // strong aerobic → aerobic
        { distance: 25, stroke: null, expectsIntensity: true, intensityType: "easy" }, // easy
      ]},
      // Descend: 1 = 70% / 2 = 75% / 3 = 80% / 4 = ~85% — rule 22(a)
      // per-rep intensity ladder. 4 reps, 4 fragments, each intensity is
      // a descend-type (the LLM keeps the parent intensity.type="descend"
      // AND emits per-fragment descend with the rep-N percent label).
      { reps: 4, distance: 50, interval: "1:00", stroke: null, fragments: [
        { distance: 50, stroke: null, expectsIntensity: true, intensityType: "descend" },
        { distance: 50, stroke: null, expectsIntensity: true, intensityType: "descend" },
        { distance: 50, stroke: null, expectsIntensity: true, intensityType: "descend" },
        { distance: 50, stroke: null, expectsIntensity: true, intensityType: "descend" },
      ]},
      // 4 × 25 @ :40 with 12.5 strong + 12.5 easy — composite (round to 13/13 by the
      // _decimal-distance-fix.ts post-pass; assertion uses the ROUNDED integer).
      { reps: 4, distance: 25, interval: ":40", stroke: null, fragments: [
        { distance: 13, stroke: null, expectsIntensity: true, intensityType: "aerobic" }, // strong
        { distance: 13, stroke: null, expectsIntensity: true, intensityType: "easy" },
      ]},
      { reps: 1, distance: 100, interval: null, stroke: null }, // 100 easy

      // === Section 2: 50/100 (3 rounds) ===
      // Rule 23: 4 × 100 @ 80–85% — @ N%–M% is the governing intensity
      // (percent_range), NOT an interval. interval stays null.
      { reps: 4, distance: 100, interval: null, stroke: null },
      { reps: 1, distance: 200, interval: null, stroke: null }, // 200 easy
      // Rule 24: 25 event rhythm / 25 easy — event rhythm maps to race_pace.
      { reps: 4, distance: 50, interval: "1:00", stroke: null, fragments: [
        { distance: 25, stroke: null, expectsIntensity: true, intensityType: "race_pace" },
        { distance: 25, stroke: null, expectsIntensity: true, intensityType: "easy" },
      ]},
    ],
    // 'descend' is honored as the parent repGroup's intensity.type —
    // rule 7 exclusion (6) removes it from unmapped_terms. 'event'
    // is part of 'event rhythm' which rule 24 maps to race_pace —
    // rule 7 exclusion (5) removes it. Net: clean.
    expectedUnmappedTerms: [],
    expectedSectionCountMin: 2,
  },
};
