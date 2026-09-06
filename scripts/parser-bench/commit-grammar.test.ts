import assert from "node:assert/strict";
import { parseWorkoutV2 } from "./engine";

function groups(input: string) {
  return parseWorkoutV2(input).sections.flatMap((section) =>
    section.namedSets.flatMap((namedSet) => namedSet.repGroups),
  );
}

const parenthetical = groups("50 drill / 50 build (single arm Fingers on shoulder) (catch pause drill)");
assert.equal(parenthetical.length, 1);
assert.equal(parenthetical[0].fragments?.length, 2);
assert.match(parenthetical[0].note ?? "", /catch pause drill/i);

// ponytail (V0.52 dispatch brief, 2026-09-06): DEFERRED — meter-prose composite
// rule was explicitly excluded from this iteration's scope ("the prior
// agent's analysis says the corpus hits are in the numbered-instruction
// branch already"). Keeping the assertion here as a TODO so a future
// session knows the gap is intentional, not lost.
// const meterProse = groups("15 m MAX + 35 m very easy");
// assert.equal(meterProse.length, 1);
// assert.equal(meterProse[0].fragments?.length, 2);
// assert.equal(meterProse[0].distance, 50);

const athletePrefix = parseWorkoutV2("SP: 25 race speed + easy");
const athleteSet = athletePrefix.sections[0].namedSets[0];
assert.equal(athleteSet.label, "SP");
assert.equal(athleteSet.repGroups[0].sourceLine, "25 race speed + easy");

// ponytail (V0.52 dispatch, rule e, 2026-09-06): "2 x through" round
// multiplier. The existing round-multiplier detector in the main loop
// (engine.ts ~line 1898) already handles "Nx through" via
// /^(\d+)\s*[x×]\s*(?:thru|through)\s*:?\s*$/i. No engine change needed —
// document coverage via these grammar assertions.
{
  const through = groups("2 x through\n4 x 100 free");
  assert.equal(through.length, 1);
  assert.equal(through[0].reps, 8);
  assert.equal(through[0].distance, 100);
  assert.equal(through[0].stroke, "Free");
  assert.equal(through[0].sourceLine, "4 x 100 free");

  // Trailing colon variant.
  const throughColon = groups("2 x through:\n4 x 100 free");
  assert.equal(throughColon.length, 1);
  assert.equal(throughColon[0].reps, 8);

  // × (U+00D7) variant.
  const timesSign = groups("3 × through\n4 x 50 free");
  assert.equal(timesSign.length, 1);
  assert.equal(timesSign[0].reps, 12);

  // Multiplies multiple repGroups, persists across blank lines.
  const multiplies = groups("2 x through\n\n4 x 100 free\n\n8 x 50");
  assert.equal(multiplies.length, 2);
  assert.equal(multiplies[0].reps, 8);
  assert.equal(multiplies[1].reps, 16);

  // Adjacent to "each 100:" / "repeat" / word-number rounds — the
  // existing round-multiplier detector handles all four forms with the
  // same machinery. Verify "two rounds" still works as a sanity check.
  const wordRound = groups("two rounds:\n4 x 100 free");
  assert.equal(wordRound.length, 1);
  assert.equal(wordRound[0].reps, 8);

  // Indented block (commit-jodie-08 form: indented subsequent lines still
  // receive the multiplier — roundMultiplier is set at section scope).
  const indented = groups("      2 x through\n\n            4 x 200 holding pace 3:00\n            4 x 100 desc 1:30");
  assert.equal(indented.length, 2);
  assert.equal(indented[0].reps, 8);
  assert.equal(indented[1].reps, 8);
}

const continuedInterval = groups("4 x 50\n1:22");
assert.equal(continuedInterval.length, 1);
assert.equal(continuedInterval[0].interval, "1:22");

