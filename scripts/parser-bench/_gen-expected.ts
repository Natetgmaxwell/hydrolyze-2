/**
 * _gen-expected.ts — generate expected.json from expected.ts
 * (the 21 real-input corpus). Mirrors _gen-expected-jodie.ts.
 *
 * Run:
 *   npx tsx scripts/parser-bench/_gen-expected.ts > scripts/parser-bench/expected.json
 */
import * as fs from "node:fs";
import * as path from "node:path";

import { EXPECTED } from "./expected.ts";

const out = path.resolve("./expected.json");
fs.writeFileSync(out, JSON.stringify(EXPECTED, null, 2) + "\n", "utf8");
console.error(`wrote ${out}`);
