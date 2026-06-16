# Pairing Engine — Design Specification

**Status:** Draft
**Date:** 2026-04-26
**Purpose:** Rework the swim time prediction and pairing engine as an isolated, testable
script, before integrating into Hydrolyze.

---

## 1. Problem Statement

Current engine problems (from production observation):

| Symptom | Root Cause |
|---|---|
| Jake 38.4s → 55% confidence | `confidenceFromZ` had a hard ceiling at 55% for z≥2.0. Extreme outliers are identifiable, not uncertain — the formula was wrong. |
| Sofia 32.9s → 41% | Margin factor wasn't applied. Runner-up z was being compared against winner z but marginFactor was 1.0 when runnerUpZ ≤ bestZ (equal z). |
| Confidence jumps without clear reason | No systematic theory — confidence was ad-hoc bucket assignment. |
| New swimmers always 0% | No warm-start from speed curve or gear-adjusted PBs. |
| Gear penalties are universal | Real swimmers have individual responses to gear. |

---

## 2. Design Principles

### 2.1 — Probabilistic foundation over heuristics

Confidence should reflect **probability the assignment is correct**, not an arbitrary scale.
The framework: given a swimmer's historical distribution (mean μ, std σ) and a lap time x,
what is P(swimmer swam x)?

For a normal distribution: P(x) ∝ exp(-0.5 * ((x-μ)/σ)²)

This naturally gives us:
- z < 0.5 → very high probability → high confidence
- z large → low probability → low confidence
- BUT: z very large (extreme outlier) → the time is distinctive → confidence rises again

The final confidence should reflect two competing signals:
1. **Positional** — how close is x to μ compared to the std? (position in distribution)
2. **Distinctiveness** — how unlikely is x for ANY swimmer in the pool? (pool-wide)

### 2.2 — Three-layer prediction pipeline

```
Layer 1: Recorded Stats (swimmer_stats table)
  → Best quality. Mean and std computed from actual training times.
  → Cap: 95% (unlimited when real data exists)

Layer 2: Speed Curve (swimmer_pbs table)
  → Secondary. Power-law fit through PBs.
  → Used when no recorded stats for this stroke/distance/gear combination.
  → Cap: 70% (estimated data)

Layer 3: Universal Seed (domain knowledge)
  → Cold start. Population averages by age group / stroke / distance.
  → Used when no Layer 1 or Layer 2 data exists.
  → Cap: 55% (minimal information)
```

### 2.3 — Gear: per-swimmer calibration, not universal

Universal gear penalties are a placeholder. In production:
- Some swimmers are MORE affected by paddles than others
- Some swimmers don't use paddles at all

The engine should:
1. Accept per-swimmer gear adjustment factors
2. Fall back to universal seed values when no per-swimmer data exists
3. Store computed gear penalty in output so caller knows what was used

### 2.4 — Distance-aware stddev

Training variance (stddev) varies by distance:
- 25m sprints: σ ≈ 2-4% of mean (tight, repeatable)
- 100m: σ ≈ 5-8% of mean
- 400m+: σ ≈ 10-15% of mean

The current "10% of mean" fallback is too large for sprints, too small for distance.
Engine should accept computed stddev from stats, or fall back to a smarter default
that scales by distance.

---

## 3. Algorithm

### 3.1 — Input

```typescript
interface LapEvent {
  timeMs: number          // raw tap time (or wave-corrected)
  setDistance: number     // metres
  stroke: Stroke
  intensity: IntensityLevel
  gear: GearType | null
}

interface SwimmerCandidate {
  id: string
  name: string
  formStroke: Stroke | null   // for "Form" resolution
}

interface SwimmerPrediction {
  statsType: 'recorded' | 'curve' | 'seed' | 'no_data'
  meanTimeMs: number            // effective mean for this prediction
  stddevMs: number              // stddev
  sampleCount: number           // n for recorded; projected for curve/seed
  source: string                // human-readable: 'swimmer_stats 50m Free w/ paddles'
  gearPenalty: number           // what was applied: 1.0 means no adjustment
  curveFit: SpeedCurve | null   // present if statsType === 'curve'
  confidenceCeiling: number     // 95 (recorded), 70 (curve), 55 (seed), 0 (no_data)
}
```

