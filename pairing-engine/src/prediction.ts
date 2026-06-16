/**
 * Prediction pipeline — Layer 1/2/3 lookup system.
 *
 * For a given swimmer + set context (distance, stroke, intensity, gear),
 * tries each lookup in priority order until a prediction is found.
 *
 * Priority:
 *   Layer 1 (recorded stats):  exact 5-way match from swimmer_stats table
 *   Layer 2 (speed curve):     PB-based prediction (fallback from Layer 1)
 *   Layer 3 (universal seed):  population average when no other data exists
 *
 * Each returned SwimmerPrediction carries a confidence ceiling that reflects
 * the data quality of the source.
 */

import type {
  SwimmerPrediction,
  SwimmerStatsRecord,
  GearCalibration,
  CurvePB,
  Stroke,
  IntensityLevel,
  GearType,
} from './types.js'
import {
  INTENSITY_MULTIPLIERS,
  getGearPenalty,
  getStddevFraction,
  POPULATION_SPEEDS,
  SAMPLE_COUNT,
  CONFIDENCE_CEILING,
} from './constants.js'
import { fitSpeedCurve, predictTime, classifyPrediction } from './speed-curve.js'

// ─── Gear calibration registry ────────────────────────────────────────────────

/**
 * In-memory per-swimmer gear calibrations.
 * Key: `${swimmerId}:${gear}`
 * Value: personal adjustment factor (multiplier to bare-hand mean)
 *
 * In production this would come from a swimmer_gears table in Supabase.
 * For the standalone engine, we initialize from the seed data or
 * accept an optional calibration map as input.
 */
export class GearCalibrationStore {
  private calibrations = new Map<string, GearCalibration>()

  add(cal: GearCalibration): void {
    this.calibrations.set(`${cal.swimmerId}:${cal.gear}`, cal)
  }

  get(swimmerId: string, gear: GearType): GearCalibration | undefined {
    return this.calibrations.get(`${swimmerId}:${gear}`)
  }

  /** Effective gear penalty for this swimmer: per-swimmer calibration, or universal fallback */
  effectivePenalty(swimmerId: string, gear: GearType | null): number {
    if (gear === null) return 1.0
    const cal = this.get(swimmerId, gear)
    if (cal) return cal.adjustmentFactor
    return getGearPenalty(gear)
  }
}

// ─── Recorded stats store ─────────────────────────────────────────────────────

/**
 * Layer 1: explicit recorded stats from swimmer_stats table.
 * Key: `${swimmerId}:${stroke}:${distance}:${intensity}:${gear ?? 'bare'}`
 */
export class StatsStore {
  private stats = new Map<string, SwimmerStatsRecord>()

  /** Set a swimmer's recorded stats for an exact 5-way combination */
  set(swimmerId: string, stroke: Stroke, distance: number, intensity: IntensityLevel, gear: GearType | null, record: SwimmerStatsRecord): void {
    const key = this.makeKey(swimmerId, stroke, distance, intensity, gear)
    this.stats.set(key, record)
  }

  /** Get exact 5-way match */
  get(swimmerId: string, stroke: Stroke, distance: number, intensity: IntensityLevel, gear: GearType | null): SwimmerStatsRecord | undefined {
    return this.stats.get(this.makeKey(swimmerId, stroke, distance, intensity, gear))
  }

  /** Get without gear (bare hand fallback) */
  getBareHand(swimmerId: string, stroke: Stroke, distance: number, intensity: IntensityLevel): SwimmerStatsRecord | undefined {
    return this.stats.get(this.makeKey(swimmerId, stroke, distance, intensity, null))
  }

  private makeKey(swimmerId: string, stroke: Stroke, distance: number, intensity: IntensityLevel, gear: GearType | null): string {
    return `${swimmerId}:${stroke}:${distance}:${intensity}:${gear ?? 'bare'}`
  }
}

// ─── PB store ───────────────────────────────────────────────────────────────────

/**
 * Layer 2: PB records for speed curve prediction.
 * Key: `${swimmerId}:${stroke}`
 * Value: sorted array of PBs at various distances
 */
export class PBStore {
  private pbs = new Map<string, CurvePB[]>()

  set(swimmerId: string, stroke: Stroke, pbs: CurvePB[]): void {
    this.pbs.set(`${swimmerId}:${stroke}`, [...pbs].sort((a, b) => a.distance - b.distance))
  }

  get(swimmerId: string, stroke: Stroke): CurvePB[] {
    return this.pbs.get(`${swimmerId}:${stroke}`) ?? []
  }

  has(swimmerId: string, stroke: Stroke): boolean {
    return this.pbs.has(`${swimmerId}:${stroke}`)
  }
}

// ─── Core prediction pipeline ─────────────────────────────────────────────────

/**
 * Predict mean and stddev for a swimmer in a given set context.
 * Uses recorded stats → speed curve → universal seed priority order.
 *
 * @param swimmerId     Swimmer identifier
 * @param formStroke   Swimmer's form stroke (for "Form" resolution)
 * @param stroke        Stroke of the current set
 * @param distance      Distance in metres
 * @param intensity    Intensity level
 * @param gear          Gear type or null
 * @param statsStore    Layer 1: recorded stats
 * @param pbStore       Layer 2: PB data for speed curve
 * @param gearCalStore  Per-swimmer gear calibrations
 */
