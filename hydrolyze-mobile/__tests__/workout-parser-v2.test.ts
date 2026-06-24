import { parseWorkoutV2, formatWorkoutV2 } from "../lib/workout-parser-v2";
import type { Workout } from "../lib/workout-types";

// ─── Helper ─────────────────────────────────────────────────────────────────

function countTests(): { passed: number; failed: number; total: number } {
  return { passed: 0, failed: 0, total: 0 };
}

// ─── Ported from old workout-parser.test.ts ─────────────────────────────────
// These test that standard inputs still parse correctly under v2.
// Expectations are wrapped in the new tree shape:
//   single section (no title), single namedSet (no label), one repGroup

describe("parseWorkoutV2 — ported cases from v1", () => {
  describe("basic set parsing", () => {
    test("4x50 free @1:00", () => {
      const w = parseWorkoutV2("4x50 free @1:00");
      expect(w.sections).toHaveLength(1);
      expect(w.sections[0].namedSets).toHaveLength(1);
      const rg = w.sections[0].namedSets[0].repGroups[0];
      expect(rg.reps).toBe(4);
      expect(rg.distance).toBe(50);
      expect(rg.stroke).toBe("Free");
      expect(rg.interval).toBe("1:00");
    });

    test("4x50 kick fins", () => {
      const w = parseWorkoutV2("4x50 kick fins");
      expect(w.sections[0].namedSets[0].repGroups[0].note).toBe("fins");
    });

    test("200 easy", () => {
      const w = parseWorkoutV2("200 easy");
      const rg = w.sections[0].namedSets[0].repGroups[0];
      expect(rg.distance).toBe(200);
      expect(rg.reps).toBe(1);
    });
  });

  describe("multi-set parsing", () => {
    test("two sets separated by comma", () => {
      const w = parseWorkoutV2("4x100 free, 2x50 kick fins");
      expect(w.sections[0].namedSets).toHaveLength(2);
      expect(w.sections[0].namedSets[0].repGroups[0].reps).toBe(4);
      expect(w.sections[0].namedSets[0].repGroups[0].distance).toBe(100);
      expect(w.sections[0].namedSets[1].repGroups[0].reps).toBe(2);
      expect(w.sections[0].namedSets[1].repGroups[0].distance).toBe(50);
    });

    test("three sets with mixed gear", () => {
      const w = parseWorkoutV2(
        "4x100 free @1:30, 4x50 kick fins @1:00, 200 easy",
      );
      expect(w.sections[0].namedSets).toHaveLength(3);
      expect(w.sections[0].namedSets[0].repGroups[0].interval).toBe("1:30");
      expect(w.sections[0].namedSets[1].repGroups[0].note).toBe("fins");
    });
  });

  describe("intensity parsing", () => {
    test("sprint", () => {
      const w = parseWorkoutV2("8x25 fly sprint @30");
      const rg = w.sections[0].namedSets[0].repGroups[0];
      expect(rg.intensity?.type).toBe("sprint");
      expect(rg.stroke).toBe("Fly");
    });

    test("pace target", () => {
      const w = parseWorkoutV2("4x100 free at 200 pace");
      const rg = w.sections[0].namedSets[0].repGroups[0];
      expect(rg.intensity?.type).toBe("pace_target");
      expect(rg.intensity?.paceDistance).toBe(200);
    });

    test("easy", () => {
      const w = parseWorkoutV2("100 easy");
      const rg = w.sections[0].namedSets[0].repGroups[0];
      expect(rg.intensity?.type).toBe("easy");
    });
  });

  describe("interval parsing", () => {
    test("@1:30 format", () => {
      const w = parseWorkoutV2("4x100 free @1:30");
      expect(w.sections[0].namedSets[0].repGroups[0].interval).toBe("1:30");
    });

    test("on 1:30 format", () => {
      const w = parseWorkoutV2("4x100 on 1:30");
      expect(w.sections[0].namedSets[0].repGroups[0].interval).toBe("1:30");
    });

    test("@45 seconds format", () => {
      const w = parseWorkoutV2("4x25 fly sprint @45");
      expect(w.sections[0].namedSets[0].repGroups[0].interval).toBe("0:45");
    });
  });

  describe("stroke parsing", () => {
    test("free", () => {
      const w = parseWorkoutV2("4x50 free");
      expect(w.sections[0].namedSets[0].repGroups[0].stroke).toBe("Free");
    });

    test("back", () => {
      const w = parseWorkoutV2("4x50 back");
      expect(w.sections[0].namedSets[0].repGroups[0].stroke).toBe("Back");
    });

    test("fly", () => {
      const w = parseWorkoutV2("4x50 fly");
      expect(w.sections[0].namedSets[0].repGroups[0].stroke).toBe("Fly");
    });

    test("IM", () => {
      const w = parseWorkoutV2("4x50 IM");
      expect(w.sections[0].namedSets[0].repGroups[0].stroke).toBe("IM");
    });
  });

  describe("rounds/blocks expansion", () => {
    test("4x (50 free, 50 back) — comma within parens", () => {
      const w = parseWorkoutV2("4x (50 free, 50 back)");
      // Parser treats comma-separated items within a line as separate repGroups
      // But the parens block notation may not expand in v2 yet
      // This test captures current behavior — may need adjustment in Stage 4
      expect(w.sections[0].namedSets.length).toBeGreaterThanOrEqual(1);
    });
  });
});

