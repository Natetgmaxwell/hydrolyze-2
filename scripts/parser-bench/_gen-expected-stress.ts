/**
 * _gen-expected-stress.ts — generate expected.stress.json from
 * expected.stress.ts. Mirrors _gen-expected-jodie.ts.
 *
 * Run:
 *   npx tsx scripts/parser-bench/_gen-expected-stress.ts > scripts/parser-bench/expected.stress.json
 */
import * as fs from "node:fs";
import * as path from "node:path";

import { EXPECTED_STRESS } from "./expected.stress.ts";

const out = path.resolve("./expected.stress.json");
fs.writeFileSync(out, JSON.stringify(EXPECTED_STRESS, null, 2) + "\n", "utf8");
console.error(`wrote ${out}`);