// ponytail (V0.52 dispatch brief, 2026-09-06): "25 strong / 25 easy"
// (slash-only, no enclosing parens) — rule (f) standalone slash-set /
// plus-set composite. The main-loop "per-rep variant instruction"
// path (~line 2287) previously misclassified these as per-rep notes
// when they summed to the previous rg's distance; rule (f) explicitly
// excludes standalone slash/plus composites from that path and rewrites
// them in parseRepGroup to "1 x (a / b)" form so the fragment path
// handles them.
{
  // Slash form (most common from the Jodie corpus).
  const strong = groups("25 strong / 25 easy");
  assert.equal(strong.length, 1);
  assert.equal(strong[0].reps, 1);
  assert.equal(strong[0].distance, 50);
  assert.equal(strong[0].fragments?.length, 2);
  assert.equal(strong[0].fragments?.[0].distance, 25);
  assert.equal(strong[0].fragments?.[1].distance, 25);
  assert.equal(strong[0].sourceLine, "25 strong / 25 easy");

  const surge = groups("25 surge / 25 controlled");
  assert.equal(surge.length, 1);
  assert.equal(surge[0].fragments?.length, 2);
  assert.equal(surge[0].fragments?.[0].note, "surge");
  assert.equal(surge[0].fragments?.[1].note, "controlled");

  // Period at end is fine — tokenize strips it.
  const scullPeriod = groups("25 scull / 25 perfect swimming.");
  assert.equal(scullPeriod.length, 1);
  assert.equal(scullPeriod[0].fragments?.length, 2);

  // Plus form.
  const raceRhythm = groups("25 race rhythm + 25 easy");
  assert.equal(raceRhythm.length, 1);
  assert.equal(raceRhythm[0].fragments?.length, 2);

  const pursuit = groups("25 pursuit + 25 easy");
  assert.equal(pursuit.length, 1);
  assert.equal(pursuit[0].fragments?.length, 2);

  // Plus form with trailing prose on the right side.
  const scullNote = groups("25 scull + 25 swim — connect catch to stroke");
  assert.equal(scullNote.length, 1);
  assert.equal(scullNote[0].fragments?.length, 2);
  assert.equal(scullNote[0].fragments?.[1].note?.includes("connect catch to stroke"), true);

  // Three-segment standalone composite (parseCompositeFragments handles
  // any N>=2 segments).
  const three = groups("25 a / 25 b / 25 c");
  assert.equal(three.length, 1);
  assert.equal(three[0].fragments?.length, 3);

  // ─── Regression guards ───

  // Danger case: lines containing their own "Nx" rep patterns must NOT
  // be split by rule (f). The existing + -split path handles
  // "400 swim + 4 × 100 pull + 4 × 50" — verify that the rg count is
  // >=2 (the + -split fires multiple times) and no rule-f composite
  // with fragments is produced.
  {
    const danger = groups("400 swim + 4 × 100 pull + 4 × 50");
    assert.equal(danger.length >= 2, true, "danger case should produce 2+ rg's via + -split");
    // No composite fragment — rule (f) skipped because of the
    // embedded "Nx" rep pattern.
    for (const rg of danger) {
      assert.equal(rg.fragments === null, true, "danger case must not produce fragments");
    }
  }

  // "as" notation lines — the slash inside "as" is per-rep variant
  // notation, NOT a top-level composite separator.
  const asNot = groups("4 x 50 free @ 1:00 as 25 strong + 25 easy");
  assert.equal(asNot.length, 1);
  assert.equal(asNot[0].fragments?.length ?? 0, 0);

  // Trailing "× N" multiplier anywhere in the segment means the slash
  // is inside a per-rep rotation, NOT a top-level composite
  // (real-input-7 line 5: "400 Swim 100 Free / 100 Back × 2 - Build
  // effort each 100").
  const trailMult = groups("400 Swim 100 Free / 100 Back × 2 - Build effort each 100");
  // Should produce a "400 Swim" parent set + a "100 Back × 2" sub-set,
  // NOT a single composite with 500m total.
  assert.equal(trailMult[0].distance, 400);

  // Leading "Nx" patterns skip rule (f) entirely — existing main-loop
  // path handles them.
  const leadingNx = groups("4 x 25 strong / 25 easy");
  assert.equal(leadingNx.length, 1);
  assert.equal(leadingNx[0].reps, 4);
  assert.equal(leadingNx[0].fragments?.length ?? 0, 0);

  // Pre-existing parenthetical composite (rule d) untouched.
  const paren = groups("4 x (75 fast / 25 easy)");
  assert.equal(paren.length, 1);
  assert.equal(paren[0].fragments?.length, 2);
}

// ─── Documented-regression log (V0.52 grammar loop, 2026-09-06) ────────
// Each block documents an attempted rule + observed regression so we
// don't re-pay the same debugging cost in a future session.
//
// RULE (a) athletePrefix /^([A-Z]{2,5}):\s/i on extractLabel:
//   Attempted: prepend prefix-stripping that turns "SP: 25 race speed + easy"
//              into label="SP", rest="25 race speed + easy".
//   Regressed: real-input-7.txt line 35
//                "* Evens: First 50 aerobic, Flip/open turn, Underwater to
//                 15 m, Last 50 strong aerobic"
//              The "Evens:" prefix matched the regex and overrode
//              extractLabel's normal split, dropping the "Flip" 50 set
//              from the actual parse (15/16 vs 16/16 baseline).
//   Verdict:   REVERTED. The regex needs a real athlete-keyword whitelist
//              or a contextual anchor (e.g. must NOT be preceded by "*"
//              /indented bullet, must be a standalone line).
//   Re-survey commit-jodie-05-aug.txt for safer targets: lines 119/121/123/125
//   (SP:/MD:/IM:/SURF:) — the standalone ones are unambiguous because they
//   are flush-left with no leading punctuation.

console.log("commit grammar tests passed");