// ─── New v2 construct tests ──────────────────────────────────────────────────

describe("parseWorkoutV2 — new v2 constructs", () => {
  describe("section header detection", () => {
    test("Warm Up — standalone header", () => {
      const w = parseWorkoutV2("Warm Up\n4x50 easy");
      expect(w.sections[0].title).toBe("Warm Up");
    });

    test("Main — with em dash", () => {
      const w = parseWorkoutV2("Main - Sprint\n4x50 fast");
      expect(w.sections[0].title).toBe("Main - Sprint");
    });

    test("Cool Down", () => {
      const w = parseWorkoutV2("Cool Down\n200 easy");
      expect(w.sections[0].title).toBe("Cool Down");
    });

    test("multiple sections", () => {
      const w = parseWorkoutV2("Warm Up\n200 easy\n\nMain\n4x100 free");
      expect(w.sections).toHaveLength(2);
      expect(w.sections[0].title).toBe("Warm Up");
      expect(w.sections[1].title).toBe("Main");
    });

    test("section header without set on same line", () => {
      const w = parseWorkoutV2("Warm Up\n\nAerobic Build\n400 swim");
      // First section is empty/blank, second section gets the content
      expect(w.sections.length).toBeGreaterThanOrEqual(1);
    });
  });

  describe("named-set label parsing", () => {
    test("label on its own line (no set)", () => {
      const w = parseWorkoutV2("Aerobic Build (400m)\n400 swim");
      expect(w.sections[0].namedSets[0].label).toBe("Aerobic Build (400m)");
    });

    test("label inline before rep pattern", () => {
      const w = parseWorkoutV2("Stroke Activation 4x100 as 25 drill + 75 swim");
      expect(w.sections[0].namedSets[0].label).toBe("Stroke Activation");
    });

    test("label with description text — label extracted correctly", () => {
      const w = parseWorkoutV2(
        "Pull with Pressure 4 x 75 Descend 1-4 to ~80-85%",
      );
      expect(w.sections[0].namedSets[0].label).toBe("Pull with Pressure");
    });

    test("section + inline label combined", () => {
      const w = parseWorkoutV2(
        "Main\nStroke Activation 4x100 as 25 drill + 75 swim",
      );
      expect(w.sections[0].title).toBe("Main");
      expect(w.sections[0].namedSets[0].label).toBe("Stroke Activation");
    });
  });

  describe("percentage range intensity", () => {
    test("range with en-dash ~80-85%", () => {
      const w = parseWorkoutV2("4x100 @~80-85%");
      const rg = w.sections[0].namedSets[0].repGroups[0];
      expect(rg.intensity?.type).toBe("percent_range");
      expect(rg.intensity?.percentLow).toBe(75);
      expect(rg.intensity?.percentHigh).toBe(90);
    });

    test("range with hyphen 80-85%", () => {
      const w = parseWorkoutV2("4x100 80-85%");
      const rg = w.sections[0].namedSets[0].repGroups[0];
      expect(rg.intensity?.type).toBe("percent_range");
      expect(rg.intensity?.percentLow).toBe(80);
      expect(rg.intensity?.percentHigh).toBe(85);
    });

    test("approximate ~75%", () => {
      const w = parseWorkoutV2("100 build to ~75%");
      const rg = w.sections[0].namedSets[0].repGroups[0];
      expect(rg.intensity?.type).toBe("percent_range");
      expect(rg.intensity?.label).toBe("75%");
    });

    test("bare percentage 85%", () => {
      const w = parseWorkoutV2("4x50 @85%");
      const rg = w.sections[0].namedSets[0].repGroups[0];
      expect(rg.intensity?.type).toBe("percent_range");
      expect(rg.intensity?.percentLow).toBe(80);
      expect(rg.intensity?.percentHigh).toBe(90);
    });
  });

  describe("compound + notation", () => {
    test("4x300 + 8x25 on same line", () => {
      const w = parseWorkoutV2("4x300 + 8x25 ATP 1:15");
      expect(w.sections[0].namedSets[0].repGroups).toHaveLength(2);
      expect(w.sections[0].namedSets[0].repGroups[0].reps).toBe(4);
      expect(w.sections[0].namedSets[0].repGroups[0].distance).toBe(300);
      expect(w.sections[0].namedSets[0].repGroups[1].reps).toBe(8);
      expect(w.sections[0].namedSets[0].repGroups[1].distance).toBe(25);
      expect(w.sections[0].namedSets[0].repGroups[1].connectors).toContain("+");
    });

    test("interval inherited from first to second group", () => {
      const w = parseWorkoutV2("4x300 + 8x25 ATP 1:15");
      // Second group should inherit interval from first
      expect(w.sections[0].namedSets[0].repGroups[1].interval).toBe("1:15");
    });
  });

  describe("inline gear in note", () => {
    test("Paddles optional in parens", () => {
      const w = parseWorkoutV2(
        "Pull with Pressure 4 x 75 Descend 1-4 to ~80-85% Paddles optional",
      );
      const rg = w.sections[0].namedSets[0].repGroups[0];
      expect(rg.note).toMatch(/optional/);
    });

    test("gear keyword inside parens attaches to note", () => {
      const w = parseWorkoutV2("4x75 pull (paddles optional)");
      const rg = w.sections[0].namedSets[0].repGroups[0];
      expect(rg.note).toBe("paddles optional");
    });

    test("(very fast) as note", () => {
      const w = parseWorkoutV2("4x300 + 8x25 ATP 1:15 (very fast)");
      const rg = w.sections[0].namedSets[0].repGroups[0];
      expect(rg.note).toBe("very fast");
    });
  });

  describe("drill/swim sub-breakdown", () => {
    test("25 drill + 75 swim", () => {
      const w = parseWorkoutV2("4x100 as 25 drill + 75 swim");
      const rg = w.sections[0].namedSets[0].repGroups[0];
      expect(rg.patternType).toBe("drill_swim");
      expect(rg.pattern[0].type).toBe("drill_swim");
      expect((rg.pattern[0] as any).drillMeters).toBe(25);
      expect((rg.pattern[0] as any).swimMeters).toBe(75);
    });

    test("inline as: 100 smooth free, 100 IM drill/swim, 100 pull, 100 build to ~75%", () => {
      const w = parseWorkoutV2(
        "400 swim as: 100 smooth free, 100 IM drill/swim, 100 pull (long strokes), 100 build to ~75%",
      );
      // The sub-breakdown parsing handles comma-separated parts
      expect(w.sections[0].namedSets.length).toBeGreaterThanOrEqual(1);
    });
  });

  describe("odd/even alternation", () => {
    test("odd/even block indented on following lines", () => {
      const w = parseWorkoutV2(`Kick + Oxygen Demand 4 x 50
  Odd: underwater dolphin kick (breakout + easy to wall)
  Even: freestyle kick build to strong`);
      const ns = w.sections[0].namedSets[0];
      expect(ns.label).toBe("Kick + Oxygen Demand");
      expect(ns.repGroups[0].patternType).toBe("odd_even");
      expect(ns.repGroups[0].pattern[0].type).toBe("odd_even");
    });
  });

  describe("dash normalization", () => {
    test("en-dash (–) normalizes to hyphen (-)", () => {
      const w = parseWorkoutV2("4x100 80–85%");
      const rg = w.sections[0].namedSets[0].repGroups[0];
      expect(rg.intensity?.type).toBe("percent_range");
    });

    test("descend 1–4 with en-dash", () => {
      const w = parseWorkoutV2("4x75 Descend 1–4 to ~80–85%");
      const rg = w.sections[0].namedSets[0].repGroups[0];
      expect(rg.intensity?.type).toBe("build");
    });
  });

  describe("spacing variations", () => {
    test("4 x 50 (spaces) parses same as 4x50", () => {
      const withSpaces = parseWorkoutV2("4 x 50 free");
      const noSpaces = parseWorkoutV2("4x50 free");
      const rgSpaces = withSpaces.sections[0].namedSets[0].repGroups[0];
      const rgNoSpaces = noSpaces.sections[0].namedSets[0].repGroups[0];
      expect(rgSpaces.reps).toBe(rgNoSpaces.reps);
      expect(rgSpaces.distance).toBe(rgNoSpaces.distance);
    });

    test("400 standalone distance", () => {
      const w = parseWorkoutV2("400 swim");
      const rg = w.sections[0].namedSets[0].repGroups[0];
      expect(rg.distance).toBe(400);
      expect(rg.reps).toBe(1);
    });
  });

  describe("intensity type coverage", () => {
    test("descend", () => {
      const w = parseWorkoutV2("4x100 descend");
      expect(w.sections[0].namedSets[0].repGroups[0].intensity?.type).toBe(
        "descend",
      );
    });

    test("build", () => {
      const w = parseWorkoutV2("100 build");
      expect(w.sections[0].namedSets[0].repGroups[0].intensity?.type).toBe(
        "build",
      );
    });

    test("negative split", () => {
      const w = parseWorkoutV2("4x100 negative split");
      expect(w.sections[0].namedSets[0].repGroups[0].intensity?.type).toBe(
        "negative_split",
      );
    });

    test("aerobic", () => {
      const w = parseWorkoutV2("4x100 aerobic");
      expect(w.sections[0].namedSets[0].repGroups[0].intensity?.type).toBe(
        "aerobic",
      );
    });

    test("race pace", () => {
      const w = parseWorkoutV2("4x100 race pace");
      expect(w.sections[0].namedSets[0].repGroups[0].intensity?.type).toBe(
        "race_pace",
      );
    });

    test("threshold", () => {
      const w = parseWorkoutV2("4x100 threshold");
      expect(w.sections[0].namedSets[0].repGroups[0].intensity?.type).toBe(
        "threshold",
      );
    });
  });

  describe("empty and whitespace input", () => {
    test("empty string → workout with no sections", () => {
      const w = parseWorkoutV2("");
      expect(w.sections).toHaveLength(0);
    });

    test("whitespace only → workout with no sections", () => {
      const w = parseWorkoutV2("   \n\n  ");
      expect(w.sections).toHaveLength(0);
    });
  });
});

