/**
 * _gen-expected-jodie.ts — generate expected.jodie.json from
 * expected.jodie.ts. Run with:
 *   npx tsx scripts/parser-bench/_gen-expected-jodie.ts > scripts/parser-bench/expected.jodie.json
 *
 * The JSON is what `_jodie-quality.py` consumes (Python can't import
 * TypeScript). The TypeScript file remains the canonical source of
 * truth — JSON is regenerated from it.
 */

import * as fs from "node:fs";
import * as path from "node:path";

import { EXPECTED_JODIE } from "./expected.jodie.ts";

const out = path.resolve("./expected.jodie.json");
fs.writeFileSync(out, JSON.stringify(EXPECTED_JODIE, null, 2) + "\n", "utf8");
console.error(`wrote ${out}`);
