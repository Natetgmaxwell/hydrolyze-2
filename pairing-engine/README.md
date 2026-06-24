# Pairing Engine

**Standalone swim time prediction and pairing engine for Hydrolyze.**

Independent from the app — runs as a Node.js script with a full CLI and test suite.

---

## Quick start

```bash
npm install
npm test          # run all 69 tests
npx tsx src/cli.ts --pool=jake,sofia --lap=38400 --stroke=Free --distance=50 --intensity=moderate
```

---

## What it does

Given a **lap time** and a **pool of swimmers**, it assigns the lap to the most likely swimmer and scores its confidence.

```
Pairing Engine — CLI
────────────────────────────────────────────────────────────
Pool size:    2 swimmers
Lap time:     38.40s
Stroke:       Free / 50m / moderate

Result:
  Winner:          00000000-0000-0000-0000-000000000003 (confidence: 88%)
  Stats type:      recorded
  z-score:          29.29
  Distinctiveness: 1.21× over runner-up

Full pool ranking:
  Sofia  z= 29.29  conf= 88%  [REC  ]  mean= 30.20s  σ=  280ms  gear=1×
  Jake   z= 35.33  conf= 95%  [REC  ]  mean= 27.80s  σ=  300ms  gear=1×
```

---

## Architecture

```
src/
  types.ts         # All interfaces
  constants.ts     # Gear penalties, stddev fractions, confidence ceilings
  speed-curve.ts   # Power-law PB curve fitting
  prediction.ts    # Layer 1/2/3 prediction pipeline
  confidence.ts    # Continuous confidence scoring
  pair.ts          # Main pairing function
  cli.ts           # CLI interface
__tests__/
  confidence.test.ts  # Confidence scoring unit tests
  prediction.test.ts   # Prediction pipeline unit tests
  pair.test.ts         # End-to-end pairing tests
```

### Prediction layers (priority order)

| Layer | Source | Confidence ceiling | Use when |
|---|---|---|---|
| 1 | `swimmer_stats` table (recorded) | 95% | Swimmer has real training data for this stroke/distance/intensity/gear |
| 2 | Speed curve from `swimmer_pbs` table | 70% | No recorded stats, but has PBs |
| 3 | Universal population seed | 55% | No data at all — cold start |

### Confidence scoring

Two regimes:

**Normal (z ≤ 5):**  
`confidence = positional(z) × (0.5 + 0.5 × marginFactor) + outlierBonus`  
where `positional(z) = exp(-0.5 × z²) × 100`

**Extreme (z > 5):**  
`confidence = ((z - 5) / 30) × 90 + outlierBonus`  
Extreme times are distinctive, not uncertain — gets identifiable confidence.

`marginFactor` = how much better the winner is than the runner-up.  
`outlierBonus` = +10 if pool has any z > 3, +15 if any z > 5.

---

## Key design decisions

### Why extreme z-scores get HIGH confidence

A time that's 35 standard deviations from a swimmer's mean is **identifiable** — nobody else in the pool swims that time. The Gaussian positional score drops to near-zero, but the distinctive signal rescues it.

### Why z=0 doesn't return 100%

The function returns `ceiling` for z=0 — the cap is always respected. This keeps the output deterministic and consistent regardless of whether the ceiling is 95 (recorded) or 55 (seed).

### Why outlier bonus applies in both regimes

The outlier bonus (+10 or +15) reflects how distinctive the time is for the **pool**, not just the winner. Even when the winner is in extreme regime, if other swimmers are also extreme, the bonus still applies.

### Why marginFactor is 0 when tied or runner-up is worse

`(runnerUpZ / winnerZ - 1) / 1.5` → 0 when `runnerUpZ ≤ winnerZ`. A tie gets no margin boost. This prevents artificially inflated confidence when swimmers are genuinely indistinguishable.

---

## Testing

```bash
npm test           # vitest run — all 69 tests
npm run test:watch # vitest --watch for TDD
npm run typecheck  # tsc --noEmit
```

---

## Integration with Hydrolyze

When integrating into Hydrolyze, replace the old `lib/ml-pairing.ts` with a thin adapter:

```typescript
// hydrolyze-mobile/lib/ml-pairing.ts
import { StatsStore, PBStore, predictPool } from 'pairing-engine/src/prediction'
import { pairLap } from 'pairing-engine/src/pair'

export function pairTime(lapTimeMs, pool, cache, stroke, intensity, distance, gear) {
  // Populate StatsStore and PBStore from cache
  const statsStore = new StatsStore()
  const pbStore = new PBStore()
  for (const [key, stats] of Object.entries(cache)) {
    const [swimmerId, stroke, distance, intensity, gear] = key.split(':')
    statsStore.set(swimmerId, stroke as any, +distance, intensity as any, gear as any === 'none' ? null : gear as any, stats)
  }
  
  const result = pairLap({ timeMs, setDistance: distance, stroke, intensity, gear }, { swimmers: pool, statsStore, pbStore })
  
  return { swimmerId: result.winnerId, confidence: result.confidence, source: result.statsType }
}
```

---

## Planned improvements (for integration)

- [ ] Per-swimmer gear calibration from real usage data
- [ ] Intensity multiplier per-swimmer calibration
- [ ] Backtest script: validate against historical recorded times
- [ ] WAV file export of pairing results for analysis
- [ ] Wave correction support (wave 2 times +10s adjustment)