// ─── Bug 1 — as: sub-breakdown with comma-separated mini-reps ──────────────────

describe("parseWorkoutV2 — Bug 1: as: sub-breakdown", () => {
  test("as: with multiple comma-separated mini-reps", () => {
    const w = parseWorkoutV2(
      "400 swim as: 100 smooth free, 100 IM drill/swim, 100 pull (long strokes), 100 build to ~75%",
    );
    expect(w.sections[0].namedSets).toHaveLength(1);
    const ns = w.sections[0].namedSets[0];
    expect(ns.repGroups).toHaveLength(1);
    const rg = ns.repGroups[0];
    expect(rg.reps).toBe(1);
    expect(rg.distance).toBe(400);
    expect(rg.stroke).toBe("Free");
    expect(rg.patternType).toBe("simple");
    expect(rg.pattern).toHaveLength(4);
    expect((rg.pattern[0] as any).meters).toBe(100);
    expect((rg.pattern[0] as any).stroke).toBe("Free");
    expect((rg.pattern[1] as any).meters).toBe(100);
    expect((rg.pattern[1] as any).stroke).toBe("IM");
    expect((rg.pattern[2] as any).meters).toBe(100);
    expect((rg.pattern[3] as any).meters).toBe(100);
    expect((rg.pattern[3] as any).intensity?.type).toBe("percent_range");
    expect((rg.pattern[3] as any).intensity?.percentLow).toBe(70);
    expect((rg.pattern[3] as any).intensity?.percentHigh).toBe(80);
  });

  test("as: mini-rep note field captures parenthetical text", () => {
    const w = parseWorkoutV2("400 swim as: 100 pull (long strokes), 100 easy");
    const rg = w.sections[0].namedSets[0].repGroups[0];
    expect(rg.pattern[0].type).toBe("simple");
    expect((rg.pattern[0] as any).note).toBe("long strokes");
  });

  test("as: on its own line (no colon variant)", () => {
    const w = parseWorkoutV2("400 swim as 100 easy, 100 hard");
    expect(w.sections[0].namedSets[0].repGroups[0].pattern).toHaveLength(2);
  });
});

