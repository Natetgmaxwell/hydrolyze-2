import { parseWorkoutV2 } from "./engine";
import * as fs from "node:fs";
import * as path from "node:path";

interface SourceLine { number: number; text: string }
interface FileCoverage { file: string; captured: number; total: number; percentage: number; missed: SourceLine[] }

const SET_LIKE_RE = /(×|x|@|:\d\d|\s\d{2,3}\s)/;
const benchDir = process.cwd();
const files = fs.readdirSync(benchDir).filter((file) => /^commit-jodie-.*\.txt$/.test(file)).sort();

function coverageFor(file: string): FileCoverage {
  const document = fs.readFileSync(path.join(benchDir, file), "utf8");
  const parsed = parseWorkoutV2(document);
  const capturedSourceLines = new Set(parsed.sections.flatMap((section) =>
    section.namedSets.flatMap((namedSet) => namedSet.repGroups.map((repGroup) => repGroup.sourceLine.trim())),
  ));
  // ponytail (V0.52 dispatch, 2026-09-06): "# date | url" header lines and
// other comment lines (starting with "#") are file metadata, not sets.
// Filter them out of the setLike set so they don't count as MISS lines.
const setLikeLines = document.split(/\r?\n/).map((text, index) => ({ number: index + 1, text: text.trim() }))
    .filter(({ text }) => text.length > 0 && !text.startsWith("#") && /\d/.test(text) && SET_LIKE_RE.test(text));
  const missed = setLikeLines.filter(({ text }) => !capturedSourceLines.has(text));
  const captured = setLikeLines.length - missed.length;
  return { file, captured, total: setLikeLines.length, percentage: setLikeLines.length === 0 ? 100 : captured / setLikeLines.length * 100, missed };
}

const results = files.map(coverageFor);
const captured = results.reduce((sum, result) => sum + result.captured, 0);
const total = results.reduce((sum, result) => sum + result.total, 0);
console.log("=== COMMIT JODIE COVERAGE ===");
for (const result of results) {
  console.log(`${result.file}: ${result.captured}/${result.total} (${result.percentage.toFixed(1)}%)`);
  for (const missed of result.missed) console.log(`  MISS ${missed.number}: ${missed.text}`);
}
console.log(`TOTAL: ${captured}/${total} (${total === 0 ? "100.0" : (captured / total * 100).toFixed(1)}%)`);
if (total === 0 || captured / total < 0.9) process.exitCode = 1;
