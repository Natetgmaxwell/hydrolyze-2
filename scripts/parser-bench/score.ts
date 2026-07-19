// score.ts — runs the parser against one or more input files, scores
// each against its expected set. Outputs a JSON report per input plus
// an aggregate.
import { parseWorkoutV2 } from "./engine";
import { EXPECTED, matchesExpected } from "./expected";
import * as fs from "node:fs";
import * as path from "node:path";

interface FlatRepGroup {
  reps: number | null;
  distance: number | null;
  interval: string | null;
  stroke: string | null;
  pattern: string | null;
  note: string | null;
  subReps: number;
  source: string;
}

function flatten(parsed: ReturnType<typeof parseWorkoutV2>): FlatRepGroup[] {
  const out: FlatRepGroup[] = [];
  for (const sec of parsed.sections) {
    for (const ns of sec.namedSets) {
      for (const rg of ns.repGroups) {
        // Extract a string representation of the pattern from the Rep[] array.
        // FBBF-style rotations are stored as sub-reps with stroke='Free'/'Back'/etc.
        // We concatenate their first letter to get 'FBBF'.
        let patternStr: string | null = null;
        if (rg.pattern && rg.pattern.length > 0) {
          // Filter to simple Reps with a stroke
          const simpleReps = rg.pattern.filter(
            (r) => (r as { type: string }).type === "simple",
          ) as Array<{ stroke: string | null; meters: number }>;
          if (simpleReps.length >= 2) {
            // All simple reps in a pattern should have a stroke
            patternStr = simpleReps
              .map((r) => strokeToLetter(r.stroke))
              .join("");
          }
        }
        // If no structured pattern, look for the FBBF-style string in details
        if (!patternStr && rg.details) {
          for (const d of rg.details) {
            const upper = d.toUpperCase();
            if (upper.length >= 2 && /^[FBKRIM]+$/.test(upper)) {
              patternStr = upper;
              break;
            }
          }
        }
        out.push({
          reps: rg.reps,
          distance: rg.distance,
          interval: rg.interval,
          stroke: rg.stroke,
          pattern: patternStr,
          note: rg.note,
          subReps: rg.pattern?.length ?? 0,
          source: (rg.details || []).join(" ").slice(0, 60),
        });
      }
    }
  }
  return out;
}

function strokeToLetter(s: string | null): string {
  if (!s) return "";
  const lower = s.toLowerCase();
  if (lower.startsWith("free") || lower === "freestyle") return "F";
  if (lower.startsWith("back") || lower === "backstroke") return "B";
  if (lower.startsWith("breast") || lower === "breaststroke") return "K";
  if (lower.startsWith("fly") || lower === "butterfly") return "R";
  if (lower === "im" || lower.startsWith("medley")) return "M";
  return "";
}

function scoreInput(inputFile: string): unknown {
  const text = fs.readFileSync(inputFile, "utf8");
  const parsed = parseWorkoutV2(text);
  const allRGs = flatten(parsed);
  const expected = EXPECTED[path.basename(inputFile)];

  if (!expected) {
    return {
      input: inputFile,
      error: `no EXPECTED entry for ${path.basename(inputFile)}`,
    };
  }

  // Greedy match: for each expected, find first actual that matches
  const matched = new Set<number>();
  const matches: Array<{ expected: (typeof expected)["repGroups"][0]; actual: FlatRepGroup | null }> = [];
  for (const exp of expected.repGroups) {
    let found = -1;
    for (let i = 0; i < allRGs.length; i++) {
      if (matched.has(i)) continue;
      if (matchesExpected(allRGs[i], exp)) {
        found = i;
        break;
      }
    }
    if (found >= 0) {
      matched.add(found);
      matches.push({ expected: exp, actual: allRGs[found] });
    } else {
      matches.push({ expected: exp, actual: null });
    }
  }

  const matchedCount = matches.filter((m) => m.actual != null).length;
  const totalExpected = expected.repGroups.length;
  const score = totalExpected > 0 ? matchedCount / totalExpected : 1;

  return {
    input: inputFile,
    expected_count: totalExpected,
    actual_count: allRGs.length,
    matched: matchedCount,
    score,
    notes_count: expected.notes.length,
    notes_actual: countActualNotes(parsed),
    matches: matches.map((m) => ({
      expected: m.expected,
      actual: m.actual,
      status: m.actual ? "matched" : "MISSING",
    })),
  };
}

function countActualNotes(parsed: ReturnType<typeof parseWorkoutV2>): number {
  let count = 0;
  for (const sec of parsed.sections) {
    for (const ns of sec.namedSets) {
      for (const rg of ns.repGroups) {
        if (rg.note) count++;
      }
    }
  }
  return count;
}

// Driver: score all input files in the bench dir
const benchDir = process.cwd();
const inputs = fs.readdirSync(benchDir)
  .filter((f) => f.startsWith("real-input-") && f.endsWith(".txt"))
  .sort();

const results = inputs.map((f) => scoreInput(path.join(benchDir, f)));

const aggregate = {
  files: results.length,
  total_score: results.reduce((acc, r) => {
    const s = (r as { score?: number }).score ?? 0;
    return acc + s;
  }, 0) / Math.max(1, results.length),
  per_file: results.map((r) => ({
    input: (r as { input: string }).input,
    score: (r as { score?: number }).score,
    matched: (r as { matched?: number }).matched,
    expected: (r as { expected_count?: number }).expected_count,
  })),
};

console.log("=== AGGREGATE ===");
console.log(JSON.stringify(aggregate, null, 2));
console.log();
console.log("=== PER-INPUT DETAIL ===");
for (const r of results) {
  console.log(JSON.stringify(r, null, 2));
  console.log();
}
process.exit(aggregate.total_score === 1.0 ? 0 : 1);