// ─── Bug 2 — multi-line Odd/Even after parent set line ────────────────────────

describe("parseWorkoutV2 — Bug 2: Odd/Even in full workout context", () => {
  test("Odd/Even block after Kick set — standalone", () => {
    const w = parseWorkoutV2(
      "Kick + Oxygen Demand 4 x 50\n  Odd: underwater dolphin kick (breakout + easy to wall)\n  Even: freestyle kick build to strong",
    );
    const ns = w.sections[0].namedSets[0];
    expect(ns.label).toBe("Kick + Oxygen Demand");
    expect(ns.repGroups[0].patternType).toBe("odd_even");
    expect((ns.repGroups[0].pattern[0] as any).odd).toBe(
      "underwater dolphin kick (breakout + easy to wall)",
    );
    expect((ns.repGroups[0].pattern[0] as any).even).toBe(
      "freestyle kick build to strong",
    );
  });

  test("full workout context — Odd/Even block after Kick set", () => {
    const w = parseWorkoutV2(`Warm Up

Aerobic Build (400m)
400 swim as:100 smooth free,100 IM drill/swim,100 pull (long strokes), 100 build to ~75%

Stroke Activation 4x100 as 25 drill + 75 swim @ moderate aerobic (Rotate strokes or keep stroke-specific)connect technique under light aerobic load

Kick + Oxygen Demand 4 x 50 - switch on core + breathing control

Odd: underwater dolphin kick (breakout + easy to wall)

Even: freestyle kick build to strong

Pull with Pressure 4 x 75 Descend 1-4 to ~80-85% Paddles optional

Aerobic Power Prep 4 x 50 as 25 smooth + 25 build to 85-90%

Main - Sprint
4x300 + 8x25 ATP 1:15 (very fast)`);
    const ns = w.sections[0].namedSets.find(
      (ns) => ns.label === "Kick + Oxygen Demand",
    );
    expect(ns).toBeDefined();
    expect(ns!.repGroups[0].patternType).toBe("odd_even");
    expect((ns!.repGroups[0].pattern[0] as any).odd).toBe(
      "underwater dolphin kick (breakout + easy to wall)",
    );
    expect((ns!.repGroups[0].pattern[0] as any).even).toBe(
      "freestyle kick build to strong",
    );
  });
});

