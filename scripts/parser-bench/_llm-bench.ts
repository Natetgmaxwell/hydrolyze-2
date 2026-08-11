/**
 * _llm-bench.ts — runs the LLM parser prototype as a subprocess on the
 * 19 real coach inputs and aggregates per-input coverage.
 *
 * Usage:
 *   GROQ_API_KEY=*** npx tsx _llm-bench.ts
 *
 * Subprocess approach (vs importing llm-parser.ts directly) because the
 * prototype is a CLI script with main() at module scope. Refactoring it
 * to export would couple the prototype to the bench; subprocess keeps
 * them independent.
 *
 * This is the "did the swap break anything" smoke test. Not a corpus
 * scorer — that's score.ts. This is the LLM-specific signal: every
 * real input should produce >=1 repGroup.
 */

import { execFileSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";

const BENCH_DIR = path.dirname(new URL(import.meta.url).pathname);

interface BenchResult {
  file: string;
  rgCount: number;
  withFragments: number;
  error?: string;
  elapsedMs: number;
}

function runPrototype(inputFile: string): { rgCount: number; withFragments: number; stderr: string; stdout: string } {
  const stdout = execFileSync("npx", ["tsx", "llm-parser.ts", inputFile], {
    cwd: BENCH_DIR,
    env: process.env,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  const summaryMatch = stdout.match(/\[SUMMARY\] (\d+) repGroups, (\d+) with fragments/);
  const rgCount = summaryMatch ? parseInt(summaryMatch[1]) : 0;
  const withFragments = summaryMatch ? parseInt(summaryMatch[2]) : 0;
  return { rgCount, withFragments, stdout, stderr: "" };
}

async function benchOne(file: string): Promise<BenchResult> {
  const t0 = Date.now();
  try {
    const { rgCount, withFragments } = runPrototype(file);
    return { file, rgCount, withFragments, elapsedMs: Date.now() - t0 };
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return {
      file,
      rgCount: 0,
      withFragments: 0,
      error: msg.slice(0, 200),
      elapsedMs: Date.now() - t0,
    };
  }
}

async function main() {
  const inputs = fs.readdirSync(BENCH_DIR)
    .filter((f) => /^real-input-\d+\.txt$/.test(f))
    .sort((a, b) => {
      const na = parseInt(a.match(/real-input-(\d+)/)![1]);
      const nb = parseInt(b.match(/real-input-(\d+)/)![1]);
      return na - nb;
    });

  console.error(`[BENCH] running LLM parser on ${inputs.length} real inputs (sequential, rate-limited)\n`);

  const results: BenchResult[] = [];
  for (const file of inputs) {
    const r = await benchOne(file);
    results.push(r);
    const status = r.error ? `ERROR (${r.error.slice(0, 60)})` : `${r.rgCount} rg, ${r.withFragments} frag`;
    console.error(`  ${file.padEnd(20)} ${status.padEnd(40)} ${r.elapsedMs}ms`);
    // ponytail: rate-limit guard. gpt-oss-20b free tier is 8K TPM.
    // ~3.2K tokens per call × 19 inputs ≈ 60K tokens. 25s gap = ~2 calls/min.
    if (file !== inputs[inputs.length - 1]) {
      console.error(`  ... waiting 25s for rate limit ...`);
      await new Promise((resolve) => setTimeout(resolve, 25_000));
    }
  }

  const totalRgs = results.reduce((acc, r) => acc + r.rgCount, 0);
  const totalFragments = results.reduce((acc, r) => acc + r.withFragments, 0);
  const totalErrors = results.filter((r) => r.error).length;
  const totalEmpty = results.filter((r) => !r.error && r.rgCount === 0).length;

  console.error(`\n[BENCH] summary:`);
  console.error(`  total repGroups:      ${totalRgs}`);
  console.error(`  total with fragments: ${totalFragments}`);
  console.error(`  errors:               ${totalErrors}`);
  console.error(`  empty (0 repGroups):  ${totalEmpty}`);

  // ponytail: this is the "did the pipeline work" assert. Fail loud
  // if any input produced 0 repGroups or errored — that's a regression
  // vs the prototype's known-good state.
  if (totalErrors > 0 || totalEmpty > 0) {
    console.error(`\n[FAIL] ${totalErrors} errors, ${totalEmpty} empty results`);
    process.exit(1);
  }
  console.error(`\n[PASS] all ${inputs.length} inputs parsed non-empty`);
}

main().catch((e) => {
  console.error("FATAL:", e);
  process.exit(1);
});
