import { parseWorkoutV2 } from "./engine";
import { normalizeFragmentDistances } from "./_decimal-distance-fix";
import * as fs from "node:fs";

const inputFile = process.argv[2];
if (!inputFile) {
  console.error("usage: tsx measure.ts <input-file>");
  process.exit(2);
}
const text = fs.readFileSync(inputFile, "utf8");
try {
  const result = parseWorkoutV2(text);
  // ponytail (2026-09-08): mirror the edge function's serialization-time
  // normalizer so measure.ts output matches what the deployed function
  // would emit on the wire. Without this, fragment.distance shows the raw
  // float (12.5) here but the integer (13) in the live response — the
  // bench and the device would disagree on the same input.
  console.log(JSON.stringify(normalizeFragmentDistances(result), null, 2));
} catch (e) {
  console.error("PARSE THREW:", e);
  process.exit(1);
}