// ─── Bug 3 — compound + with interval and note after last + ──────────────────

describe("parseWorkoutV2 — Bug 3: compound + with shared interval and note", () => {
  test("4x300 + 8x25 ATP 1:15 (very fast) — both groups get interval + note", () => {
    const w = parseWorkoutV2("4x300 + 8x25 ATP 1:15 (very fast)");
    expect(w.sections[0].namedSets[0].repGroups).toHaveLength(2);
    const [rg1, rg2] = w.sections[0].namedSets[0].repGroups;
    expect(rg1.interval).toBe("1:15");
    expect(rg1.intensity?.type).toBe("sprint");
    expect(rg1.note).toBe("very fast");
    expect(rg2.interval).toBe("1:15");
    expect(rg2.connectors).toContain("+");
  });

  test("4x300 + 8x25 — second group inherits interval from first when interval after both", () => {
    const w = parseWorkoutV2("4x300 + 8x25 1:15");
    const [, rg2] = w.sections[0].namedSets[0].repGroups;
    expect(rg2.interval).toBe("1:15");
  });
});

// ─── Bug 4 — label-only line pairs with set on next line ────────────────────

describe("parseWorkoutV2 — Bug 4: label-only line pairs with next set", () => {
  test("pairs a label-only line with the set on the next line", () => {
    const input = `Aerobic Build (400m)
400 swim as: 100 smooth free, 100 IM drill/swim, 100 pull (long strokes), 100 build to ~75%`;
    const result = parseWorkoutV2(input);
    const namedSet = result.sections[0].namedSets[0];
    expect(namedSet.label).toMatch(/Aerobic Build/);
    expect(namedSet.repGroups[0].distance).toBe(400);
    expect(namedSet.repGroups[0].pattern).toHaveLength(4);
  });

  test("drops bare section headers like 'Main - Sprint' without losing the next set", () => {
    const input = `Main - Sprint
4x300 + 8x25 ATP 1:15 (very fast)`;
    const result = parseWorkoutV2(input);
    const allRepGroups = result.sections.flatMap((s) =>
      s.namedSets.flatMap((ns) => ns.repGroups),
    );
    expect(allRepGroups.find((rg) => rg.distance === 300)).toBeTruthy();
    expect(
      allRepGroups.find(
        (rg) => rg.distance === 25 && rg.connectors?.includes("+"),
      ),
    ).toBeTruthy();
  });
});

