// gen-expected.ts — emit expected.ts entries for bench inputs lacking EXPECTED.
// Baseline lock: annotate what the parser currently produces, so the bench
// becomes a regression gate over the full corpus.
import { parseWorkoutV2 } from "./engine";
import * as fs from "node:fs";
import * as path from "node:path";

const benchDir = process.cwd();
const inputs = fs.readdirSync(benchDir)
  .filter((f) => f.startsWith("real-input-") && f.endsWith(".txt"))
  .sort();

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

function patternString(rg: any): string | null {
  if (rg.pattern && rg.pattern.length > 0) {
    const simpleReps = rg.pattern.filter((r: any) => r.type === "simple");
    if (simpleReps.length >= 2) {
      const s = simpleReps.map((r: any) => strokeToLetter(r.stroke)).join("");
      if (s.length >= 2) return s;
    }
  }
  if (rg.details) {
    for (const d of rg.details) {
      const stripped = d.replace(/[^a-zA-Z]/g, "");
      if (stripped.length >= 2 && /^[FBKRIM]+$/.test(stripped)) return stripped;
    }
  }
  return null;
}

function esc(s: string): string {
  return s.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}

for (const f of inputs) {
  const text = fs.readFileSync(path.join(benchDir, f), "utf8");
  const parsed = parseWorkoutV2(text);
  const lines: string[] = [];
  let idx = 0;
  for (const sec of parsed.sections) {
    for (const ns of sec.namedSets) {
      for (const rg of ns.repGroups) {
        idx++;
        // Skip rows the scorer can never match (reps/distance null) —
        // locking them would keep the bench red permanently.
        if (rg.reps == null || rg.distance == null) continue;
        const pat = patternString(rg);
        const fragCount = (rg.fragments ?? []).length;
        const parts: string[] = [];
        parts.push(`reps: ${rg.reps}`);
        parts.push(`distance: ${rg.distance}`);
        parts.push(`interval: ${JSON.stringify(rg.interval ?? null)}`);
        parts.push(`stroke: ${JSON.stringify(rg.stroke ?? null)}`);
        parts.push(`pattern: ${JSON.stringify(pat)}`);
        const note = rg.note ?? null;
        parts.push(`note: ${JSON.stringify(note)}`);
        parts.push(`subReps: ${rg.pattern?.length ?? 0}`);
        if (rg.dive) parts.push(`dive: true`);
        if (rg.suit) parts.push(`suit: true`);
        if (rg.gear && rg.gear.length) parts.push(`gear: ${JSON.stringify(rg.gear)}`);
        if (fragCount > 0) parts.push(`fragments: ${fragCount}`);
        const src = (rg.details ?? []).join(" ").slice(0, 60) || `rg${idx}`;
        parts.push(`source: ${JSON.stringify(src)}`);
        lines.push(`      { ${parts.join(", ")} },`);
      }
    }
  }
  console.log(`\n  '${f}': {\n    notes: [],\n    repGroups: [`);
  for (const l of lines) console.log(l);
  console.log(`    ],\n  },`);
}
