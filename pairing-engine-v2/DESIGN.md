# Pairing Engine v2 — Design

## The problem

Coach has 4 swimmers in a set. Coach taps LAP 4 times. Each tap is a raw time.
We need to figure out which swimmer swam which time.

## The coach's mental model

A coach watching a set has a rough idea of what range each swimmer swims in.
They don't need precision — they just need to sort 4 times into 4 swimmers.
If they're uncertain about a pair (two swimmers are close in speed),
they flag it for manual check.

The ML engine's job is to replicate this: sort times into swimmers, flag ambiguity.

## Design principles

1. **No confidence scores** — just a ranked list. The coach decides, not the engine.
2. **Z-score is the signal** — `z = |lap - expected| / stddev`. Lower z = closer to expected.
3. **Simple is correct** — no regime switching, no outlier bonuses, no fancy math.
4. **Data quality determines stddev** — real recorded data has real stddev. No data means large stddev (conservative, low priority).
5. **Gear and intensity affect expected time** — paddles make swimmers slower. Race effort is faster than moderate.

## What we need to predict

For each swimmer in the pool, given the set context:
- **Expected time** (mean) — what we think this swimmer swims this distance/stroke/intensity/gear
- **Stddev** — how much this swimmer varies (real data = real stddev; no data = large conservative)

Then for each lap:
- Compute z-score for every swimmer
- Sort swimmers by z-score
- Return ranked list — coach uses it to assign

## Data sources (priority)

### Layer 1: Recorded stats
From `swimmer_stats` table: real historical training times.
Has real `mean_time_ms` and `stddev_time_ms`.
Key: `${swimmer_id}:${stroke}:${distance}:${intensity}:${gear ?? 'bare'}`

### Layer 2: Personal bests (speed curve)
From `swimmer_pbs` table: PB at specific distances.
Fit a power-law curve. Predict expected time at set distance.
Has estimated stddev based on distance (not real data).

### Layer 3: Population average
Universal cold start. Not used for ranking — just gives a ballpark.
Has very large stddev (low priority in sorting).

## The z-score ranking

```
For each swimmer in pool:
  expected_time = prediction_from_layer(swimmer, context)
  stddev = stddev_from_prediction
  z = |lap_time - expected_time| / stddev

Sort pool by z ascending (lowest = closest to expected = most likely)
Return ranked list with z-scores

Coach sees: "Sorted by likelihood. Swimmer A: z=0.3, Swimmer B: z=2.1..."
```

## When two swimmers are close

Coach sees both swimmers have low z-scores (e.g., z=0.4 vs z=0.6).
Both are plausible. Engine flags the gap — "ambiguous pair, 1.5× closer."
Coach resolves manually.

No confidence percentage. No fuzzy math. Just z-score ranking with a margin flag.

## Gear handling

- Paddles → swimmer is slower → expected time increases
- Fins → swimmer is faster → expected time decreases
- No gear → no adjustment

Universal gear adjustments (cold start):
- `paddles: 1.05×` (5% slower)
- `fins: 0.88×` (12% faster)
- `kickboard: 1.04×`
- `pull_buoy: 1.03×`

Per-swimmer adjustments override universal when data exists.

## Intensity handling

- `race`: expected time × 1.00 (race pace)
- `hard`: expected time × 1.03 (3% slower)
- `moderate`: expected time × 1.10 (10% slower)
- `easy`: expected time × 1.25 (25% slower)

These multipliers apply to the **race-pace baseline** (from PB or population average).
If we have recorded training data at this intensity, the multiplier is already baked in — don't double-apply.

## What gets returned

```typescript
interface SwimmerRank {
  swimmerId: string
  expectedTimeMs: number
  stddevMs: number
  zScore: number
  dataSource: 'recorded' | 'curve' | 'seed'  // where the prediction came from
}

interface SetContext {
  distance: number      // metres
  stroke: Stroke         // Free, Back, etc.
  intensity: IntensityLevel
  gear: GearType | null
  lapTimes: number[]    // raw tap times (ms), one per swimmer
}

// For each lap time, return ranked swimmers
function rankLap(
  lapTimeMs: number,
  pool: Swimmer[],
  context: SetContext,
  statsStore: StatsStore,
  pbStore: PBStore,
): SwimmerRank[]
```

## Summary

Simple: z-score ranking. No confidence. No bins. Just sort by likelihood.
Coach gets the ranked list, sees ambiguity when gap is small, decides manually.

Build:
1. Prediction pipeline (layer 1 → 2 → 3)
2. Z-score calculator
3. Ranker (sort by z)
4. CLI for testing