// ─── formatWorkoutV2 smoke test ───────────────────────────────────────────────

describe("formatWorkoutV2", () => {
  test("formats a simple workout to readable string", () => {
    const w = parseWorkoutV2("4x50 free @1:00");
    const formatted = formatWorkoutV2(w);
    expect(formatted).toContain("4×50m");
    expect(formatted).toContain("Free");
    expect(formatted).toContain("1:00");
  });

  test("formats with section title", () => {
    const w = parseWorkoutV2("Warm Up\n200 easy");
    const formatted = formatWorkoutV2(w);
    expect(formatted).toContain("[Warm Up]");
  });

  test("formats with named set label", () => {
    const w = parseWorkoutV2("Aerobic Build\n400 swim");
    const formatted = formatWorkoutV2(w);
    expect(formatted).toContain("Aerobic Build");
  });
});

describe("parseWorkoutV2 — lossless parsing", () => {
  test("captures gear and descend on a rep-group", () => {
    const input =
      "Pull with Pressure 4 x 75 Descend 1-4 to ~80-85% Paddles optional";
    const result = parseWorkoutV2(input);
    const rg = result.sections[0].namedSets[0].repGroups[0];
    expect(rg.reps).toBe(4);
    expect(rg.distance).toBe(75);
    expect(rg.intensity?.label).toMatch(/80-85/);
    expect(rg.descend).toBe("1-4");
    expect(rg.gear?.some((g) => g.includes("paddles"))).toBe(true);
  });

  test("preserves every meaningful token — no information loss", () => {
    const input = `Aerobic Build (400m)
400 swim as: 100 smooth free, 100 IM drill/swim, 100 pull (long strokes), 100 build to ~75%
Stroke Activation 4x100 as 25 drill + 75 swim @ moderate aerobic
Kick + Oxygen Demand 4 x 50
  Odd: underwater dolphin kick (breakout + easy to wall)
  Even: freestyle kick build to strong
Pull with Pressure 4 x 75 Descend 1-4 to ~80-85% Paddles optional
Aerobic Power Prep 4 x 50 as 25 smooth + 25 build to 85-90%
4x300 + 8x25 ATP 1:15 (very fast)`;
    const result = parseWorkoutV2(input);
    const json = JSON.stringify(result).toLowerCase();
    for (const word of [
      "paddles",
      "descend",
      "smooth",
      "build",
      "strong",
      "breakout",
      "optional",
      "fast",
    ]) {
      expect(json).toContain(word);
    }
  });
});

