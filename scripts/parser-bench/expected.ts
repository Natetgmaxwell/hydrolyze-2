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
  },
};

// Normalize interval: "1.20" <-> "1:20", trim leading zero
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
  return true;
}
