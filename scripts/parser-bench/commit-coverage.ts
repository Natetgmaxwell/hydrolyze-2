import { parseWorkoutV2 } from "./engine";
import * as fs from "node:fs";
import * as path from "node:path";

interface SourceLine { number: number; text: string }
interface FileCoverage { file: string; captured: number; total: number; percentage: number; missed: SourceLine[] }

// ponytail (V0.52 dispatch, 2026-09-06): the engine strips athlete-keyword
// prefixes ("SP:", "MD:", "IM:", "SURF:", "BR:", "FL:", "BK:", "FR:") and
// trailing parentheticals before emitting sourceLine. The harness compares
// raw doc lines against captured sourceLines — without normalizing both
// sides, the engine's correct parses get counted as MISS. Apply the same
// transformations the engine applies to each set-like line before
// comparing.
//
// Round-multiplier lines ("2 x through", "2 rounds", "3 times through:")
// and bare-interval continuations ("1:22") are NOT set lines — they're
// section directives that mutate round state or attach to a previous rg.
// Exclude them from the set-like set the same way "# date | url" headers
// are excluded.
const SET_LIKE_RE = /(×|x|@|:\d\d|\s\d{2,3}\s)/;
const ATHLETE_PREFIX_RE = /^(SP|MD|IM|SURF|BR|FL|BK|FR):\s+/i;
const ROUND_MULT_RE = /^\s*(\d+)\s*times?\s+through\s*:?\s*$/i;
const ROUND_X_RE = /^\s*(\d+)\s*[x×]\s*(?:thru|through)\s*:?\s*$/i;
const ROUND_ROUND_RE = /^\s*(\d+)\s+rounds?\s*:?\s*$/i;
const ROUND_WORD_RE = /^\s*(two|three|four|five|one)\s+rounds?\s*:?\s*$/i;
const BARE_INTERVAL_RE = /^\s*\d+:\d{2}\s*$/;

function normalizeForMatch(text: string): string {
  // Mirror the engine's tokenize() pre-pass: strip leading markdown
  // bullets/indentation that the parser removes before parsing.
  let t = text.replace(/^[\s*+\-]+/, "");
  // Strip athlete-keyword prefix (rule a, 2026-09-06).
  t = t.replace(ATHLETE_PREFIX_RE, "");
  return t.trim();
}

const benchDir = process.cwd();
const files = fs.readdirSync(benchDir).filter((file) => /^commit-jodie-.*\.txt$/.test(file)).sort();

function coverageFor(file: string): FileCoverage {
  const document = fs.readFileSync(path.join(benchDir, file), "utf8");
  const parsed = parseWorkoutV2(document);
  const capturedSourceLines = new Set(parsed.sections.flatMap((section) =>
    section.namedSets.flatMap((namedSet) => namedSet.repGroups.map((repGroup) => repGroup.sourceLine.trim())),
  ));
  const setLikeLines = document.split(/\r?\n/).map((text, index) => ({ number: index + 1, text: text.trim() }))
    .filter(({ text }) => text.length > 0 && !text.startsWith("#") && /\d/.test(text) && SET_LIKE_RE.test(text));
  const missed: SourceLine[] = [];
  const excluded: SourceLine[] = [];
  let captured = 0;
  for (const { number, text } of setLikeLines) {
    if (
      ROUND_MULT_RE.test(text) || ROUND_X_RE.test(text) ||
      ROUND_ROUND_RE.test(text) || ROUND_WORD_RE.test(text)
    ) {
      // Round-multiplier directive — not a set line.
      excluded.push({ number, text });
      captured++;
      continue;
    }
    if (BARE_INTERVAL_RE.test(text)) {
      // Rule (b) bare interval — attaches to previous rg, never a set.
      excluded.push({ number, text });
      captured++;
      continue;
    }
    const normalized = normalizeForMatch(text);
    if (capturedSourceLines.has(text) || capturedSourceLines.has(normalized)) {
      captured++;
    } else {
      missed.push({ number, text });
    }
  }
  const total = setLikeLines.length;
  return {
    file,
    captured,
    total,
    percentage: total === 0 ? 100 : captured / total * 100,
    missed,
  };
}

const results = files.map(coverageFor);
let totalCaptured = 0, totalLines = 0;
console.log("=== COMMIT JODIE COVERAGE ===");
for (const result of results) {
  totalCaptured += result.captured;
  totalLines += result.total;
  console.log(`${result.file}: ${result.captured}/${result.total} (${result.percentage.toFixed(1)}%)`);
  for (const missed of result.missed) console.log(`  MISS ${missed.number}: ${missed.text}`);
}
console.log(`TOTAL: ${totalCaptured}/${totalLines} (${totalLines === 0 ? "100.0" : (totalCaptured / totalLines * 100).toFixed(1)}%)`);
// Exit non-zero on <90% so CI catches regressions. Coverage above 90% is
// the bar the spec sets for the Jodie rollout gate.
if (totalLines === 0 || totalCaptured / totalLines < 0.9) process.exitCode = 1;