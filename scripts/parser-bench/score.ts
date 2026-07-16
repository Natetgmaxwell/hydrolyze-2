// score.ts — runs the parser, scores actual vs expected. Outputs a JSON report.
import { parseWorkoutV2 } from "./engine";
import { EXPECTED, matchesExpected } from "./expected";
import * as fs from "node:fs";

const inputFile = process.argv[2];
if (!inputFile) {
  console.error("usage: tsx score.ts <input-file>");
  process.exit(2);
}
const text = fs.readFileSync(inputFile, "utf8");
const parsed = parseWorkoutV2(text);

// Flatten all rep groups from the parse
const allRGs: Array<{ reps: number | null; distance: number | null; interval: string | null; source: string }> = [];
for (const sec of parsed.sections) {
  for (const ns of sec.namedSets) {
    for (const rg of ns.repGroups) {
      allRGs.push({
        reps: rg.reps,
        distance: rg.distance,
        interval: rg.interval,
        source: (rg.details || []).join(" ").slice(0, 60),
      });
    }
  }
}

// Greedy match: for each expected, find first actual that matches
const matched = new Set<number>();
const matches: Array<{ expected: typeof EXPECTED[0]; actual: typeof allRGs[0] | null }> = [];
for (const exp of EXPECTED) {
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

const score = matches.filter((m) => m.actual != null).length / EXPECTED.length;
const report = {
  input: inputFile,
  expected_count: EXPECTED.length,
  actual_count: allRGs.length,
  matched: matches.filter((m) => m.actual != null).length,
  score: score,
  matches,
};
console.log(JSON.stringify(report, null, 2));
process.exit(score === 1.0 ? 0 : 1);
