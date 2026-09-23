import { parseWorkoutV2 } from "./engine";
import * as fs from "node:fs";

for (const file of fs.readdirSync(".").filter((name) => name.startsWith("commit-jodie-")).sort()) {
  const text = fs.readFileSync(file, "utf8");
  const parsed = parseWorkoutV2(text);
  console.log(`### ${file}`);
  for (const section of parsed.sections) {
    for (const namedSet of section.namedSets) {
      for (const group of namedSet.repGroups) {
        if (/15 m|25 strong|50 drill|race speed|through|1:22|build|MAX|pursuit|surge|scull|rhythm|broken 100|Warm-up|Threshold volume|LC Finishing|Swim-down|Full acceleration|Second swimmer|last 15|First 35|final 15/i.test(group.sourceLine)) {
          console.log(JSON.stringify({sourceLine: group.sourceLine, reps: group.reps, distance: group.distance, interval: group.interval, stroke: group.stroke, note: group.note, fragments: group.fragments?.length ?? 0, pattern: group.pattern.length}));
        }
      }
    }
  }
}