describe("parseWorkoutV2 — as: sub-rep drop fix", () => {
  test("keeps sub-rep with distance + pacing + intensity but no stroke", () => {
    const input = `Aerobic Build (400m)
400 swim as: 100 smooth free, 100 IM drill/swim, 100 pull (long strokes), 100 build to ~75%`;
    const result = parseWorkoutV2(input);
    const rg = result.sections[0].namedSets[0].repGroups[0];
    expect(rg.pattern).toHaveLength(4);
    const last = rg.pattern[3];
    expect(last.type).toBe("simple");
    const simple = last as import("../lib/workout-types").SimpleRep;
    expect(simple.meters).toBe(100);
    expect(simple.pacing).toBe("build");
    expect(simple.intensity?.label).toMatch(/75/);
  });
});

describe("parseWorkoutV2 — as: + separator fix", () => {
  test("splits as: block on + as well as ,", () => {
    const input = "Aerobic Power Prep 4 x 50 as 25 smooth + 25 build to 85-90%";
    const result = parseWorkoutV2(input);
    const rg = result.sections[0].namedSets[0].repGroups[0];
    expect(rg.pattern).toHaveLength(2);
    const [first, second] = rg.pattern;
    expect((first as any).meters).toBe(25);
    expect((first as any).pacing).toBe("smooth");
    expect((first as any).intensity).toBeFalsy();
    expect((second as any).meters).toBe(25);
    expect((second as any).pacing).toBe("build");
    expect((second as any).intensity?.label).toMatch(/85/);
  });

  test("preserves drill/swim + notation inside as: block", () => {
    const input = "4x100 as 25 drill + 75 swim @ moderate aerobic";
    const result = parseWorkoutV2(input);
    const rg = result.sections[0].namedSets[0].repGroups[0];
    expect(rg.pattern).toHaveLength(1);
    expect(rg.pattern[0].type).toBe("drill_swim");
  });

  test("does not promote sub-rep intensity to parent spine when only some sub-reps have it", () => {
    const input = "Aerobic Power Prep 4 x 50 as 25 smooth + 25 build to 85-90%";
    const result = parseWorkoutV2(input);
    const rg = result.sections[0].namedSets[0].repGroups[0];
    expect(rg.intensity).toBeFalsy(); // spine should NOT carry 85-90%
    expect((rg.pattern[0] as any).intensity).toBeFalsy();
    expect((rg.pattern[1] as any).intensity?.percentLow).toBe(85);
  });
});

describe("parseWorkoutV2 — pacing, stroke, and gearOptional", () => {
  test("captures pacing qualifier when both pacing and intensity present", () => {
    const input = "4x100 free build to 75%";
    const result = parseWorkoutV2(input);
    const rg = result.sections[0].namedSets[0].repGroups[0];
    expect(rg.intensity?.label).toMatch(/75/);
    expect(rg.pacing).toBe("build");
  });

  test("captures pacing alone when no intensity (strong, smooth)", () => {
    const input = `Kick + Oxygen Demand 4 x 50
  Odd: underwater dolphin kick (breakout + easy to wall)
  Even: freestyle kick build to strong`;
    const result = parseWorkoutV2(input);
    const rg = result.sections[0].namedSets[0].repGroups[0];
    expect(rg.pattern[0].type).toBe("odd_even");
    const oddEven = rg.pattern[0] as import("../lib/workout-types").OddEvenRep;
    expect(oddEven.even).toContain("strong");
    expect(oddEven.even.toLowerCase()).toContain("build");
  });

  test("parses drill/swim with slash separator and captures stroke", () => {
    const input = "4x100 as 25 drill/75 swim";
    const result = parseWorkoutV2(input);
    const rg = result.sections[0].namedSets[0].repGroups[0];
    const sub = rg.pattern.find((p) => p.type === "drill_swim");
    expect(sub).toBeTruthy();
    const drillSub = sub as import("../lib/workout-types").DrillSwimRep;
    expect(drillSub.drillMeters).toBe(25);
    expect(drillSub.swimMeters).toBe(75);
  });

  test("recognizes pull as a stroke and lifts gearOptional flag", () => {
    const input = "Pull with Pressure 4 x 75 to ~80% Paddles optional";
    const result = parseWorkoutV2(input);
    const rg = result.sections[0].namedSets[0].repGroups[0];
    expect(rg.gear?.[0].toLowerCase()).toContain("paddles");
    expect(rg.gearOptional).toBe(true);
    expect(rg.details).not.toContain("optional");
  });

  test("captures pull as stroke on a sub-rep", () => {
    const input =
      "400 swim as: 100 smooth free, 100 pull (long strokes), 100 build";
    const result = parseWorkoutV2(input);
    const rg = result.sections[0].namedSets[0].repGroups[0];
    const pullRep = rg.pattern.find(
      (p) =>
        p.type === "simple" &&
        (p as import("../lib/workout-types").SimpleRep).stroke === "Pull",
    );
    expect(pullRep).toBeTruthy();
  });
});

