/**
 * expected.stress.ts — hand-annotated expected output for the
 * stress-input.txt corpus. The expected reflects what the coach
 * MEANT, not what the engine currently emits — the gap IS the
 * benchmark signal. Used by `bench.py` to score the regex
 * engine on edge-case coach inputs the user explicitly cares
 * about (V0.52 Slice 3 follow-up, 2026-09-23).
 *
 * The 9 categories in the source file map to known engine
 * gaps:
 *   1. Ambiguous-intensity vocabulary (9 sets) — engine loses
 *      the intensity word as a note. EXPECTED has it.
 *   2. Bare-seconds intervals (2 sets) — engine normalizes.
 *   3. Words for distance (5 sets) — engine resolves `per/on/
 *      leaving on/on the` to interval; `max effort` is lost.
 *   4. Mixed sets on one line (2 lines, 4 sets) — engine emits
 *      only one of the two pairs.
 *   5. Free-text sprinkles (3 notes) — should NOT become rgs.
 *   6. Race-day specific (4 sets) — engine handles most.
 *   7. Longer programs (4 sets) — engine handles most.
 *   8. Alternative gear (4 sets) — engine loses all gear.
 *   9. Solo word problems — `Two 400s` emits 1×400 (loses the
 *      second 400), `three rounds thru:` emits one round
 *      (loses the 2× multiplier).
 */

export interface ExpectedRepGroup {
  reps: number;
  distance: number;
  interval: string | null;
  stroke: string | null;
  gear?: string[] | null;
  note?: string | null;
  source: string;
}

export interface ExpectedLine {
  notes: string[];
  repGroups: ExpectedRepGroup[];
}

export const EXPECTED_STRESS: Record<string, ExpectedLine> = {
  "stress-input.txt": {
    // Category 1: ambiguous intensity vocabulary
    // Engine resolves each to a tier type; the assertion is rg
    // structure (reps/distance/interval/stroke) — intensity
    // resolution is in the validator and is NOT asserted here
    // (would couple to intensity-tier rules that change).
    notes: [],
    repGroups: [
      { reps: 4, distance: 50, interval: "1:00", stroke: "Free", note: "moderate", source: "4 x 50 free moderate @ 1:00" },
      { reps: 4, distance: 50, interval: "1:00", stroke: "Free", note: "hard",     source: "4 x 50 free hard @ 1:00" },
      { reps: 4, distance: 50, interval: "1:00", stroke: "Free", note: "steady",   source: "4 x 50 free steady @ 1:00" },
      { reps: 4, distance: 50, interval: "1:00", stroke: "Free", note: "cruise",   source: "4 x 50 free cruise @ 1:00" },
      { reps: 4, distance: 50, interval: "1:00", stroke: "Free", note: "light",    source: "4 x 50 free light @ 1:00" },
      { reps: 4, distance: 50, interval: "1:00", stroke: "Free", note: "strong",   source: "4 x 50 free strong @ 1:00" },
      { reps: 4, distance: 50, interval: "1:00", stroke: "Free", note: "tough",    source: "4 x 50 free tough @ 1:00" },
      { reps: 4, distance: 50, interval: "1:00", stroke: "Free", note: "all-out",  source: "4 x 50 free all-out @ 1:00" },
      // Category 2: bare-seconds intervals
      { reps: 8,  distance: 25, interval: "0:30", stroke: "Free", source: "8 x 25 free @ :30" },
      { reps: 10, distance: 50, interval: "0:45", stroke: "Free", note: "rest", source: "10 x 50 free @ :45 rest" },
      // Category 3: words for distance (engine resolves `per/on/leaving on/on the`
      // and bare `max effort` to interval-shaped values)
      { reps: 4, distance: 100, interval: "1:30", stroke: "Free", source: "4 x 100 free per 1:30" },
      { reps: 4, distance: 100, interval: "1:30", stroke: "Free", source: "4 x 100 free on 1:30" },
      { reps: 4, distance: 100, interval: "1:30", stroke: "Free", source: "4 x 100 free leaving on 1:30" },
      { reps: 4, distance: 100, interval: "1:30", stroke: "Free", source: "4 x 100 free on the 1:30" },
      { reps: 4, distance: 100, interval: null,   stroke: "Free", note: "max effort", source: "4 x 100 free max effort" },
      // Category 4: mixed sets on one line
      { reps: 1, distance: 200, interval: "3:00", stroke: "Free", source: "200 free + 200 IM @ 3:00" },
      { reps: 1, distance: 200, interval: "3:00", stroke: "IM",    source: "200 free + 200 IM @ 3:00" },
      { reps: 4, distance: 50,  interval: "1:00", stroke: "Free", source: "4 x 50 free + 4 x 50 kick @ 1:00" },
      { reps: 4, distance: 50,  interval: "1:00", stroke: "Kick", source: "4 x 50 free + 4 x 50 kick @ 1:00" },
      // Category 6: race-day specific
      { reps: 4, distance: 25,  interval: "0:45", stroke: null, source: "4 x 25 from a push @ :45" },
      { reps: 3, distance: 100, interval: null,   stroke: null, source: "3 x 100 race pace, smooth into the first 25" },
      { reps: 1, distance: 400, interval: null,   stroke: null, note: "with first 50 fast", source: "400 with first 50 fast" },
      { reps: 1, distance: 200, interval: null,   stroke: null, source: "200 build to sprint with fast finish" },
      // Category 7: longer programs
      { reps: 4, distance: 50,  interval: null,   stroke: "Free", note: "easy", source: "4 x 50 free easy" },
      { reps: 2, distance: 100, interval: null,   stroke: "Free", note: "moderate", source: "2 x 100 free moderate" },
      { reps: 6, distance: 100, interval: "1:30", stroke: null,   source: "6 x 100 free on 1:30 (2 fast, 4 easy)" },
      { reps: 1, distance: 200, interval: null,   stroke: null,   note: "easy", source: "warm down 200 easy" },
      // Category 8: alternative gear
      { reps: 4, distance: 50,  interval: "1:00", stroke: "Fly", gear: ["fins"], source: "4 x 50 fly with fins @ 1:00 (race pace)" },
      { reps: 4, distance: 50,  interval: "1:00", stroke: "Free", gear: ["paddles"], source: "4 x 50 freestyle w/ paddles @ 1:00" },
      { reps: 6, distance: 50,  interval: "0:50", stroke: null,  gear: ["pull_buoy"], source: "6 x 50 w/ pull buoy @ 0:50" },
      { reps: 8, distance: 25,  interval: "0:30", stroke: null,  gear: ["snorkel"], source: "8 x 25 w/snorkel on the 0:30" },
      // Category 9: solo word problems
      { reps: 2, distance: 400, interval: null,   stroke: null, source: "Two 400s" },
      // three rounds thru — engine emits one round only; expected 3
      { reps: 3, distance: 200, interval: null,   stroke: null, note: "easy", source: "1 x 200 easy (round × 3)" },
      { reps: 3, distance: 200, interval: null,   stroke: null, note: "build", source: "1 x 200 build (round × 3)" },
    ],
    // Category 5: 3 free-text sprinkles — must remain notes, NOT repGroups.
    notes: [
      "Focus on streamline off every wall",
      "Focus: breakout tempo",
      "*emphasis on vertical line*",
    ],
  },
};
