/**
 * Prediction pipeline — Layer 1 → 2 → 3 lookup.
 *
 * For a swimmer + set context, find the best available prediction of their
 * expected time and variance. Priority:
 *
 *   Layer 1: recorded stats (real training data — best quality)
 *   Layer 2: speed curve from PBs (estimated)
 *   Layer 3: population average (cold start — low priority)
 */

import type { Swimmer, Prediction, SetContext, DataSource, GearCalibrationStore } from './types.js'
import { StatsStore, PBStore } from './types.js'
import { GEAR_PENALTIES, INTENSITY_MULTIPLIERS, STDDEV_FRACTION, POPULATION_SPEEDS } from './constants.js'
import { fitAndPredict } from './speed-curve.js'

// ─── Effective stroke resolution ───────────────────────────────────────────────

function effectiveStroke(swimmer: Swimmer, ctx: SetContext): string {
  return ctx.stroke === 'Form' ? (swimmer.formStroke ?? 'Free') : ctx.stroke
}

// ─── Main prediction function ──────────────────────────────────────────────────

/**
 * Predict a swimmer's expected time and stddev for a set.
 *
 * @param swimmer       The swimmer to predict for
 * @param ctx           Set context (distance, stroke, intensity, gear)
 * @param statsStore    Layer 1: recorded training stats
 * @param pbStore       Layer 2: PB records → speed curve
 * @param gearCalStore  Per-swimmer gear calibrations (optional)
 */
export function predict(
  swimmer: Swimmer,
  ctx: SetContext,
  statsStore: StatsStore,
  pbStore: PBStore,
  gearCalStore?: GearCalibrationStore,
): Prediction | null {
  // IM is always manual — no prediction possible
  if (ctx.stroke === 'IM') return null

  const stroke = effectiveStroke(swimmer, ctx)

  // ── Layer 1: Recorded stats (exact 5-way match) ─────────────────────────────
  {
    const recorded = statsStore.get(swimmer.id, stroke as any, ctx.distance, ctx.intensity, ctx.gear)
    if (recorded) {
      const gearMult = effectiveGearMult(swimmer.id, ctx.gear, gearCalStore)
      const intMult = INTENSITY_MULTIPLIERS[ctx.intensity] ?? 1.10

      // Recorded stats already reflect training reality. Apply gear only.
      // Don't double-apply intensity — it's already mixed into the recorded mean.
      const expectedTimeMs = recorded.meanTimeMs * gearMult
      const stddevMs = recorded.stddevMs * gearMult // scale stddev with mean

      return {
        source: 'recorded',
        expectedTimeMs,
        stddevMs: Math.max(stddevMs, 100),
        sampleCount: recorded.sampleCount,
        gearMultiplier: gearMult,
        intensityMultiplier: 1.0, // not applied — baked into recorded mean
      }
    }
  }

  // ── Layer 2: Speed curve from PBs ───────────────────────────────────────────
  {
    const pbs = pbStore.get(swimmer.id, stroke as any)
    if (pbs.length > 0) {
      const result = fitAndPredict(pbs, ctx.distance)
      if (result) {
        const gearMult = effectiveGearMult(swimmer.id, ctx.gear, gearCalStore)
        const intMult = INTENSITY_MULTIPLIERS[ctx.intensity] ?? 1.10
        const stddevFraction = STDDEV_FRACTION[String(ctx.distance)] ?? 0.10

        const racePaceMs = result.timeMs
        const expectedTimeMs = racePaceMs * intMult * gearMult
        const stddevMs = Math.max(racePaceMs * stddevFraction, 100)

        return {
          source: 'curve',
          expectedTimeMs,
          stddevMs,
          sampleCount: pbs.length,
          gearMultiplier: gearMult,
          intensityMultiplier: intMult,
        }
      }
    }
  }

  // ── Layer 3: Population average (cold start) ──────────────────────────────
  {
    const speedMps = POPULATION_SPEEDS[stroke] ?? 1.35
    const racePaceMs = (ctx.distance / speedMps) * 1000
    const intMult = INTENSITY_MULTIPLIERS[ctx.intensity] ?? 1.10
    const gearMult = effectiveGearMult(swimmer.id, ctx.gear, gearCalStore)
    const stddevFraction = STDDEV_FRACTION[String(ctx.distance)] ?? 0.10

    const expectedTimeMs = racePaceMs * intMult * gearMult
    const stddevMs = Math.max(racePaceMs * stddevFraction, 200)

    return {
      source: 'seed',
      expectedTimeMs: Math.round(expectedTimeMs),
      stddevMs,
      sampleCount: 1,
      gearMultiplier: gearMult,
      intensityMultiplier: intMult,
    }
  }
}

// ─── Gear multiplier helper ───────────────────────────────────────────────────

function effectiveGearMult(swimmerId: string, gear: string | null, calStore?: GearCalibrationStore): number {
  if (!gear) return 1.0
  if (calStore) {
    const cal = calStore.get(swimmerId, gear as any)
    if (cal) return cal.adjustmentFactor
  }
  return GEAR_PENALTIES[gear] ?? 1.0
}

// ─── Pool prediction ──────────────────────────────────────────────────────────

/**
 * Predict for all swimmers in a pool.
 * Returns map of swimmerId → Prediction.
 */
export function predictPool(
  swimmers: Swimmer[],
  ctx: SetContext,
  statsStore: StatsStore,
  pbStore: PBStore,
  gearCalStore?: GearCalibrationStore,
): Map<string, Prediction> {
  const result = new Map<string, Prediction>()
  for (const swimmer of swimmers) {
    const pred = predict(swimmer, ctx, statsStore, pbStore, gearCalStore)
    if (pred !== null) result.set(swimmer.id, pred)
  }
  return result
}