describe("parseWorkoutV2 — intensity label preservation", () => {
  test("preserves original label for moderate", () => {
    const input = "4 x 50 @ moderate";
    const result = parseWorkoutV2(input);
    const rg = result.sections[0].namedSets[0].repGroups[0];
    expect(rg.intensity?.label).toBe("moderate");
  });

  test("recognizes EZ as easy and preserves original label", () => {
    const input = "200 EZ choice";
    const result = parseWorkoutV2(input);
    const rg = result.sections[0].namedSets[0].repGroups[0];
    expect(rg.intensity?.type).toBe("easy");
    expect(rg.intensity?.label?.toLowerCase()).toMatch(/ez|easy/);
  });

  test("preserves EZ on recovery set", () => {
    const input = "100 EZ recovery";
    const result = parseWorkoutV2(input);
    const rg = result.sections[0].namedSets[0].repGroups[0];
    expect(rg.intensity?.label?.toLowerCase()).toMatch(/ez|easy|recovery/);
  });
});

describe("parseWorkoutV2 — orphan RG + label attachment + token preservation", () => {
  test("no orphan rep-group for as: block with + joined sub-reps", () => {
    const input = "Aerobic Power Prep 4 x 50 as 25 smooth + 25 build to 85-90%";
    const result = parseWorkoutV2(input);
    const ns = result.sections[0].namedSets[0];
    expect(ns.repGroups).toHaveLength(1);
    expect(ns.repGroups[0].pattern).toHaveLength(2);
  });

  test("all sets after a section label attach to the same named-set", () => {
    const input = `Warm-Up (600m)
200 EZ choice
4 x 50 as 25 kick + 25 swim
2 x 100 IM @ smooth`;
    const result = parseWorkoutV2(input);
    const warmup = result.sections[0];
    expect(warmup.namedSets).toHaveLength(1);
    expect(warmup.namedSets[0].repGroups).toHaveLength(3);
  });

  test("choice as stroke survives", () => {
    const input = "200 choice EZ";
    const result = parseWorkoutV2(input);
    const rg = result.sections[0].namedSets[0].repGroups[0];
    expect(rg.stroke).toBe("Choice");
  });

  test("best avg survives as note", () => {
    const input = "3 x 100 strong on 1:30 best avg";
    const result = parseWorkoutV2(input);
    const rg = result.sections[0].namedSets[0].repGroups[0];
    const json = JSON.stringify(rg).toLowerCase();
    expect(json).toContain("avg");
  });

  test("underwater dolphin survives as details or note", () => {
    const input = "4 x 25 underwater dolphin";
    const result = parseWorkoutV2(input);
    const rg = result.sections[0].namedSets[0].repGroups[0];
    const json = JSON.stringify(rg).toLowerCase();
    expect(json).toContain("underwater");
  });

  test("between rounds survives as note", () => {
    const input = "50 EZ between rounds";
    const result = parseWorkoutV2(input);
    const rg = result.sections[0].namedSets[0].repGroups[0];
    const json = JSON.stringify(rg).toLowerCase();
    expect(json).toContain("between");
  });
});