### 3.2 — Prediction pipeline

For each swimmer in candidatePool:

1. **Try exact 5-way match:** (swimmerId, stroke, distance, intensity, gear)
2. **Fall back 4-way:** (swimmerId, stroke, distance, intensity, null)
3. **Fall back 3-way:** (swimmerId, stroke, distance) — use speed curve at that distance
4. **Fall back 2-way:** (swimmerId, stroke) — extrapolate from speed curve
5. **Fall back 1-way:** (swimmerId) — use universal seed with no swimmer context
6. **No data:** return no_data

### 3.3 — Confidence scoring

For each swimmer, compute:
- **zScore** = |lapTime - effectiveMean| / stddev
- **poolDistinctiveness** = ratio of runner-up z to winner z

Then compute final confidence:

```typescript
function scoreConfidence(zScore: number, poolDistinctiveness: number, ceiling: number): number {
  // Base: Gaussian probability scaled to confidence percentage
  // P(x) ∝ exp(-0.5 * z²). Normalize so z=0.5 → 95%.

  const positional = Math.exp(-0.5 * zScore * zScore) * 100

  // Distinctiveness: if every swimmer gets a similar z, confidence drops
  // marginFactor ∈ [0, 1]. 1.0 = winner is far ahead; 0.0 = tied.
  const marginFactor = Math.max(0, (poolDistinctiveness - 1.0) / 1.5)

  // Distinctive times (very high z for the pool) get a bonus
  const maxZInPool = /* computed from all swimmers */ 
  const outlierBonus = maxZInPool > 3.0 ? 10 : 0  // extreme times are identifiable

  const raw = positional * (0.5 + 0.5 * marginFactor) + outlierBonus
  return Math.round(Math.min(ceiling, Math.max(0, raw)))
}
```

**Key insight:** The confidence is a continuous function of z and margin — no ad-hoc bucket
boundaries. z=0.5 always → ~95%, z=1.0 → ~61%, z=2.0 → ~13%, etc.

### 3.4 — Outcome types

```typescript
interface AssignmentResult {
  swimmerId: string | null
  confidence: number           // 0–100 continuous
  statsType: SwimmerPrediction['statsType']
  zScore: number
  poolDistinctiveness: number  // runnerUpZ / winnerZ
  diagnostic: {
    meanMs: number
    stddevMs: number
    lapMs: number
    gearPenalty: number
    source: string
    poolSizes: { swimmerId: string, zScore: number }[]
  }
}
```

---

## 4. Gear Model

### 4.1 — Per-swimmer gear adjustments

```typescript
interface GearCalibration {
  swimmerId: string
  gear: GearType
  adjustmentFactor: number  // multiplier: e.g. 1.08 means 8% slower with this gear
  sampleCount: number       // n used to compute the adjustment
  computedAt: Date
}
```

**How to compute adjustment:** For each swimmer with ≥10 recorded times with gear X
and ≥10 without, compute: `mean(with_gear) / mean(bare_hand)`. This is their personal
adjustment factor.

**Fallback:** When no per-swimmer calibration exists, use universal seed:

```typescript
const UNIVERSAL_GEAR_ADJUSTMENT: Record<GearType, number> = {
  paddles:    1.05,   // 5% slower
  pull_buoy:  1.03,
  fins:       0.88,   // FASTER with fins (reduced drag)
  kickboard:  1.04,
  dragSuit:  1.10,
}
```

**Direction matters:** Fins make swimmers FASTER (lower time = higher speed).
Paddles make them SLOWER (higher time = lower speed).
The penalty factor moves the effective mean in the correct direction.

---

## 5. Distance-aware stddev

### 5.1 — Universal stddev fallback by distance

When stddev is unknown (cold start or speed curve):

