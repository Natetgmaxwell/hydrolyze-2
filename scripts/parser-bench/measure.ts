import { parseWorkoutV2 } from "./engine";
import * as fs from "node:fs";

const inputFile = process.argv[2];
if (!inputFile) {
  console.error("usage: tsx measure.ts <input-file>");
  process.exit(2);
}
const text = fs.readFileSync(inputFile, "utf8");
try {
  const result = parseWorkoutV2(text);
  console.log(JSON.stringify(result, null, 2));
} catch (e) {
  console.error("PARSE THREW:", e);
  process.exit(1);
}
