import { parseWorkoutV2 } from "./engine";

const cases = [
  "50 drill / 50 build ( single arm Fingers on shoulder) (catch pause drill)",
  "15 m fast breakout + settle",
  "15 m MAX + 35 m very easy",
  "SP: 25 race speed + easy",
  "2 x through\n800 progressive aerobic",
  "4 x 50 @ 1:00\n1:22",
  "25 scull + 25 swim — connect catch to stroke",
  "#2 — 15 m fast breakout + settle",
  "25 strong / 25 easy",
];
for (const input of cases) {
  const parsed = parseWorkoutV2(input);
  console.log(JSON.stringify({ input, groups: parsed.sections.flatMap((s) => s.namedSets.flatMap((n) => n.repGroups)) }, null, 2));
}