```typescript
const STDDEV_BY_DISTANCE: Record<string, number> = {
  '25':   0.03,   // 3% of mean
  '50':   0.05,   // 5%
  '100':  0.06,   // 6%
  '200':  0.08,   // 8%
  '400':  0.10,   // 10%
  '800':  0.12,   // 12%
  '1500': 0.15,   // 15%
  default: 0.10,  // 10%
}
```

stddev = stddevFraction * meanTime

---

## 6. Output formats

### 6.1 — Structured result (for app integration)

```typescript
interface PairingResult {
  winner: AssignmentResult
  allCandidates: AssignmentResult[]   // sorted by confidence descending
  poolSize: number
  unassignable: string[]               // swimmerIds with no stats at all
  diagnostic: {
    poolDistinctiveness: number
    winnerMargin: number              // z of runner-up
    allZs: { swimmerId: string; zScore: number }[]
  }
}
```

### 6.2 — CLI output (for testing)

```
pairing-engine $ node src/pair.js --pool jake,sofia,marcus,ryan,lily,emma \
  --lap 38400 --stroke Free --distance 50 --intensity moderate

Pool size: 6 swimmers
Lap time:  38.4s
Stroke:    Free / 50m / moderate

Winner:    Jake (id: 00002)
Confidence: 82%
z-score:    35.3
Source:    recorded: swimmer_stats(50m Free, n=12, σ=300ms)
Gear:      none (1.0×)
Margin:    1.21× over runner-up (Marcus, z=29.1)

Full pool:
  Jake     z=35.3  conf=82%  [recorded]
  Sofia    z=29.3  conf=79%  [recorded]
  Marcus   z=29.1  conf=79%  [recorded]
  Ryan     z=43.3  conf=75%  [recorded]
  Lily     z=18.7  conf=73%  [recorded]
  Emma     z=22.7  conf=72%  [recorded]
```

---

## 7. File Structure

```
pairing-engine/
  src/
    types.ts              # All TypeScript interfaces
    constants.ts          # Gear penalties, stddev by distance, confidence caps
    speed-curve.ts        # Power-law curve fitting (from hydrolyze-mobile)
    prediction.ts         # Layer 1/2/3 prediction pipeline
    confidence.ts         # Confidence scoring function
    pair.ts               # Main pairing function — combine prediction + confidence
    cli.ts                # CLI interface
  __tests__/
    prediction.test.ts     # Layer 1/2/3 prediction tests
    confidence.test.ts     # Confidence scoring tests
    pair.test.ts          # End-to-end pairing tests
    fixtures/             # Real and synthetic test data
  scripts/
    run-pairing.ts        # Dev convenience script
  package.json
  tsconfig.json
  README.md
```

---

## 8. Verification Plan

### 8.1 — Unit tests (automated)

All scenarios from production plus new edge cases:

| Test | Input | Expected |
|---|---|---|
| Exact match recorded stats | Jake's 38.4s, pool with real stats | Jake at highest confidence |
| Extreme outlier identifiable | z=35.3 → confidence should be HIGH, not low | 75-85% |
| Genuine close race | Two swimmers with similar means | Lower confidence with margin factor |
| PB curve prediction | Swimmer with no recorded stats, has PBs | curve-based with 70% cap |
| Gear adjustment direction | Fins (0.88×) makes effectiveMean LOWER | effectiveMean < recordedMean |
| No data swimmer | Swimmer with no stats | 0% confidence, unassignable |
| Form stroke resolution | Stroke="Form", swimmer form_stroke="Back" | Uses Back stats |
| IM always manual | Stroke="IM" | null result |
| Empty pool | pool=[] | null result |

### 8.2 — Integration tests (manual, with real Supabase data)

```bash
# Pull real swimmer data from Supabase and run the engine
node scripts/run-pairing.ts \
  --swimmers jake,sofia,marcus,ryan,lily,emma \
  --workout-id <recent-workout-id>
```

### 8.3 — Backtest against historical times

For every recorded time in the DB that has a known swimmerId:
1. Remove that swimmer's times for that date
2. Run the engine with all other swimmers in the pool
3. Check if the correct swimmer was assigned
4. Report accuracy %

This validates the algorithm against real-world data before production use.