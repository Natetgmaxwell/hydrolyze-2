import { parseWorkoutV2 } from "../lib/workout-parser-v2";

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
console.log(JSON.stringify(result, null, 2));
