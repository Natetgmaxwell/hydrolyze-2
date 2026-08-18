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
  dive: boolean;
  suit: boolean;
  gear: string[] | null;
  fragments: number;
  zoneTerm: string | null;
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
            // ponytail (autoresearch iter 5, 2026-07-19): strip non-pattern
            // punctuation like @, :, ., etc. before the FBKRIM check, so
            // 'FBFB@' (with @ attached) is recognized as a pattern.
            const stripped = d.replace(/[^a-zA-Z]/g, "");
            if (stripped.length >= 2 && /^[FBKRIM]+$/.test(stripped)) {
              patternStr = stripped;
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
          dive: rg.dive ?? false,
          suit: rg.suit ?? false,
           gear: rg.gear,
           fragments: rg.fragments?.length ?? 0,
           zoneTerm: (rg as { zoneTerm?: string | null }).zoneTerm ?? null,
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
  if (lower.startsWith("free") || lower === "freestyle" || lower === "swim" || lower === "fists") return "F";
  if (lower.startsWith("back")) return "B";
  if (lower.startsWith("breast")) return "K";
  if (lower.startsWith("fly") || lower === "butterfly") return "R";
  if (lower.startsWith("kick") || lower === "flutter" || lower === "dolphin") return "K";
  if (lower === "im" || lower.startsWith("medley")) return "M";
  if (lower === "drill") return "D";
  return "";
}

function normInterval(s: string | null): string {
  if (s == null) return "";
  return s.replace(".", ":").replace(/^0+(\d)/, "$1");
}

function tokenizeSource(s: string): Set<string> {
  return new Set(
    (s || "").toLowerCase().split(/\W+/).filter((t) => t.length > 1),
  );
}

function sourceSimilarity(a: string, b: string): number {
  const ta = tokenizeSource(a);
  if (ta.size === 0) return 0;
  const tb = tokenizeSource(b);
  let common = 0;
  for (const t of ta) if (tb.has(t)) common++;
  return common;
}

function matchesTriple(
  actual: { reps: number | null; distance: number | null; interval: string | null; zoneTerm?: string | null },
  expected: { reps: number; distance: number; interval: string | null; zoneTerm?: string | null },
): boolean {
  if (actual.reps == null || actual.distance == null) return false;
  if (Math.abs(actual.reps - expected.reps) > 1) return false;
  if (actual.distance !== expected.distance) return false;
  if (normInterval(actual.interval) !== normInterval(expected.interval)) return false;
  if (expected.zoneTerm !== undefined && (actual.zoneTerm ?? null) !== expected.zoneTerm) return false;
  return true;
}

function unmatchedIndices(
  pool: FlatRepGroup[],
  matched: Set<number>,
  predicate: (rg: FlatRepGroup) => boolean,
): number[] {
  const out: number[] = [];
  for (let i = 0; i < pool.length; i++) {
    if (matched.has(i)) continue;
    if (predicate(pool[i])) out.push(i);
  }
  return out;
}

function pickBySourceSimilarity(
  expectedSource: string,
  pool: FlatRepGroup[],
  candidates: number[],
): number {
  let bestIdx = candidates[0];
  let bestSim = sourceSimilarity(expectedSource, pool[bestIdx].source);
  for (let k = 1; k < candidates.length; k++) {
    const idx = candidates[k];
    const sim = sourceSimilarity(expectedSource, pool[idx].source);
    if (sim > bestSim || (sim === bestSim && idx < bestIdx)) {
      bestSim = sim;
      bestIdx = idx;
    }
  }
  return bestIdx;
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

  // Match each expected against an actual using a tiered strategy:
  //   1. Prefer matchesExpected candidates, ranked by source-text similarity
  //      (token overlap between expected.source and actual.source).
  //   2. Fall back to a looser reps+distance+interval triple match when
  //      matchesExpected yields nothing (e.g. notes parsed differently or
  //      pattern shorthand differs for as-notation sub-reps).
  //   3. If still ambiguous, pick the first available actual (greedy).
  const matched = new Set<number>();
  const matches: Array<{ expected: (typeof expected)["repGroups"][0]; actual: FlatRepGroup | null }> = [];
  for (const exp of expected.repGroups) {
    const strictIdx = unmatchedIndices(allRGs, matched, (a) => matchesExpected(a, exp));
    let chosen: number | null = null;
    if (strictIdx.length > 0) {
      chosen = pickBySourceSimilarity(exp.source, allRGs, strictIdx);
    } else {
      const tripleIdx = unmatchedIndices(allRGs, matched, (a) => matchesTriple(a, exp));
      if (tripleIdx.length > 0) {
        chosen = pickBySourceSimilarity(exp.source, allRGs, tripleIdx);
      }
    }
    if (chosen !== null) {
      matched.add(chosen);
      matches.push({ expected: exp, actual: allRGs[chosen] });
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