export function predictSwimmer(
  swimmerId: string,
  formStroke: Stroke | null,
  stroke: Stroke,
  distance: number,
  intensity: IntensityLevel,
  gear: GearType | null,
  statsStore: StatsStore,
  pbStore: PBStore,
  gearCalStore: GearCalibrationStore,
): SwimmerPrediction {
  // Resolve "Form" to the swimmer's form stroke
  const effectiveStroke: Stroke = stroke === 'Form' ? (formStroke ?? 'Free') : stroke

  // ── Layer 1: Recorded stats (exact 5-way match) ────────────────────────────
  {
    const recorded = statsStore.get(swimmerId, effectiveStroke, distance, intensity, gear)
    if (recorded) {
      const gearPenalty = gearCalStore.effectivePenalty(swimmerId, gear)
      // Recorded stats already reflect real training times.
      // Gear penalty is applied to the effective mean.
      const meanTimeMs = recorded.meanTimeMs * gearPenalty
      return {
        statsType: 'recorded',
        meanTimeMs,
        stddevMs: recorded.stddevMs,
        sampleCount: recorded.sampleCount,
        sourceLabel: `recorded: swimmer_stats(${distance}m ${effectiveStroke}${gear ? ` w/ ${gear}` : ''}, n=${recorded.sampleCount}, σ=${recorded.stddevMs}ms)`,
        gearPenalty,
        confidenceCeiling: CONFIDENCE_CEILING.recorded,
      }
    }
  }

  // ── Layer 1 fallback: same swimmer, same stroke/distance/intensity, no gear ─
  {
    const bareHand = statsStore.getBareHand(swimmerId, effectiveStroke, distance, intensity)
    if (bareHand && gear !== null) {
      const gearPenalty = gearCalStore.effectivePenalty(swimmerId, gear)
      const meanTimeMs = bareHand.meanTimeMs * gearPenalty
      return {
        statsType: 'recorded',
        meanTimeMs,
        stddevMs: bareHand.stddevMs,
        sampleCount: bareHand.sampleCount,
        sourceLabel: `recorded: swimmer_stats(${distance}m ${effectiveStroke} bare→${gear}, n=${bareHand.sampleCount})`,
        gearPenalty,
        confidenceCeiling: CONFIDENCE_CEILING.recorded,
      }
    }
  }

  // ── Layer 2: Speed curve from PBs ──────────────────────────────────────────
  {
    const swimmerPBs = pbStore.get(swimmerId, effectiveStroke)
    if (swimmerPBs.length > 0) {
      const curve = fitSpeedCurve(swimmerPBs)
      if (curve) {
        const curveTimeMs = predictTime(curve, distance)
        if (curveTimeMs !== null) {
          const gearPenalty = gearCalStore.effectivePenalty(swimmerId, gear)
          const classification = classifyPrediction(curve, distance)
          const intensityMult = INTENSITY_MULTIPLIERS[intensity]
          const stddevFraction = getStddevFraction(distance)

          // Speed curve predicts race-pace. Apply intensity multiplier.
          const meanTimeMs = curveTimeMs * intensityMult * gearPenalty
          // stddev: use distance-aware fraction of mean (not from curve)
          const stddevMs = Math.max(meanTimeMs * stddevFraction, 100)

          const sourceLabel = `curve: ${classification} from ${swimmerPBs.length} PB(s) for ${effectiveStroke}${gear ? ` + ${gear}` : ''}`
          return {
            statsType: 'curve',
            meanTimeMs,
            stddevMs,
            sampleCount: SAMPLE_COUNT.curve,
            sourceLabel,
            gearPenalty,
            curve,
            confidenceCeiling: CONFIDENCE_CEILING.curve,
          }
        }
      }
    }
  }

  // ── Layer 3: Universal seed (population averages) ───────────────────────────
  {
    const speedMps = POPULATION_SPEEDS[effectiveStroke] ?? 1.35
    // Race-pace speed → training time (apply intensity multiplier)
    const racePaceTimeMs = (distance / speedMps) * 1000
    const intensityMult = INTENSITY_MULTIPLIERS[intensity]
    const gearPenalty = gear !== null ? gearCalStore.effectivePenalty(swimmerId, gear) : 1.0
    const meanTimeMs = racePaceTimeMs * intensityMult * gearPenalty

    const stddevFraction = getStddevFraction(distance)
    const stddevMs = Math.max(meanTimeMs * stddevFraction, 100)

    return {
      statsType: 'seed',
      meanTimeMs: Math.round(meanTimeMs),
      stddevMs,
      sampleCount: SAMPLE_COUNT.seed,
      sourceLabel: `seed: population avg for ${effectiveStroke} ${distance}m (${Math.round(meanTimeMs / 100) / 10}s predicted, ${Math.round(stddevFraction * 100)}% σ)`,
      gearPenalty,
      confidenceCeiling: CONFIDENCE_CEILING.seed,
    }
  }
}

// ─── Batch prediction ──────────────────────────────────────────────────────────

export interface SwimmerWithForm {
  id: string
  formStroke: Stroke | null
}

export interface Predictions {
  [swimmerId: string]: SwimmerPrediction
}

/**
 * Run the prediction pipeline for all swimmers in the pool.
 * Returns a map of swimmerId → SwimmerPrediction.
 */
export function predictPool(
  swimmers: SwimmerWithForm[],
  distance: number,
  stroke: Stroke,
  intensity: IntensityLevel,
  gear: GearType | null,
  statsStore: StatsStore,
  pbStore: PBStore,
  gearCalStore: GearCalibrationStore,
): Predictions {
  const result: Predictions = {}
  for (const swimmer of swimmers) {
    result[swimmer.id] = predictSwimmer(
      swimmer.id,
      swimmer.formStroke,
      stroke,
      distance,
      intensity,
      gear,
      statsStore,
      pbStore,
      gearCalStore,
    )
  }
  return result
}