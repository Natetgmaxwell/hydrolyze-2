// expected.ts — hand-annotated expected output for the bench corpus.
// Each repGroup is a flat record the parser should produce. The schema
// captures what the user actually sees in the parse preview, not just
// the metric the user has to score on (reps, distance, interval).
//
// v2 schema adds stroke, pattern, note, subReps fields. The bench now
// measures the gaps the user has flagged in screenshots: kick stroke
// detection, fast-for-time note attachment, FBFB@ pattern handling,
// and as-pattern sub-rep count.

export interface ExpectedRepGroup {
  reps: number;
  distance: number;
  interval: string | null;
  // v2 additions:
  stroke: string | null;            // canonical stroke word (Free/Back/Breast/Fly/IM/Kick/Choice/...) or null
  pattern: string | null;           // e.g. 'FBBF', 'FBF', 'FBFB' if the line had a pattern rotation
  note: string | null;              // attached free-text note (e.g. 'fast for time', 'descend 1-4')
  subReps: number;                  // count of sub-reps the line produced (0 unless the line had `as N.X, N+1.Y` notation)
  // v3 additions (metadata phase):
  dive?: boolean;                   // true if the set is dive-started (default false)
  suit?: boolean;                   // true if the set is swum in a suit (default false)
  gear?: string[];                  // extracted gear (e.g. ['fins', 'paddles'])
  fragments?: number;               // count of fragments (composite sets only; 0/null for regular)
  zoneTerm?: string | null;         // standalone zone term, when explicitly asserted
  source: string;                   // the human source line this came from, for diagnostics
}

interface ExpectedLine {
  // Lines that are expected to be free-text notes (no rep groups)
  notes: string[];
  repGroups: ExpectedRepGroup[];
}

