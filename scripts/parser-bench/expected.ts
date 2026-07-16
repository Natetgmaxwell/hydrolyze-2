// expected.ts — hand-annotated expected output for real-input-1.txt.
// Each repGroup is a flat record {reps, distance, interval} the parser should produce.
// Notes / free-text lines are excluded from the expected set (the parser can drop
// them or attach them anywhere; the spec doesn't care).

export interface ExpectedRepGroup {
  reps: number;
  distance: number;
  interval: string | null;
  // The human source line this came from, for diagnostics.
  source: string;
}

export const EXPECTED: ExpectedRepGroup[] = [
  // Line 2: "400 kick for body/head position 100 free 100 back - floppy feet"
  // The coach means: 400 kick, then 100 free, then 100 back.
  { reps: 1, distance: 400, interval: null, source: "400 kick for body/head position 100 free 100 back - floppy feet" },
  { reps: 1, distance: 100, interval: null, source: "100 free (line 2, second set)" },
  { reps: 1, distance: 100, interval: null, source: "100 back (line 2, third set)" },
  // Line 5: 3 x 300 FBBF (free,back,breast, free) @ 4:30
  { reps: 3, distance: 300, interval: "4:30", source: "3 x 300 FBBF (free,back,breast, free) @ 4:30" },
  // Line 6: 3 x 300 free @ 4.30 as 1.fists/swim, 2. catch up/swim 3. swim
  { reps: 3, distance: 300, interval: "4:30", source: "3 x 300 free @ 4.30 as 1.fists/swim, 2. catch up/swim 3. swim" },
  // Line 9: 3 x 200 FBF @ 2:50 by
  { reps: 3, distance: 200, interval: "2:50", source: "3 x 200 FBF @ 2:50 by" },
  // Line 10: 3 x 200 free @ 2:50 same as above — pattern same as prev (FBF)
  { reps: 3, distance: 200, interval: "2:50", source: "3 x 200 free @ 2:50 same as above" },
  // Line 12: 3 x 100 FBFB@ 1.20
  { reps: 3, distance: 100, interval: "1:20", source: "3 x 100 FBFB@ 1.20" },
  // Line 13: 3 x 100 free @1.20 same as above
  { reps: 3, distance: 100, interval: "1:20", source: "3 x 100 free @1.20 same as above" },
  // Line 17: 1 x 400 FBFB
  { reps: 1, distance: 400, interval: null, source: "1 x 400 FBFB" },
];

// Lines intentionally excluded from expected (notes, free-text):
//   Line 1: "Float high Body position first..." → note
//   Line 7: 30 sec extra rest → note (not a set)
//   Line 8 (or whatever the actual line #): "fast for time" → note
//
// Tolerance: reps ±1 (because "as 1.X, 2.X, 3.X" notation might be parsed as 1 rep
// instead of 3). Distance must match exactly. Interval normalized: "1.20" matches
// "1:20" and "4.30" matches "4:30".

export function matchesExpected(actual: { reps: number | null; distance: number | null; interval: string | null }, expected: ExpectedRepGroup): boolean {
  if (actual.reps == null || actual.distance == null) return false;
  if (Math.abs(actual.reps - expected.reps) > 1) return false;
  if (actual.distance !== expected.distance) return false;
  // Normalize interval: "1.20" <-> "1:20", trim leading zero
  const norm = (s: string | null): string => {
    if (s == null) return "";
    return s.replace(".", ":").replace(/^0+(\d)/, "$1");
  };
  if (norm(actual.interval) !== norm(expected.interval)) return false;
  return true;
}
