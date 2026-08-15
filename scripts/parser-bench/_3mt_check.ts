// V0.38 slice 3 verification: run the regex engine on 3MT test strings
// plus one regression input. ESM requires explicit .ts extensions under
// node --experimental-strip-types, hence the duplicated import path.
import { parseWorkoutV2 } from "./engine.ts";

interface FlatRG {
  reps: number | null;
  distance: number | null;
  interval: string | null;
  stroke: string | null;
  intensityType: string | null;
  sourceLine: string | null;
}

function flat(input: string): FlatRG[] {
  const w = parseWorkoutV2(input);
  const out: FlatRG[] = [];
  for (const s of w.sections) {
    for (const ns of s.namedSets) {
      for (const rg of ns.repGroups) {
        out.push({
          reps: rg.reps,
          distance: rg.distance,
          interval: rg.interval,
          stroke: rg.stroke,
          intensityType: rg.intensity ? rg.intensity.type : null,
          sourceLine: rg.sourceLine ?? null,
        });
      }
    }
  }
  return out;
}

let pass = 0;
let fail = 0;

function check(name: string, input: string, expect: { idx: number; reps: number; distance: number; intensityType: string; intervalNull: boolean; stroke?: string }) {
  const rgs = flat(input);
  const rg = rgs[expect.idx];
  if (!rg) {
    console.log(`FAIL ${name}: no repGroup at index ${expect.idx} (got ${rgs.length}: ${JSON.stringify(rgs)})`);
    fail++;
    return;
  }
  const ok =
    rg.reps === expect.reps &&
    rg.distance === expect.distance &&
    rg.intensityType === expect.intensityType &&
    (expect.intervalNull ? rg.interval === null : true) &&
    (expect.stroke ? rg.stroke === expect.stroke : true);
  if (ok) {
    console.log(`PASS ${name}: ${JSON.stringify(rg)}`);
    pass++;
  } else {
    console.log(`FAIL ${name}: expected ${JSON.stringify(expect)}, got ${JSON.stringify(rg)}`);
    fail++;
  }
}

check("bare 3MT", "200 easy\n3MT\n4 x 50 kick", { idx: 1, reps: 1, distance: 25, intensityType: "3mt", intervalNull: true });
check("3MT free", "3MT free", { idx: 0, reps: 1, distance: 25, intensityType: "3mt", intervalNull: true, stroke: "Free" });
check("3-min all-out", "3-min all-out", { idx: 0, reps: 1, distance: 25, intensityType: "3mt", intervalNull: true });
check("3 min test", "3 min test", { idx: 0, reps: 1, distance: 25, intensityType: "3mt", intervalNull: true });
check("3-minute all-out", "3-minute all-out kick", { idx: 0, reps: 1, distance: 25, intensityType: "3mt", intervalNull: true, stroke: "Kick" });
check("3-MT", "3-MT", { idx: 0, reps: 1, distance: 25, intensityType: "3mt", intervalNull: true });

const mixed = flat("200 easy\n3MT\n4 x 50 kick @ 1:00");
const easy = mixed[0];
const threeMT = mixed[1];
const kick = mixed[2];
if (
  mixed.length === 3 &&
  easy && easy.reps === 1 && easy.distance === 200 && easy.intensityType === "easy" &&
  threeMT && threeMT.reps === 1 && threeMT.distance === 25 && threeMT.intensityType === "3mt" &&
  kick && kick.reps === 4 && kick.distance === 50 && kick.intensityType !== "3mt"
) {
  console.log(`PASS mixed neighbors unaffected: easy=${JSON.stringify(easy)} 3mt=${JSON.stringify(threeMT)} kick=${JSON.stringify(kick)}`);
  pass++;
} else {
  console.log(`FAIL mixed neighbors: ${JSON.stringify(mixed)}`);
  fail++;
}

const normal = flat("8 x 100 free @ 1:30\n4 x 50 max\n3 x 200 pull");
if (
  normal.length === 3 &&
  normal.every((rg) => rg.intensityType !== "3mt")
) {
  console.log(`PASS normal workout unaffected: ${JSON.stringify(normal)}`);
  pass++;
} else {
  console.log(`FAIL normal workout affected: ${JSON.stringify(normal)}`);
  fail++;
}

console.log(`\n${pass} pass, ${fail} fail`);
process.exit(fail > 0 ? 1 : 0);