export const EXPECTED: Record<string, ExpectedLine> = {
  'real-input-1.txt': {
    notes: [
      "Float high Body position first, feet on lane rope and hands on board or noodle or lane rope- breath control- arms straight",
      "30 sec extra rest",
    ],
    repGroups: [
      // Line 2: "400 kick for body/head position 100 free 100 back - floppy feet"
      // The coach means: 400 kick, then 100 free, then 100 back.
      { reps: 1, distance: 400, interval: null, stroke: "Kick", pattern: null, note: null, subReps: 0, source: "400 kick for body/head position 100 free 100 back - floppy feet (first set)" },
      { reps: 1, distance: 100, interval: null, stroke: "Free", pattern: null, note: null, subReps: 0, source: "100 free (line 2, second set)" },
      { reps: 1, distance: 100, interval: null, stroke: "Back", pattern: null, note: null, subReps: 0, source: "100 back (line 2, third set)" },
      // Line 5: 3 x 300 FBBF (free,back,breast, free) @ 4:30
      { reps: 3, distance: 300, interval: "4:30", stroke: "Free", pattern: "FBBF", note: null, subReps: 0, source: "3 x 300 FBBF (free,back,breast, free) @ 4:30" },
      // Line 6: 3 x 300 free @ 4.30 as 1.fists/swim, 2. catch up/swim 3. swim
      { reps: 3, distance: 300, interval: "4:30", stroke: "Free", pattern: "FFF", note: null, subReps: 3, source: "3 x 300 free @ 4.30 as 1.fists/swim, 2. catch up/swim 3. swim" },
      // Line 9: 3 x 200 FBF @ 2:50 by
      { reps: 3, distance: 200, interval: "2:50", stroke: null, pattern: "FBF", note: null, subReps: 0, source: "3 x 200 FBF @ 2:50 by" },
      // Line 10: 3 x 200 free @ 2:50 same as above
      { reps: 3, distance: 200, interval: "2:50", stroke: "Free", pattern: "FBF", note: null, subReps: 0, source: "3 x 200 free @ 2:50 same as above (should inherit FBF from previous)" },
      // Line 12: 3 x 100 FBFB@ 1.20
      { reps: 3, distance: 100, interval: "1:20", stroke: null, pattern: "FBFB", note: null, subReps: 0, source: "3 x 100 FBFB@ 1.20 (no space before @)" },
      // Line 13: 3 x 100 free @1.20 same as above
      { reps: 3, distance: 100, interval: "1:20", stroke: "Free", pattern: "FBFB", note: null, subReps: 0, source: "3 x 100 free @1.20 same as above (should inherit FBFB from previous)" },
      // Line 17: 1 x 400 FBFB
      { reps: 1, distance: 400, interval: null, stroke: null, pattern: "FBFB", note: "fast for time", subReps: 0, source: "1 x 400 FBFB" },
    ],
  },

  'real-input-2.txt': {
    notes: [],
    repGroups: [
      // Pure kick stroke
      { reps: 4, distance: 50, interval: "1:00", stroke: "Kick", pattern: null, note: null, subReps: 0, source: "4 x 50 kick @ 1:00" },
      // free + 'fast for time' note attached
      { reps: 4, distance: 50, interval: "1:00", stroke: "Free", pattern: null, note: "fast for time", subReps: 0, source: "4 x 50 free @ 1:00 fast for time" },
      // IM with as-pattern, 4 sub-reps
      { reps: 4, distance: 50, interval: "1:00", stroke: "IM", pattern: "KDFK", note: null, subReps: 4, source: "4 x 50 IM @ 1:00 as 1.kick, 2.drill, 3.swim, 4.breast" },
    ],
  },  'real-input-4.txt': {
    notes: [
      "Pool warm-up race-prep clean tests",
    ],
    repGroups: [
      // === Single-rep, no x separator (input line 1) ===
      { reps: 1, distance: 300, interval: null, stroke: "Choice", pattern: null, note: null, subReps: 0, source: "300m choice" },
      // === as Ndm drill + Ndm swim (input line 2) — sub-reps not yet emitted ===
      { reps: 4, distance: 50, interval: "1:00", stroke: null, pattern: null, note: null, subReps: 0, source: "4 × 50m as 25m drill + 25m swim" },
      // === kick + pace split (input line 3) ===
      { reps: 4, distance: 50, interval: "1:00", stroke: "Kick", pattern: null, note: null, subReps: 0, source: "4 × 50m kick as 25m strong + 25m easy" },
      // === as descriptive note (input line 4) ===
      { reps: 4, distance: 50, interval: "1:10", stroke: null, pattern: null, note: null, subReps: 0, source: "4 × 50m as last 15m fast" },
      // === build to race tempo @ :40 (input line 5) ===
      { reps: 4, distance: 25, interval: "0:40", stroke: null, pattern: null, note: null, subReps: 0, source: "4 × 25m build to race tempo" },
      // === Single-rep: 100m easy (input line 6) ===
      { reps: 1, distance: 100, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "100m easy" },
      // === fast breakout to 15m @ :45 (input line 7) ===
      { reps: 1, distance: 25, interval: "0:45", stroke: null, pattern: null, note: null, subReps: 0, source: "1 × 25m fast breakout" },
      // === build into fast finish @ :45 (input line 8) ===
      { reps: 1, distance: 25, interval: "0:45", stroke: null, pattern: null, note: null, subReps: 0, source: "1 × 25m build into a fast finish" },
      // === as 25m smooth + 25m race tempo (input line 9) — no sub-reps yet ===
      { reps: 1, distance: 50, interval: "1:10", stroke: null, pattern: null, note: null, subReps: 0, source: "1 × 50m as 25m smooth + 25m race tempo" },
      // === 100m easy @ 2:00 (input line 10) ===
      { reps: 1, distance: 100, interval: "2:00", stroke: null, pattern: null, note: null, subReps: 0, source: "100m easy @ 2:00" },
      // === from a dive @ 4:00 (input line 11) ===
      { reps: 1, distance: 75, interval: "4:00", stroke: null, pattern: null, note: null, subReps: 0, source: "1 × 75m from a dive" },
      // === 125m very easy (input line 12) ===
      { reps: 1, distance: 125, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "125m very easy" },
      // === 2 × 50m @ 1:20 (input line 13) ===
      { reps: 2, distance: 50, interval: "1:20", stroke: null, pattern: null, note: null, subReps: 0, source: "2 × 50m @ 1:20" },
      // === 100m easy (input line 14) ===
      { reps: 1, distance: 100, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "100m easy" },
      // === 1 × 200m @ 3:30–4:00 (input line 15) ===
      { reps: 1, distance: 200, interval: "3:30", stroke: null, pattern: null, note: null, subReps: 0, source: "1 × 200m @ 3:30–4:00" },
      // === 2 × 100m @ 1:45–2:00 (input line 16) ===
      { reps: 2, distance: 100, interval: "1:45", stroke: null, pattern: null, note: null, subReps: 0, source: "2 × 100m @ 1:45–2:00" },
      // === 75m at 400m pace (input line 17) — single rep w/ pace note ===
      { reps: 1, distance: 75, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "75m at 400m pace" },
      // === 25m faster than 400m pace (input line 18) ===
      { reps: 1, distance: 25, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "25m faster than 400m pace" },
      // === 100m easy @ 2:00 (input line 19) ===
      { reps: 1, distance: 100, interval: "2:00", stroke: null, pattern: null, note: null, subReps: 0, source: "100m easy @ 2:00" },
      // === 1 × 50m smooth into wall @ 1:20 (input line 20) ===
      { reps: 1, distance: 50, interval: "1:20", stroke: null, pattern: null, note: null, subReps: 0, source: "1 × 50m smooth into the wall" },
      // === 1 × 50m easy @ 1:10 (input line 21) ===
      { reps: 1, distance: 50, interval: "1:10", stroke: null, pattern: null, note: null, subReps: 0, source: "1 × 50m easy @ 1:10" },
      // === 1 × 500m @ 7:30–8:30 (input line 22) ===
      { reps: 1, distance: 500, interval: "7:30", stroke: null, pattern: null, note: null, subReps: 0, source: "1 × 500m @ 7:30–8:30" },
      // === 4 × 50m @ :50–1:00 (input line 23) ===
      { reps: 4, distance: 50, interval: "0:50", stroke: null, pattern: null, note: null, subReps: 0, source: "4 × 50m @ :50–1:00" },
      // === 100m easy (input line 24) ===
      { reps: 1, distance: 100, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "100m easy" },
      // === 4 × 50m as 15m fast + settle (input line 25) ===
      { reps: 4, distance: 50, interval: "1:00", stroke: null, pattern: null, note: null, subReps: 0, source: "4 × 50m as 15m fast" },
      // === 100m easy (input line 26) ===
      { reps: 1, distance: 100, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "100m easy" },
      // === 4 × 25m from a dive @ 1:00 (input line 27) ===
      { reps: 4, distance: 25, interval: "1:00", stroke: null, pattern: null, note: null, subReps: 0, source: "4 × 25m from a dive" },
      // === 4 × 25m turn entry and breakout @ :50 (input line 28) ===
      { reps: 4, distance: 25, interval: "0:50", stroke: null, pattern: null, note: null, subReps: 0, source: "4 × 25m turn entry and breakout" },
      // === 2 × 50m relaxed perfect technique @ 1:00 (input line 29) ===
      { reps: 2, distance: 50, interval: "1:00", stroke: null, pattern: null, note: null, subReps: 0, source: "2 × 50m relaxed, perfect technique" },
      // === 200m relaxed choice (input line 30) — parser picks stroke=Choice ===
      { reps: 1, distance: 200, interval: null, stroke: "Choice", pattern: null, note: null, subReps: 0, source: "200m relaxed choice" },
      // === 4 × 50m as 25m backstroke + 25m freestyle @ 1:00 (input line 31) ===
      { reps: 4, distance: 50, interval: "1:00", stroke: "Back", pattern: null, note: null, subReps: 0, source: "4 × 50m as 25m backstroke + 25m freestyle" },
      // === 4 × 25m long smooth controlled @ :40 (input line 32) ===
      { reps: 4, distance: 25, interval: "0:40", stroke: "Free", pattern: null, note: null, subReps: 0, source: "4 × 25m long, smooth and controlled" },
    ],
  },
  'real-input-3.txt': {
    notes: [
      "1500 free",
      "200 easy",
    ],
    repGroups: [
      // === Race-pace + send-offs ===
      { reps: 4, distance: 50, interval: "0:30", stroke: "Free", pattern: null, note: null, subReps: 0, source: "4 x 50 free @ 0:30 race pace" },
      { reps: 1, distance: 200, interval: "1:30", stroke: "Free", pattern: null, note: "race pace", subReps: 0, source: "200 free on 1:30 race pace" },
      { reps: 3, distance: 100, interval: "1:20", stroke: "Free", pattern: null, note: "send-off", subReps: 0, source: "3 x 100 free send-off 1:20" },
      // === Negative split + build ===
      { reps: 1, distance: 400, interval: null, stroke: "Free", pattern: null, note: "negative split, 1st half faster", subReps: 0, source: "400 free negative split, 1st half faster" },
      { reps: 1, distance: 200, interval: null, stroke: "Free", pattern: null, note: "build to fast", subReps: 0, source: "200 free build to fast" },
      // === Descend + as-pattern ===
      { reps: 4, distance: 100, interval: null, stroke: "Free", pattern: null, note: "descend 1-4", subReps: 0, source: "4 x 100 free descend 1-4" },
      { reps: 3, distance: 200, interval: null, stroke: "IM", pattern: null, note: null, subReps: 4, source: "3 x 200 IM as 1.kick, 2.drill, 3.swim, 4.breast" },
      { reps: 8, distance: 50, interval: "0:45", stroke: "Free", pattern: null, note: "hold best average", subReps: 0, source: "8 x 50 free @ 0:45 hold best average" },
      // === Gear sets ===
      { reps: 4, distance: 50, interval: "1:00", stroke: "Free", pattern: null, note: null, subReps: 0, source: "4 x 50 free pull @ 1:00" },
      { reps: 4, distance: 50, interval: "1:00", stroke: "Free", pattern: null, note: null, subReps: 0, source: "4 x 50 free paddles @ 1:00" },
      { reps: 4, distance: 50, interval: "1:00", stroke: "Free", pattern: null, note: null, subReps: 0, source: "4 x 50 free pull buoy @ 1:00" },
      { reps: 4, distance: 50, interval: "1:00", stroke: "Fly", pattern: null, note: null, subReps: 0, source: "4 x 50 fly kickboard @ 1:00" },
      { reps: 4, distance: 50, interval: "1:00", stroke: "Free", pattern: null, note: null, subReps: 0, source: "4 x 50 free snorkel @ 1:00" },
      // === Drills ===
      { reps: 4, distance: 50, interval: "1:00", stroke: "Free", pattern: null, note: null, subReps: 0, source: "4 x 50 catch-up drill @ 1:00" },
      { reps: 4, distance: 50, interval: "1:00", stroke: "Free", pattern: null, note: null, subReps: 0, source: "4 x 50 fist drill @ 1:00" },
      { reps: 4, distance: 50, interval: "1:00", stroke: "Drill", pattern: null, note: null, subReps: 0, source: "4 x 50 single arm drill @ 1:00" },
      { reps: 4, distance: 50, interval: "1:00", stroke: "Kick", pattern: null, note: null, subReps: 0, source: "4 x 50 vertical kick @ 1:00" },
      { reps: 4, distance: 50, interval: "1:00", stroke: "Free", pattern: null, note: null, subReps: 0, source: "4 x 50 free kick drill on board @ 1:00" },
      // === IM + breath ===
      { reps: 4, distance: 100, interval: "1:30", stroke: "IM", pattern: null, note: null, subReps: 0, source: "4 x 100 IM @ 1:30" },
      { reps: 4, distance: 50, interval: null, stroke: "Free", pattern: null, note: "no breath", subReps: 0, source: "4 x 50 free no breath" },
      { reps: 4, distance: 25, interval: null, stroke: "Free", pattern: null, note: "no breathing", subReps: 0, source: "4 x 25 free no breathing" },
      // === Round numbers + large distances ===
      { reps: 1, distance: 400, interval: "5:30", stroke: "Free", pattern: null, note: null, subReps: 0, source: "400 free @ 5:30" },
      { reps: 1, distance: 800, interval: "12:00", stroke: "Free", pattern: null, note: null, subReps: 0, source: "800 free @ 12:00" },
      // === Multi-distance sets ===
      { reps: 4, distance: 200, interval: "0:45", stroke: "Free", pattern: null, note: null, subReps: 0, source: "4 x 200s, 4 x 50s free @ 0:45" },
      // === Section headers ===
      { reps: 4, distance: 50, interval: "1:00", stroke: "Free", pattern: null, note: null, subReps: 0, source: "WARM UP -> 4 x 50 free @ 1:00" },
      { reps: 1, distance: 200, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "WARM UP -> 200 easy" },
      { reps: 4, distance: 100, interval: "1:30", stroke: "Free", pattern: null, note: null, subReps: 0, source: "MAIN SET -> 4 x 100 free @ 1:30" },
      { reps: 1, distance: 200, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "COOL DOWN -> 200 easy" },
    ],
  },

  'real-input-5.txt': {
    notes: [
      "Dive, suit, and equipment extraction tests",
    ],
    repGroups: [
      { reps: 4, distance: 50, interval: "1:00", stroke: "Free", pattern: null, note: null, subReps: 0, dive: true, source: "4 x 50m free from a dive @ 1:00" },
      { reps: 6, distance: 25, interval: "0:40", stroke: "Fly", pattern: null, note: null, subReps: 0, dive: true, source: "6 x 25m fly off the blocks @ 0:40" },
      { reps: 4, distance: 50, interval: "1:00", stroke: "Free", pattern: null, note: null, subReps: 0, dive: true, suit: true, source: "4 x 50m free in a suit from a dive @ 1:00" },
      { reps: 8, distance: 50, interval: "1:10", stroke: "Kick", pattern: null, note: null, subReps: 0, gear: ["fins"], source: "8 x 50m kick with fins @ 1:10" },
      { reps: 4, distance: 100, interval: "1:40", stroke: "IM", pattern: null, note: null, subReps: 0, gear: ["paddles", "pull_buoy"], source: "4 x 100m IM with paddles and pull buoy @ 1:40" },
      { reps: 6, distance: 50, interval: "1:00", stroke: "Free", pattern: null, note: null, subReps: 0, gear: ["snorkel"], source: "6 x 50m free with snorkel @ 1:00" },
      { reps: 4, distance: 25, interval: "1:00", stroke: null, pattern: null, note: null, subReps: 0, dive: true, gear: ["parachute"], source: "4 x 25m sprint with parachute from a dive @ 1:00" },
      { reps: 8, distance: 50, interval: "1:15", stroke: "Back", pattern: null, note: null, subReps: 0, gear: ["resistance_band"], source: "8 x 50m back with resistance band @ 1:15" },
      { reps: 4, distance: 50, interval: "1:20", stroke: "Breast", pattern: null, note: null, subReps: 0, gear: ["tennis_balls"], source: "4 x 50m breast with tennis balls @ 1:20" },
      { reps: 6, distance: 100, interval: "1:30", stroke: "Free", pattern: null, note: null, subReps: 0, suit: true, source: "6 x 100m free raced in suit @ 1:30" },
      { reps: 4, distance: 50, interval: "1:10", stroke: "Kick", pattern: null, note: null, subReps: 0, gear: ["kickboard", "fins"], source: "4 x 50m kick with kickboard and fins @ 1:10" },
      { reps: 8, distance: 25, interval: "0:45", stroke: null, pattern: null, note: null, subReps: 0, dive: true, source: "8 x 25m dive entry fast breakout @ 0:45" },
      { reps: 6, distance: 50, interval: "1:00", stroke: "Free", pattern: null, note: null, subReps: 0, gear: ["finger_paddle"], source: "6 x 50m free with finger paddles @ 1:00" },
      { reps: 4, distance: 100, interval: "1:45", stroke: "IM", pattern: null, note: null, subReps: 0, gear: ["pull_paddle", "ankle_band"], source: "4 x 100m IM with pull paddle and ankle band @ 1:45" },
      { reps: 8, distance: 50, interval: "1:00", stroke: "Choice", pattern: null, note: null, subReps: 0, gear: ["drag_suit"], source: "8 x 50m choice with drag suit @ 1:00" },
      { reps: 4, distance: 50, interval: "1:00", stroke: "Free", pattern: null, note: null, subReps: 0, dive: true, suit: true, source: "4 x 50m free tech suit dive start @ 1:00" },
      { reps: 8, distance: 25, interval: "0:50", stroke: "Fly", pattern: null, note: null, subReps: 0, dive: true, gear: ["fins"], source: "8 x 25m fly from a dive with fins @ 0:50" },
      { reps: 6, distance: 50, interval: "1:20", stroke: "Back", pattern: null, note: null, subReps: 0, gear: ["weight_belt"], source: "6 x 50m back with weight belt @ 1:20" },
      { reps: 4, distance: 100, interval: "2:00", stroke: "Free", pattern: null, note: null, subReps: 0, gear: ["power_tower"], source: "4 x 100m free with power tower @ 2:00" },
      { reps: 8, distance: 50, interval: "1:10", stroke: "IM", pattern: null, note: null, subReps: 0, gear: ["stretchcordz"], source: "8 x 50m IM with stretchcordz @ 1:10" },
    ],
  },

  'real-input-18.txt': {
    notes: [],
    repGroups: [
      // Case 1: multi-line composite (Nathan's original example)
      { reps: 4, distance: 100, interval: null, stroke: null, pattern: null, note: null, subReps: 0, fragments: 2, source: "4 x (75 at race rhythm / :15 Rest / 25 maximal finish)" },
      // Case 2: single-line comma (same structure, different syntax)
      { reps: 4, distance: 100, interval: null, stroke: null, pattern: null, note: null, subReps: 0, fragments: 2, source: "4 x (75 at race rhythm, :15 Rest, 25 maximal finish)" },
      // Case 3: short fragments (25+25)
      { reps: 4, distance: 50, interval: null, stroke: null, pattern: null, note: null, subReps: 0, fragments: 2, source: "4 x (25 dive, 25 max finish)" },
      // Case 4: single-line slash (same as case 1 but slash syntax)
      { reps: 4, distance: 100, interval: null, stroke: null, pattern: null, note: null, subReps: 0, fragments: 2, source: "4 x (75 race rhythm / :15 Rest / 25 maximal finish)" },
    ],
  },

  'real-input-6.txt': {
    notes: [],
    repGroups: [
      { reps: 4, distance: 25, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg1" },
      { reps: 12, distance: 25, interval: "0:35", stroke: null, pattern: null, note: null, subReps: 0, source: "rg2" },
      { reps: 12, distance: 25, interval: "0:45", stroke: null, pattern: null, note: null, subReps: 0, source: "rg3" },
      { reps: 3, distance: 100, interval: "2:00", stroke: "Kick", pattern: null, note: null, subReps: 0, source: "rg4" },
      { reps: 3, distance: 75, interval: "4:00", stroke: null, pattern: null, note: null, subReps: 0, dive: true, source: "rg5" },
      { reps: 3, distance: 100, interval: "2:00", stroke: "Pull", pattern: null, note: null, subReps: 0, source: "rg6" },
      { reps: 18, distance: 25, interval: null, stroke: null, pattern: null, note: "odds: uw fast; evens: easy back", subReps: 0, source: "rg7" },
    ],
  },
  'real-input-7.txt': {
    notes: [],
    repGroups: [
      { reps: 1, distance: 4000, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg1" },
      { reps: 1, distance: 400, interval: null, stroke: "Free", pattern: null, note: null, subReps: 0, source: "rg2" },
      { reps: 1, distance: 100, interval: null, stroke: "Back", pattern: null, note: null, subReps: 0, source: "rg3" },
      { reps: 1, distance: 200, interval: null, stroke: "Pull", pattern: null, note: null, subReps: 0, gear: ["pull_paddle","pull_buoy"], source: "high elbow catch" },
      { reps: 1, distance: 200, interval: null, stroke: "Kick", pattern: null, note: null, subReps: 0, source: "rg5" },
      { reps: 12, distance: 50, interval: "0:10", stroke: "Free", pattern: null, note: null, subReps: 1, source: "catch" },
      { reps: 1, distance: 25, interval: "0:10", stroke: "Free", pattern: null, note: null, subReps: 0, source: "catch" },
      { reps: 1, distance: 25, interval: "0:10", stroke: "Free", pattern: null, note: "5–8: 25 drill + 25 swim-Focus: rotation and bodyline; 9–12: 25 drill + 25 swim Focus: distance per stroke", subReps: 0, source: "catch" },
      { reps: 1, distance: 50, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "Clean" },
      { reps: 3, distance: 200, interval: "2:20", stroke: "Free", pattern: null, note: "Hold a consistent aerobic pace; Descend 1–3 slightly; Focus on: * Stroke count, Even pacing, Fast turns, Strong underwater off every wall", subReps: 0, source: "rg10" },
      { reps: 2, distance: 50, interval: null, stroke: "Kick", pattern: null, note: "#1 moderate; #2 build to strong finish - Streamline every wall", subReps: 0, source: "rg11" },
      { reps: 6, distance: 100, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg12" },
      { reps: 1, distance: 50, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "Flip" },
      { reps: 12, distance: 100, interval: "1:30", stroke: "Pull", pattern: null, note: null, subReps: 0, source: "rg14" },
      { reps: 3, distance: 400, interval: "4:40", stroke: null, pattern: null, note: null, subReps: 0, source: "rg15" },
      { reps: 8, distance: 50, interval: "0:55", stroke: null, pattern: null, note: null, subReps: 0, source: "rg16" },
    ],
  },
  'real-input-8.txt': {
    notes: [],
    repGroups: [
      { reps: 1, distance: 400, interval: null, stroke: "Free", pattern: null, note: null, subReps: 0, source: "rg1" },
      { reps: 1, distance: 100, interval: null, stroke: "Free", pattern: null, note: null, subReps: 0, source: "rg2" },
      { reps: 1, distance: 100, interval: null, stroke: "Back", pattern: null, note: null, subReps: 0, source: "rg3" },
      { reps: 1, distance: 100, interval: null, stroke: "Pull", pattern: null, note: null, subReps: 0, source: "rg4" },
      { reps: 1, distance: 100, interval: null, stroke: "Free", pattern: null, note: null, subReps: 0, source: "rg5" },
      { reps: 4, distance: 50, interval: "1:00", stroke: null, pattern: null, note: "25 Drill / 25 Swim", subReps: 0, source: "rg6" },
      { reps: 4, distance: 50, interval: "1:00", stroke: "Kick", pattern: null, note: "Build each 50; Strong streamline off every wall", subReps: 0, source: "rg7" },
      { reps: 4, distance: 25, interval: "0:40", stroke: null, pattern: null, note: "Underwater dolphin to 10–15m; Easy swim to wall", subReps: 0, source: "rg8" },
      { reps: 8, distance: 50, interval: "0:55", stroke: null, pattern: null, note: "Odd Build 1–3 Easy home", subReps: 0, source: "rg9" },
      { reps: 1, distance: 25, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg10" },
      { reps: 8, distance: 50, interval: "1:30", stroke: null, pattern: null, note: null, subReps: 0, source: "rg11" },
      { reps: 2, distance: 100, interval: null, stroke: "Free", pattern: null, note: "56.0", subReps: 0, source: "rg12" },
      { reps: 2, distance: 200, interval: null, stroke: "Free", pattern: null, note: "2:05", subReps: 0, source: "rg13" },
      { reps: 8, distance: 25, interval: "1:00", stroke: null, pattern: null, note: "Target - Approximately 103–105% race speed", subReps: 0, source: "rg14" },
      { reps: 2, distance: 100, interval: null, stroke: "Free", pattern: null, note: null, subReps: 0, source: "rg15" },
      { reps: 2, distance: 200, interval: null, stroke: "Free", pattern: null, note: null, subReps: 0, source: "rg16" },
      { reps: 2, distance: 100, interval: "5:00", stroke: null, pattern: null, note: null, subReps: 0, source: "rg17" },
      { reps: 2, distance: 50, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg18" },
      { reps: 2, distance: 15, interval: null, stroke: null, pattern: null, note: "25 Fast; :10 Rest; 25 Fast", subReps: 0, source: "rg19" },
      { reps: 2, distance: 75, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg20" },
      { reps: 2, distance: 15, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg21" },
      { reps: 2, distance: 25, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg22" },
      { reps: 1, distance: 100, interval: null, stroke: "Free", pattern: null, note: null, subReps: 0, source: "rg23" },
      { reps: 8, distance: 25, interval: "0:45", stroke: null, pattern: null, note: "15m into wall; Fast turn; Explosive breakout; Easy to finish", subReps: 0, source: "rg24" },
      { reps: 1, distance: 100, interval: null, stroke: "Free", pattern: null, note: null, subReps: 0, source: "rg25" },
      { reps: 1, distance: 100, interval: null, stroke: "Pull", pattern: null, note: null, subReps: 0, source: "rg26" },
      { reps: 1, distance: 100, interval: null, stroke: "Choice", pattern: null, note: "Surf/Tri (Approx. 4,400m)", subReps: 0, source: "rg27" },
      { reps: 1, distance: 400, interval: null, stroke: "Free", pattern: null, note: null, subReps: 0, source: "rg28" },
      { reps: 1, distance: 200, interval: null, stroke: "Pull", pattern: null, note: null, subReps: 0, source: "rg29" },
      { reps: 4, distance: 50, interval: "0:55", stroke: null, pattern: null, note: null, subReps: 0, source: "rg30" },
      { reps: 3, distance: 600, interval: "9:00", stroke: null, pattern: null, note: null, subReps: 0, source: "rg31" },
      { reps: 1, distance: 200, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg32" },
      { reps: 1, distance: 200, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg33" },
      { reps: 1, distance: 200, interval: null, stroke: null, pattern: null, note: "strong finish", subReps: 0, source: "rg34" },
      { reps: 1, distance: 400, interval: "1:10", stroke: null, pattern: null, note: null, subReps: 0, source: "rg35" },
      { reps: 1, distance: 200, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg36" },
      { reps: 1, distance: 200, interval: "2:28", stroke: null, pattern: null, note: null, subReps: 0, source: "rg37" },
      { reps: 1, distance: 200, interval: "2:24", stroke: null, pattern: null, note: null, subReps: 0, source: "rg38" },
      { reps: 1, distance: 200, interval: "2:20", stroke: null, pattern: null, note: "Total target: 7:12–7:20 per 600.", subReps: 0, source: "rg39" },
      { reps: 8, distance: 100, interval: "1:30", stroke: "Pull", pattern: null, note: "Hold 1:11–1:13 using paddles and buoy if appropriate.; Focus on:; High elbow catch; Consistent stroke rate; Strong body position; Controlled breathing", subReps: 0, source: "rg40" },
      { reps: 1, distance: 200, interval: null, stroke: "Free", pattern: null, note: null, subReps: 0, source: "rg41" },
      { reps: 1, distance: 100, interval: null, stroke: "Back", pattern: null, note: null, subReps: 0, source: "rg42" },
      { reps: 1, distance: 100, interval: null, stroke: "Choice", pattern: null, note: null, subReps: 0, source: "rg43" },
      { reps: 1, distance: 50, interval: null, stroke: null, pattern: null, note: "Smooth, sustainable threshold work.; Hold pace consistently rather than descending.; Maintain open-water body position and efficient stroke mechanics under fatigue.", subReps: 0, source: "like" },
    ],
  },
  'real-input-9.txt': {
    notes: [],
    repGroups: [
      { reps: 1, distance: 600, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "FNT" },
      { reps: 2, distance: 50, interval: null, stroke: "Kick", pattern: null, note: null, subReps: 0, source: "rg2" },
      { reps: 4, distance: 100, interval: null, stroke: "IM", pattern: null, note: null, subReps: 0, source: "non" },
      { reps: 4, distance: 100, interval: null, stroke: null, pattern: null, note: "4 x KBO fins except breast; 4 x \"6Stk\" only. PWR Drill Max rate + fins; 6 × turn into 10–15m breakout", subReps: 0, gear: ["fins"], source: "Desc" },
      { reps: 6, distance: 25, interval: null, stroke: null, pattern: null, note: null, subReps: 0, gear: ["fins","paddles"], source: "generous" },
      { reps: 8, distance: 15, interval: null, stroke: null, pattern: null, note: "Easy 100 swimming between efforts", subReps: 0, source: "starts" },
    ],
  },
  'real-input-10.txt': {
    notes: [],
    repGroups: [
      { reps: 1, distance: 300, interval: null, stroke: "Free", pattern: null, note: null, subReps: 0, source: "rg1" },
      { reps: 1, distance: 100, interval: null, stroke: "Back", pattern: null, note: null, subReps: 0, source: "rg2" },
      { reps: 1, distance: 100, interval: null, stroke: "Free", pattern: null, note: null, subReps: 0, source: "rg3" },
      { reps: 4, distance: 50, interval: "1:00", stroke: "Free", pattern: null, note: null, subReps: 1, source: "rg4" },
      { reps: 1, distance: 200, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg5" },
      { reps: 4, distance: 50, interval: "1:05", stroke: "Free", pattern: null, note: null, subReps: 0, source: "rg6" },
      { reps: 1, distance: 200, interval: null, stroke: "Free", pattern: null, note: null, subReps: 0, source: "rg7" },
      { reps: 4, distance: 25, interval: "0:40", stroke: null, pattern: null, note: null, subReps: 0, source: "rg8" },
      { reps: 1, distance: 100, interval: null, stroke: "Free", pattern: null, note: "Rep 2: Aerobic flush", subReps: 0, source: "rg9" },
      { reps: 8, distance: 100, interval: "1:40", stroke: null, pattern: null, note: "15–25 seconds rest.; Rep 1: Freestyle, long and relaxed; Rep 2: Choice stroke, perfect technique; 3. Freestyle as 25m breathe every 3 strokes/25m breathe every 5; Rep 4: 25m backstroke + 75m freestyle; Rep 5: Freestyle, negative split; Rep 6: Choice stroke, relaxed; Rep 7: Freestyle with the final 25m at strong aerobic rhythm; Rep 8: Freestyle, descending stroke count each 25m; Repetitions 1–4: approximately 55–65%; Repetitions 5–7: approximately 65–70%; Repetition 8: relaxed reset; Rep 3: Stroke connection and skills", subReps: 0, source: "rg10" },
      { reps: 4, distance: 50, interval: "1:05", stroke: "Free", pattern: null, note: null, subReps: 0, source: "rg11" },
      { reps: 4, distance: 50, interval: "1:00", stroke: "Free", pattern: null, note: null, subReps: 1, source: "rg12" },
      { reps: 4, distance: 25, interval: "0:40", stroke: null, pattern: null, note: null, subReps: 0, source: "rg13" },
      { reps: 2, distance: 50, interval: "1:10", stroke: null, pattern: null, note: "25m scull; 25m relaxed swimming; Drill choices; 3-3-3 drill; Underwater 25s; Push in a tight streamline; Controlled underwater distance to 8–12.5m; Smooth breakout; Easy swimming to the wall; Rep 4: Competition-skills block", subReps: 0, source: "rg14" },
      { reps: 8, distance: 50, interval: "1:10", stroke: null, pattern: null, note: "15m smooth swimming into the wall; Race-quality turn; Underwater and breakout to 10–12.5m; Easy to the opposite wall; Focus on:; Fast foot placement; Tight streamline; Breakout timed into the first stroke", subReps: 0, source: "rg15" },
      { reps: 8, distance: 25, interval: "1:00", stroke: null, pattern: "BBB", note: "Dive or race-specific start; Fast to 12.5–15m; Easy to the wall; Rep 1: Approximately 70%; Rep 2: Approximately 80%; Rep 3: Approximately 85%; Rep 4: Approximately 90%", subReps: 3, source: "rg16" },
      { reps: 8, distance: 50, interval: "1:15", stroke: null, pattern: null, note: "Rep 1: 25m at 200m race rhythm + 25m easy; Rep 2: 25m easy + 25m at 200m race rhythm; Rep 3: 15m at 100m tempo + easy to the wall; Rep 4: 50m smooth, perfect competition stroke; Rep 5: Recovery pull and reset — 400m", subReps: 0, source: "rg17" },
      { reps: 8, distance: 100, interval: "1:45", stroke: "Pull", pattern: null, note: "No. 1: Long and relaxed; No. 2: Negative split; No. 3: Choice of breathing pattern; No. 4: Descend the stroke count across each 25m; Intensity should remain around 60–65%.; Rep 6: Warm-down — 400m", subReps: 0, source: "rg18" },
      { reps: 2, distance: 200, interval: null, stroke: "Back", pattern: null, note: null, subReps: 0, source: "rg19" },
      { reps: 2, distance: 200, interval: null, stroke: "Free", pattern: null, note: null, subReps: 0, source: "rg20" },
      { reps: 8, distance: 25, interval: "0:40", stroke: "Drill", pattern: null, note: null, subReps: 0, source: "rg21" },
      { reps: 2, distance: 200, interval: null, stroke: "Choice", pattern: null, note: null, subReps: 0, source: "rg22" },
      { reps: 2, distance: 100, interval: null, stroke: null, pattern: null, note: "Short race-tempo exposures should look sharp and relaxed.", subReps: 0, source: "rg23" },
      { reps: 8, distance: 100, interval: null, stroke: "Pull", pattern: null, note: null, subReps: 0, source: "removing adding warm" },
    ],
  },
  'real-input-11.txt': {
    notes: [],
    repGroups: [
      { reps: 1, distance: 400, interval: null, stroke: "Free", pattern: null, note: null, subReps: 0, source: "rg1" },
      { reps: 1, distance: 200, interval: null, stroke: "Choice", pattern: null, note: "easy", subReps: 0, source: "rg2" },
      { reps: 4, distance: 50, interval: null, stroke: "Free", pattern: null, note: null, subReps: 1, fragments: 2, source: "rg3" },
      { reps: 4, distance: 25, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg4" },
      { reps: 3, distance: 600, interval: null, stroke: "Free", pattern: null, note: "Zone 1–low Zone 2; 45–60 s rest between repetitions; Focus on:; Long, relaxed stroke; Low stroke rate; Consistent pace", subReps: 0, source: "rg5" },
      { reps: 12, distance: 200, interval: null, stroke: "Free", pattern: null, note: null, subReps: 0, source: "rg6" },
      { reps: 1, distance: 15, interval: "0:15", stroke: null, pattern: null, note: "Hold a comfortable, even pace throughout; Heart rate: ~60–70% HRmax", subReps: 0, source: "rg7" },
      { reps: 8, distance: 50, interval: null, stroke: null, pattern: "DF", note: null, subReps: 2, source: "rg8" },
      { reps: 8, distance: 25, interval: null, stroke: null, pattern: null, note: "Smooth build to 75–80% effort; Full recovery (30–45 s)", subReps: 0, source: "rg9" },
    ],
  },
  'real-input-12.txt': {
    notes: [],
    repGroups: [
      { reps: 1, distance: 400, interval: null, stroke: "Pull", pattern: null, note: null, subReps: 0, source: "rg1" },
      { reps: 1, distance: 225, interval: null, stroke: "Free", pattern: null, note: null, subReps: 0, fragments: 3, source: "rg2" },
      { reps: 1, distance: 200, interval: null, stroke: "Back", pattern: null, note: null, subReps: 0, source: "rg3" },
      { reps: 1, distance: 100, interval: null, stroke: "Free", pattern: null, note: null, subReps: 0, source: "rg4" },
      { reps: 6, distance: 100, interval: "1:30", stroke: "IM", pattern: "FR", note: null, subReps: 2, source: "rg5" },
      { reps: 6, distance: 100, interval: "1:30", stroke: "Free", pattern: null, note: null, subReps: 0, gear: ["paddles"], source: "rg6" },
      { reps: 4, distance: 200, interval: "3:00", stroke: "IM", pattern: "FR", note: null, subReps: 2, source: "rg7" },
      { reps: 4, distance: 100, interval: "1:30", stroke: null, pattern: null, note: null, subReps: 0, source: "rg8" },
      { reps: 2, distance: 300, interval: "4:30", stroke: null, pattern: null, note: null, subReps: 0, source: "rg9" },
      { reps: 2, distance: 100, interval: "1:30", stroke: null, pattern: null, note: null, subReps: 0, source: "rg10" },
      { reps: 10, distance: 200, interval: "0:30", stroke: null, pattern: null, note: null, subReps: 0, source: "rg11" },
      { reps: 4, distance: 100, interval: "2:00", stroke: "Kick", pattern: null, note: null, subReps: 1, source: "rg12" },
      { reps: 1, distance: 400, interval: null, stroke: "Pull", pattern: null, note: null, subReps: 1, gear: ["snorkel"], source: "rg13" },
    ],
  },
  'real-input-13.txt': {
    notes: [],
    repGroups: [
      { reps: 1, distance: 400, interval: null, stroke: "Free", pattern: null, note: null, subReps: 0, source: "rg1" },
      { reps: 4, distance: 50, interval: "1:00", stroke: "Kick", pattern: null, note: null, subReps: 0, source: "rg2" },
      { reps: 4, distance: 50, interval: null, stroke: "Free", pattern: null, note: null, subReps: 1, fragments: 2, source: "rg3" },
      { reps: 4, distance: 50, interval: "1:00", stroke: null, pattern: null, note: null, subReps: 0, source: "rg4" },
      { reps: 4, distance: 25, interval: "0:40", stroke: null, pattern: null, note: null, subReps: 0, source: "rg5" },
      { reps: 4, distance: 25, interval: "0:40", stroke: null, pattern: null, note: null, subReps: 0, source: "rg6" },
      { reps: 1, distance: 100, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg7" },
      { reps: 4, distance: 50, interval: "1:10", stroke: null, pattern: null, note: null, subReps: 0, source: "rg8" },
      { reps: 4, distance: 25, interval: "0:45", stroke: null, pattern: null, note: null, subReps: 0, source: "rg9" },
      { reps: 2, distance: 50, interval: "1:15", stroke: null, pattern: null, note: null, subReps: 0, source: "rg10" },
      { reps: 12, distance: 50, interval: "1:10", stroke: null, pattern: null, note: null, subReps: 0, source: "rg11" },
      { reps: 3, distance: 100, interval: "2:00", stroke: null, pattern: null, note: "#Take an additional 1 minute between rounds if necessary.", subReps: 0, source: "rg12" },
      { reps: 3, distance: 50, interval: null, stroke: null, pattern: null, note: "Example for a goal time of 2:08:; Goal average = 32.0 seconds per 50m; Push target could be approximately 32.0–32.5", subReps: 0, dive: true, source: "rg13" },
      { reps: 3, distance: 50, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg14" },
      { reps: 12, distance: 25, interval: "0:45", stroke: null, pattern: null, note: null, subReps: 0, dive: true, source: "rg15" },
      { reps: 3, distance: 100, interval: "2:00", stroke: null, pattern: null, note: null, subReps: 0, source: "rg16" },
      { reps: 3, distance: 100, interval: null, stroke: null, pattern: null, note: "Target average = approximately 14.5 seconds per 25m; Push repetitions may need to be adjusted slightly for the missing dive advantage", subReps: 0, source: "rg17" },
      { reps: 2, distance: 50, interval: "1:30", stroke: null, pattern: null, note: null, subReps: 0, source: "rg18" },
      { reps: 4, distance: 25, interval: "0:50", stroke: null, pattern: null, note: null, subReps: 0, source: "rg19" },
      { reps: 2, distance: 50, interval: "1:30", stroke: null, pattern: null, note: null, subReps: 0, source: "rg20" },
      { reps: 4, distance: 50, interval: "1:10", stroke: null, pattern: null, note: null, subReps: 0, source: "rg21" },
      { reps: 4, distance: 25, interval: "0:45", stroke: null, pattern: null, note: null, subReps: 0, source: "rg22" },
      { reps: 1, distance: 100, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg23" },
      { reps: 1, distance: 200, interval: null, stroke: "Choice", pattern: null, note: null, subReps: 0, source: "rg24" },
      { reps: 4, distance: 50, interval: null, stroke: "Free", pattern: null, note: null, subReps: 0, fragments: 2, source: "rg25" },
      { reps: 4, distance: 25, interval: "0:35", stroke: null, pattern: null, note: null, subReps: 0, source: "rg26" },
      { reps: 1, distance: 100, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg27" },
      { reps: 1, distance: 200, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg28" },
      { reps: 1, distance: 400, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg29" },
      { reps: 4, distance: 50, interval: "1:00", stroke: null, pattern: null, note: null, subReps: 0, source: "rg30" },
      { reps: 4, distance: 25, interval: "0:40", stroke: null, pattern: null, note: null, subReps: 0, source: "rg31" },
      { reps: 2, distance: 50, interval: "1:10", stroke: null, pattern: null, note: null, subReps: 0, source: "rg32" },
      { reps: 12, distance: 100, interval: "1:40", stroke: null, pattern: null, note: null, subReps: 0, source: "rg33" },
      { reps: 3, distance: 100, interval: "2:00", stroke: null, pattern: null, note: "Allow an additional 1 minute between rounds if needed to preserve exact pace.", subReps: 0, source: "rg34" },
      { reps: 3, distance: 400, interval: "4:32", stroke: null, pattern: null, note: "Goal average = 1:08 per 100m; Target range = approximately 1:07.5–1:08.5; Controlled pace and stroke count; Hold pace while lifting the final 25m of each 100", subReps: 0, source: "rg35" },
      { reps: 8, distance: 50, interval: "1:10", stroke: null, pattern: null, note: null, subReps: 0, source: "rg36" },
      { reps: 2, distance: 100, interval: "2:00", stroke: null, pattern: null, note: null, subReps: 0, source: "rg37" },
      { reps: 2, distance: 400, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg38" },
      { reps: 2, distance: 100, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg39" },
      { reps: 4, distance: 50, interval: "1:00", stroke: null, pattern: null, note: null, subReps: 0, source: "rg40" },
      { reps: 2, distance: 100, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg41" },
      { reps: 4, distance: 50, interval: "1:10", stroke: null, pattern: null, note: null, subReps: 0, source: "rg42" },
      { reps: 4, distance: 25, interval: "0:45", stroke: null, pattern: null, note: null, subReps: 0, source: "rg43" },
      { reps: 1, distance: 100, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg44" },
      { reps: 1, distance: 300, interval: null, stroke: "Choice", pattern: null, note: null, subReps: 0, source: "rg45" },
      { reps: 8, distance: 50, interval: null, stroke: "Free", pattern: null, note: null, subReps: 1, fragments: 2, source: "rg46" },
      { reps: 1, distance: 100, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg47" },
    ],
  },
  'real-input-14.txt': {
    notes: [],
    repGroups: [
      { reps: 1, distance: 600, interval: null, stroke: "Kick", pattern: null, note: null, subReps: 0, source: "rg1" },
      { reps: 8, distance: 50, interval: "1:10", stroke: "Free", pattern: null, note: null, subReps: 0, source: "rg2" },
      { reps: 1, distance: 200, interval: null, stroke: null, pattern: null, note: null, subReps: 0, dive: true, source: "rg3" },
      { reps: 8, distance: 25, interval: "0:30", stroke: null, pattern: null, note: null, subReps: 0, source: "rg4" },
      { reps: 1, distance: 300, interval: null, stroke: null, pattern: null, note: "4 x bungees and drag", subReps: 0, source: "rg5" },
      { reps: 6, distance: 25, interval: null, stroke: null, pattern: null, note: null, subReps: 0, gear: ["fins","paddles"], source: "rg6" },
      { reps: 1, distance: 400, interval: null, stroke: null, pattern: null, note: "Easy aerobic swimming between quality repetitions", subReps: 0, source: "rg7" },
      { reps: 1, distance: 400, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg8" },
    ],
  },
  'real-input-15.txt': {
    notes: [],
    repGroups: [
      { reps: 1, distance: 300, interval: null, stroke: "Free", pattern: null, note: null, subReps: 0, source: "rg1" },
      { reps: 1, distance: 100, interval: null, stroke: "Back", pattern: null, note: null, subReps: 0, source: "rg2" },
      { reps: 1, distance: 100, interval: null, stroke: "Free", pattern: null, note: null, subReps: 0, source: "rg3" },
      { reps: 4, distance: 50, interval: "1:00", stroke: "Free", pattern: null, note: null, subReps: 1, source: "rg4" },
      { reps: 1, distance: 200, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg5" },
      { reps: 4, distance: 50, interval: "1:05", stroke: "Free", pattern: null, note: null, subReps: 0, source: "rg6" },
      { reps: 1, distance: 200, interval: null, stroke: "Free", pattern: null, note: null, subReps: 0, source: "rg7" },
      { reps: 4, distance: 25, interval: "0:40", stroke: null, pattern: null, note: null, subReps: 0, source: "rg8" },
      { reps: 1, distance: 100, interval: null, stroke: "Free", pattern: null, note: "Rep 2: Aerobic flush", subReps: 0, source: "rg9" },
      { reps: 8, distance: 100, interval: "1:40", stroke: null, pattern: null, note: "15–25 seconds rest.; Rep 1: Freestyle, long and relaxed; Rep 2: Choice stroke, perfect technique; 3. Freestyle as 25m breathe every 3 strokes/25m breathe every 5; Rep 4: 25m backstroke + 75m freestyle; Rep 5: Freestyle, negative split; Rep 6: Choice stroke, relaxed; Rep 7: Freestyle with the final 25m at strong aerobic rhythm; Rep 8: Freestyle, descending stroke count each 25m; Repetitions 1–4: approximately 55–65%; Repetitions 5–7: approximately 65–70%; Repetition 8: relaxed reset; Rep 3: Stroke connection and skills", subReps: 0, source: "rg10" },
      { reps: 4, distance: 50, interval: "1:05", stroke: "Free", pattern: null, note: null, subReps: 0, source: "rg11" },
      { reps: 4, distance: 50, interval: "1:00", stroke: "Free", pattern: null, note: null, subReps: 1, source: "rg12" },
      { reps: 4, distance: 25, interval: "0:40", stroke: null, pattern: null, note: null, subReps: 0, source: "rg13" },
      { reps: 2, distance: 50, interval: "1:10", stroke: null, pattern: null, note: "25m scull; 25m relaxed swimming; Drill choices; 3-3-3 drill; Underwater 25s; Push in a tight streamline; Controlled underwater distance to 8–12.5m; Smooth breakout; Easy swimming to the wall; Rep 4: Competition-skills block", subReps: 0, source: "rg14" },
      { reps: 8, distance: 50, interval: "1:10", stroke: null, pattern: null, note: "15m smooth swimming into the wall; Race-quality turn; Underwater and breakout to 10–12.5m; Easy to the opposite wall; Focus on:; Fast foot placement; Tight streamline; Breakout timed into the first stroke", subReps: 0, source: "rg15" },
      { reps: 8, distance: 25, interval: "1:00", stroke: null, pattern: "BBB", note: "Dive or race-specific start; Fast to 12.5–15m; Easy to the wall; Rep 1: Approximately 70%; Rep 2: Approximately 80%; Rep 3: Approximately 85%; Rep 4: Approximately 90%", subReps: 3, source: "rg16" },
      { reps: 8, distance: 50, interval: "1:15", stroke: null, pattern: null, note: "Rep 1: 25m at 200m race rhythm + 25m easy; Rep 2: 25m easy + 25m at 200m race rhythm; Rep 3: 15m at 100m tempo + easy to the wall; Rep 4: 50m smooth, perfect competition stroke; Rep 5: Recovery pull and reset — 400m", subReps: 0, source: "rg17" },
      { reps: 8, distance: 100, interval: "1:45", stroke: "Pull", pattern: null, note: "No. 1: Long and relaxed; No. 2: Negative split; No. 3: Choice of breathing pattern; No. 4: Descend the stroke count across each 25m; Intensity should remain around 60–65%.; Rep 6: Warm-down — 400m", subReps: 0, source: "rg18" },
      { reps: 2, distance: 200, interval: null, stroke: "Back", pattern: null, note: null, subReps: 0, source: "rg19" },
      { reps: 2, distance: 200, interval: null, stroke: "Free", pattern: null, note: null, subReps: 0, source: "rg20" },
      { reps: 8, distance: 25, interval: "0:40", stroke: "Drill", pattern: null, note: null, subReps: 0, source: "rg21" },
      { reps: 2, distance: 200, interval: null, stroke: "Choice", pattern: null, note: null, subReps: 0, source: "rg22" },
      { reps: 2, distance: 100, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg23" },
    ],
  },
  'real-input-16.txt': {
    notes: [],
    repGroups: [
      { reps: 1, distance: 200, interval: null, stroke: "Choice", pattern: null, note: null, subReps: 0, source: "rg1" },
      { reps: 4, distance: 50, interval: "1:00", stroke: null, pattern: null, note: null, subReps: 0, source: "rg2" },
      { reps: 4, distance: 50, interval: "1:00", stroke: null, pattern: null, note: "Build the kick and swimming gradually from approximately 55–70%.; Rep 2: Stroke connection", subReps: 0, source: "rg3" },
      { reps: 6, distance: 50, interval: "1:00", stroke: null, pattern: null, note: "Rep 1: 25m front scull + 25m swim; Rep 2: 25m mid scull + 25m swim; Rep 3: 25m drill + 25m swim; Rep 4: 25m drill + 25m build; Rep 5: 15m strong connection + easy to wall; Rep 6: Full-stroke swimming at approximately 75%; Rep 3: Turn and breakout preparation", subReps: 0, source: "rg4" },
      { reps: 4, distance: 50, interval: "1:10", stroke: null, pattern: null, note: "15m controlled into the wall; Race-quality turn; Fast underwater and breakout to 10–12.5m; Easy to the next wall", subReps: 0, source: "rg5" },
      { reps: 4, distance: 25, interval: "0:45", stroke: null, pattern: null, note: "Fast underwater and breakout; Build to race tempo; Easy into the wall; Rep 4: Race priming", subReps: 0, source: "rg6" },
      { reps: 1, distance: 25, interval: "0:40", stroke: null, pattern: null, note: null, subReps: 0, source: "rg7" },
      { reps: 1, distance: 25, interval: "0:45", stroke: null, pattern: null, note: null, subReps: 0, dive: true, source: "rg8" },
      { reps: 1, distance: 50, interval: "1:10", stroke: null, pattern: null, note: null, subReps: 0, source: "rg9" },
      { reps: 1, distance: 100, interval: "2:00", stroke: null, pattern: null, note: null, subReps: 0, source: "rg10" },
      { reps: 2, distance: 25, interval: "1:00", stroke: null, pattern: null, note: null, subReps: 0, dive: true, source: "rg11" },
      { reps: 2, distance: 25, interval: null, stroke: null, pattern: null, note: "race pace @ :50", subReps: 0, dive: true, source: "rg12" },
      { reps: 2, distance: 25, interval: "0:50", stroke: null, pattern: null, note: "Rep 1: 5m easy +; Rep 2: 5m maximum finish @ :50", subReps: 0, source: "rg13" },
      { reps: 2, distance: 25, interval: "0:50", stroke: null, pattern: null, note: null, subReps: 0, dive: true, source: "rg14" },
      { reps: 2, distance: 100, interval: "2:00", stroke: null, pattern: null, note: "Take an additional 60 seconds between rounds.", subReps: 0, source: "rg15" },
      { reps: 1, distance: 25, interval: null, stroke: "Back", pattern: null, note: "Turn approach: hold speed into the wall without gliding", subReps: 0, source: "rg16" },
      { reps: 1, distance: 50, interval: null, stroke: null, pattern: null, note: "1 × broken 50m:", subReps: 0, source: "rg17" },
      { reps: 1, distance: 25, interval: null, stroke: null, pattern: null, note: null, subReps: 0, dive: true, source: "rg18" },
      { reps: 1, distance: 25, interval: null, stroke: null, pattern: null, note: null, subReps: 0, dive: true, source: "rg19" },
      { reps: 1, distance: 150, interval: null, stroke: null, pattern: null, note: "Additional 3–4 minutes before the next broken 50m", subReps: 0, source: "rg20" },
      { reps: 1, distance: 100, interval: null, stroke: null, pattern: null, note: "1 × broken 100m:", subReps: 0, source: "rg21" },
      { reps: 1, distance: 50, interval: null, stroke: null, pattern: null, note: null, subReps: 0, dive: true, source: "rg22" },
      { reps: 1, distance: 25, interval: null, stroke: null, pattern: null, note: null, subReps: 0, dive: true, source: "rg23" },
      { reps: 1, distance: 25, interval: null, stroke: null, pattern: null, note: null, subReps: 0, dive: true, source: "rg24" },
      { reps: 1, distance: 200, interval: null, stroke: null, pattern: null, note: "Additional 4 minutes before round two", subReps: 0, source: "rg25" },
      { reps: 2, distance: 50, interval: "1:30", stroke: null, pattern: null, note: null, subReps: 0, source: "rg26" },
      { reps: 4, distance: 25, interval: "0:50", stroke: null, pattern: null, note: null, subReps: 0, source: "rg27" },
      { reps: 2, distance: 100, interval: "2:00", stroke: null, pattern: null, note: null, subReps: 0, source: "rg28" },
      { reps: 1, distance: 200, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg29" },
      { reps: 1, distance: 75, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg30" },
      { reps: 1, distance: 50, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg31" },
      { reps: 1, distance: 50, interval: null, stroke: null, pattern: null, note: "25m at back-end race effort", subReps: 0, source: "rg32" },
      { reps: 1, distance: 200, interval: null, stroke: null, pattern: null, note: "Additional 4–5 minutes before round two; Rep 1: Exact target pace and controlled opening speed; Rep 2: Maintain pace, then attack the final 50m", subReps: 0, source: "rg33" },
      { reps: 1, distance: 75, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg34" },
      { reps: 1, distance: 50, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg35" },
      { reps: 1, distance: 25, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg36" },
      { reps: 8, distance: 50, interval: "1:15", stroke: null, pattern: null, note: null, subReps: 0, source: "rg37" },
      { reps: 2, distance: 100, interval: "2:00", stroke: null, pattern: null, note: "Hold the same target split across all four 50s.; No. 1: First-50 race rhythm; No. 2: Middle-50 rhythm; No. 3: Third-50 discipline; No. 4: Final-50 speed", subReps: 0, source: "rg38" },
      { reps: 4, distance: 25, interval: "0:50", stroke: null, pattern: null, note: null, subReps: 0, source: "rg39" },
      { reps: 1, distance: 100, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg40" },
      { reps: 8, distance: 50, interval: "1:00", stroke: null, pattern: null, note: null, subReps: 0, source: "rg41" },
      { reps: 2, distance: 200, interval: "3:30", stroke: null, pattern: null, note: "Additional 60 seconds between rounds", subReps: 0, source: "rg42" },
      { reps: 2, distance: 15, interval: null, stroke: null, pattern: null, note: "Rep 1: Exact pace, stroke count and turn quality; Rep 2: Hold pace with the final 15m of repetition four slightly stronger; For a goal time of 4:32:; Goal average = 34.0 seconds per 50m; Target range = approximately 33.7–34.5 from a push", subReps: 0, source: "rg43" },
      { reps: 1, distance: 400, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg44" },
      { reps: 1, distance: 100, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg45" },
      { reps: 1, distance: 100, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg46" },
      { reps: 1, distance: 100, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg47" },
      { reps: 1, distance: 100, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg48" },
      { reps: 1, distance: 400, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg49" },
      { reps: 4, distance: 50, interval: "1:10", stroke: null, pattern: null, note: null, subReps: 0, source: "rg50" },
      { reps: 1, distance: 25, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg51" },
      { reps: 1, distance: 25, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg52" },
      { reps: 4, distance: 400, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg53" },
      { reps: 1, distance: 400, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg54" },
      { reps: 1, distance: 100, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg55" },
      { reps: 1, distance: 100, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg56" },
      { reps: 1, distance: 100, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg57" },
      { reps: 1, distance: 100, interval: null, stroke: null, pattern: null, note: "Freestyle cycle: 5:30–6:30; Adjust the cycle to provide 20–40 seconds rest.", subReps: 0, source: "rg58" },
      { reps: 1, distance: 400, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg59" },
      { reps: 1, distance: 100, interval: "1:45", stroke: null, pattern: null, note: null, subReps: 0, source: "rg60" },
      { reps: 1, distance: 100, interval: null, stroke: null, pattern: null, note: "Rep 1: Establish control and stroke length; Rep 2: Include sighting every six to eight strokes; Rep 3: Simulate a mid-race surge during the third 100m; 4. Strong final 100m as though racing toward the finish", subReps: 0, source: "rg61" },
      { reps: 1, distance: 100, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg62" },
      { reps: 4, distance: 50, interval: "1:10", stroke: null, pattern: null, note: "25m easy into a race-quality turn; Fast underwater and breakout; Easy to the wall", subReps: 0, source: "rg63" },
      { reps: 4, distance: 25, interval: "0:50", stroke: null, pattern: null, note: null, subReps: 1, source: "rg64" },
      { reps: 1, distance: 200, interval: null, stroke: "Choice", pattern: null, note: null, subReps: 0, source: "rg65" },
      { reps: 4, distance: 50, interval: "1:00", stroke: null, pattern: null, note: null, subReps: 0, source: "rg66" },
      { reps: 4, distance: 25, interval: "0:40", stroke: null, pattern: null, note: null, subReps: 0, source: "rg67" },
    ],
  },
  'real-input-17.txt': {
    notes: [],
    repGroups: [
      { reps: 1, distance: 400, interval: null, stroke: "Free", pattern: null, note: null, subReps: 0, source: "rg1" },
      { reps: 1, distance: 100, interval: null, stroke: "Free", pattern: null, note: null, subReps: 0, source: "rg2" },
      { reps: 1, distance: 100, interval: null, stroke: "Back", pattern: null, note: null, subReps: 0, source: "rg3" },
      { reps: 1, distance: 100, interval: null, stroke: "Pull", pattern: null, note: null, subReps: 0, source: "rg4" },
      { reps: 1, distance: 100, interval: null, stroke: "Free", pattern: null, note: null, subReps: 0, source: "rg5" },
      { reps: 4, distance: 50, interval: "1:00", stroke: null, pattern: null, note: "25 Drill / 25 Swim", subReps: 0, source: "rg6" },
      { reps: 4, distance: 50, interval: "1:00", stroke: "Kick", pattern: null, note: "Build each 50; Strong streamline off every wall", subReps: 0, source: "rg7" },
      { reps: 4, distance: 25, interval: "0:40", stroke: null, pattern: null, note: "Underwater dolphin to 10–15m; Easy swim to wall", subReps: 0, source: "rg8" },
      { reps: 8, distance: 50, interval: "0:55", stroke: null, pattern: null, note: "Odd Build 1–3 Easy home", subReps: 0, source: "rg9" },
      { reps: 1, distance: 25, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg10" },
      { reps: 8, distance: 50, interval: "1:30", stroke: null, pattern: null, note: null, subReps: 0, source: "rg11" },
      { reps: 2, distance: 100, interval: null, stroke: "Free", pattern: null, note: "56.0", subReps: 0, source: "rg12" },
      { reps: 2, distance: 200, interval: null, stroke: "Free", pattern: null, note: "2:05", subReps: 0, source: "rg13" },
      { reps: 8, distance: 25, interval: "1:00", stroke: null, pattern: null, note: "Target - Approximately 103–105% race speed", subReps: 0, source: "rg14" },
      { reps: 2, distance: 100, interval: null, stroke: "Free", pattern: null, note: null, subReps: 0, source: "rg15" },
      { reps: 2, distance: 200, interval: null, stroke: "Free", pattern: null, note: null, subReps: 0, source: "rg16" },
      { reps: 2, distance: 100, interval: "5:00", stroke: null, pattern: null, note: null, subReps: 0, source: "rg17" },
      { reps: 2, distance: 50, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg18" },
      { reps: 2, distance: 15, interval: null, stroke: null, pattern: null, note: "25 Fast; :10 Rest; 25 Fast", subReps: 0, source: "rg19" },
      { reps: 2, distance: 75, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg20" },
      { reps: 2, distance: 15, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg21" },
      { reps: 2, distance: 25, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg22" },
      { reps: 1, distance: 100, interval: null, stroke: "Free", pattern: null, note: null, subReps: 0, source: "rg23" },
      { reps: 8, distance: 25, interval: "0:45", stroke: null, pattern: null, note: "15m into wall; Fast turn; Explosive breakout; Easy to finish", subReps: 0, source: "rg24" },
      { reps: 1, distance: 100, interval: null, stroke: "Free", pattern: null, note: null, subReps: 0, source: "rg25" },
      { reps: 1, distance: 100, interval: null, stroke: "Pull", pattern: null, note: null, subReps: 0, source: "rg26" },
      { reps: 1, distance: 100, interval: null, stroke: "Choice", pattern: null, note: "Surf/Tri (Approx. 4,400m)", subReps: 0, source: "rg27" },
      { reps: 1, distance: 400, interval: null, stroke: "Free", pattern: null, note: null, subReps: 0, source: "rg28" },
      { reps: 1, distance: 200, interval: null, stroke: "Pull", pattern: null, note: null, subReps: 0, source: "rg29" },
      { reps: 4, distance: 50, interval: "0:55", stroke: null, pattern: null, note: null, subReps: 0, source: "rg30" },
      { reps: 3, distance: 600, interval: "9:00", stroke: null, pattern: null, note: null, subReps: 0, source: "rg31" },
      { reps: 1, distance: 200, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg32" },
      { reps: 1, distance: 200, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg33" },
      { reps: 1, distance: 200, interval: null, stroke: null, pattern: null, note: "strong finish", subReps: 0, source: "rg34" },
      { reps: 1, distance: 400, interval: "1:10", stroke: null, pattern: null, note: null, subReps: 0, source: "rg35" },
      { reps: 1, distance: 200, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg36" },
      { reps: 1, distance: 200, interval: "2:28", stroke: null, pattern: null, note: null, subReps: 0, source: "rg37" },
      { reps: 1, distance: 200, interval: "2:24", stroke: null, pattern: null, note: null, subReps: 0, source: "rg38" },
      { reps: 1, distance: 200, interval: "2:20", stroke: null, pattern: null, note: "Total target: 7:12–7:20 per 600.", subReps: 0, source: "rg39" },
      { reps: 8, distance: 100, interval: "1:30", stroke: "Pull", pattern: null, note: "Hold 1:11–1:13 using paddles and buoy if appropriate.; Focus on:; High elbow catch; Consistent stroke rate; Strong body position; Controlled breathing", subReps: 0, source: "rg40" },
      { reps: 1, distance: 200, interval: null, stroke: "Free", pattern: null, note: null, subReps: 0, source: "rg41" },
      { reps: 1, distance: 100, interval: null, stroke: "Back", pattern: null, note: null, subReps: 0, source: "rg42" },
      { reps: 1, distance: 100, interval: null, stroke: "Choice", pattern: null, note: null, subReps: 0, source: "rg43" },
    ],
  },
  'real-input-19.txt': {
    notes: [],
    repGroups: [
      { reps: 8, distance: 100, interval: "0:20", stroke: null, pattern: "FFFKFBFR", note: "Rep 1: 50 free breathe 3 / 50 free catch up drill; Rep 2: 50 free breathe 5 / 50 Breast 3 kick + 1 pull; Rep 3: 50 free breathe 7 / 50 Back 6-3-6; Rep 4: 50 free breathe 9 / 50 fly 2-2-2", subReps: 8, fragments: 4, source: "rg1" },
      { reps: 4, distance: 125, interval: "1:50", stroke: null, pattern: null, note: null, subReps: 0, source: "rg3" },
      { reps: 4, distance: 100, interval: "1:30", stroke: null, pattern: null, note: "Free 4.00 nonstop kick on side @ 3.00", subReps: 0, source: "rg5" },
      { reps: 4, distance: 50, interval: "0:50", stroke: null, pattern: null, note: null, subReps: 0, source: "rg6" },
      { reps: 10, distance: 25, interval: null, stroke: "Free", pattern: null, note: "1-2 = 2 uw kicks + 2 fast arms; 2-4 = 4 uw kicks + 4 fast arms; 3-4 = 6 uw kicks + 6 fast arms; 4-8 = 8 uw kicks + 8 fast arms; 5 max ux kick to top + all the way fast", subReps: 0, source: "rg7" },
      { reps: 4, distance: 25, interval: null, stroke: "Kick", pattern: null, note: null, subReps: 0, source: "rg8" },
      { reps: 3, distance: 25, interval: null, stroke: "Kick", pattern: null, note: "2 x uw \" kick to 15m", subReps: 0, source: "rg9" },
      { reps: 1, distance: 25, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg10" },
      { reps: 8, distance: 100, interval: "2:00", stroke: null, pattern: null, note: null, subReps: 0, fragments: 4, source: "rg11" },
    ],
  },

  // V0.38 (2026-08-16): 3MT recognition. Bare "3MT", "3MT free",
  // "3-min all-out", "3 min test", "3-minute all-out kick" all emit
  // reps=1, distance=25, interval=null, intensity_type "3mt".
  // Neighbors (200 easy free, 4 x 50 kick) unaffected.
  'real-input-20.txt': {
    notes: [],
    repGroups: [
      { reps: 1, distance: 200, interval: null, stroke: "Free", pattern: null, note: null, subReps: 0, source: "rg1" },
      { reps: 1, distance: 25, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg2" },
      { reps: 4, distance: 50, interval: "1:00", stroke: "Kick", pattern: null, note: null, subReps: 0, source: "rg3" },
      { reps: 1, distance: 25, interval: null, stroke: "Free", pattern: null, note: null, subReps: 0, source: "rg4" },
      { reps: 1, distance: 25, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg5" },
      { reps: 1, distance: 25, interval: null, stroke: null, pattern: null, note: null, subReps: 0, source: "rg6" },
       { reps: 1, distance: 25, interval: null, stroke: "Kick", pattern: null, note: null, subReps: 0, source: "rg7" },
    ],
  },
  'real-input-21.txt': {
    notes: [],
    repGroups: [
      { reps: 8, distance: 100, interval: "1:30", stroke: null, pattern: null, note: null, subReps: 0, zoneTerm: "steady", source: "8×100 Steady on 1:30" },
      { reps: 4, distance: 50, interval: null, stroke: null, pattern: null, note: null, subReps: 0, zoneTerm: "sprint", source: "4×50 Sprint" },
      { reps: 8, distance: 100, interval: "1:30", stroke: "Free", pattern: null, note: null, subReps: 0, zoneTerm: null, source: "8×100 free on 1:30" },
      { reps: 4, distance: 100, interval: null, stroke: null, pattern: null, note: null, subReps: 0, zoneTerm: "hard", source: "4×100 Hard" },
    ],
  },

};
function normInterval(s: string | null): string {
  if (s == null) return "";
  return s.replace(".", ":").replace(/^0+(\d)/, "$1");
}

function normStroke(s: string | null): string {
  if (s == null) return "";
  return s.toLowerCase().trim();
}

function normPattern(s: string | null): string {
  if (s == null) return "";
  return s.toUpperCase().replace(/[^FBKRIM]/g, "");
}

function normNote(s: string | null): string {
  if (s == null) return "";
  return s.toLowerCase().trim();
}

export function matchesExpected(
  actual: {
    reps: number | null;
    distance: number | null;
    interval: string | null;
    stroke: string | null;
    pattern: string | null;
    note: string | null;
    subReps?: number;
    dive?: boolean;
    suit?: boolean;
     gear?: string[] | null;
     fragments?: number | null;
     zoneTerm?: string | null;
   },
  expected: ExpectedRepGroup,
): boolean {
  if (actual.reps == null || actual.distance == null) return false;
  if (Math.abs(actual.reps - expected.reps) > 1) return false;
  if (actual.distance !== expected.distance) return false;
  if (normInterval(actual.interval) !== normInterval(expected.interval)) return false;
  // v2 fields
  if (normStroke(actual.stroke) !== normStroke(expected.stroke)) return false;
  if (normPattern(actual.pattern) !== normPattern(expected.pattern)) return false;
  if (normNote(actual.note) !== normNote(expected.note)) return false;
  // ponytail (autoresearch iter 7, 2026-07-19): when sub-reps are
  // present (as-notation), the pattern shorthand is ambiguous
  // (e.g. K=kick vs K=breast). The structured sub-reps are the
  // ground truth — only match pattern shorthand for pure rotation
  // patterns (FBBF/FBF/FBFB), not for as-notation sub-reps.
  const hasSubReps = (actual.subReps ?? 0) > 0;
  const expectedHasSubReps = expected.subReps > 0;
  if (!hasSubReps && !expectedHasSubReps) {
    if (normPattern(actual.pattern) !== normPattern(expected.pattern)) return false;
  }
  if (expectedHasSubReps) {
    if ((actual.subReps ?? 0) !== expected.subReps) return false;
  }
  // v3 fields (metadata phase): dive, suit, gear
  if (expected.dive !== undefined && (actual.dive ?? false) !== expected.dive) return false;
  if (expected.suit !== undefined && (actual.suit ?? false) !== expected.suit) return false;
  if (expected.gear !== undefined) {
    const actualGear = actual.gear ?? [];
    const expectedGear = expected.gear;
    // Every expected gear must be present in actual
    for (const g of expectedGear) {
      if (!actualGear.includes(g)) return false;
    }
  }
  // v4: fragment count (composite sets)
  if (expected.fragments !== undefined) {
    const actualFragCount = actual.fragments ?? 0;
    if (actualFragCount !== expected.fragments) return false;
  }
  if (expected.zoneTerm !== undefined && (actual.zoneTerm ?? null) !== expected.zoneTerm) return false;
  return true;
}
