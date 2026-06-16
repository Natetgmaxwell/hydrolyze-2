/**
 * Swimmer pairing — assigns a lap time to the most likely swimmer.
 *
 * Algorithm: residual ranking
 *   residual = |lapTime − expected|
 *   Sort swimmers by residual ascending → lowest = most likely.
 *
 * Drop-in replacement for the old z-score based pairing.
 * Same function signature — backward compatible.
 */

import type { IntensityLevel } from './set-parser'
import { predict, type RecordedStats, type Prediction } from './pairing-v2'
import type { Swimmer, StatsCache } from './pairing-v2'

export type { Swimmer, StatsCache } from './pairing-v2'
export type { Stroke } from './pairing-v2'

export type AssignmentSource = 'recorded' | 'curve' | 'seed' | 'no_data'

export interface Assignment {
  swimmerId: string
  /** Residual in milliseconds — |lapTime − expected| */
  errorMs: number
  source: AssignmentSource
  /** Number of samples informing this prediction (for maturity display in UI) */
  sampleCount: number
}

// ─── Gear multiplier ────────────────────────────────────────────────────────────

const GEAR_PENALTIES: Record<string, number> = {
  paddles:    1.05,
  pull_buoy:  1.03,
  fins:       0.88,
  kickboard:  1.04,
  dragSuit:   1.10,
}
function getGearPenalty(gear: string | null): number {
  return gear ? (GEAR_PENALTIES[gear] ?? 1.0) : 1.0
}

// ─── StatsCache → Prediction bridge ────────────────────────────────────────────

function cacheEntryToPrediction(
  swimmerId: string,
  stroke: string,
  distance: number,
  intensity: string,
  gear: string | null,
  statsCache: StatsCache,
): { pred: Prediction; source: AssignmentSource; sampleCount: number } | null {
  const key = `${swimmerId}:${stroke}:${distance}:${intensity}:${gear ?? 'none'}`
  const entry = statsCache[key]
  if (!entry) return null

  const recordedStats: RecordedStats | null =
    entry.assignmentSource === 'recorded'
      ? { meanTimeMs: entry.mean_time_ms, stddevMs: entry.stddev_time_ms, sampleCount: entry.sample_count }
      : null

  const pbs: { distance: number; pbMs: number }[] =
    entry.pb_predicted_ms != null && entry.assignmentSource !== 'recorded'
      ? [{ distance, pbMs: entry.pb_predicted_ms }]
      : []

  const pred = predict(recordedStats, pbs, stroke, distance, intensity as IntensityLevel, gear)
  return { pred, source: entry.assignmentSource as AssignmentSource, sampleCount: entry.sample_count }
}

// ─── Main pairing function ─────────────────────────────────────────────────────

/**
 * Assign a lap time to a swimmer using residual ranking.
 *
 * @param lapTimeMs    Raw tap time (ms)
 * @param pool         Swimmers present for this rep
 * @param statsCache  Stats cache from attendance screen
 * @param stroke      Stroke type
 * @param intensity   Effort level for this rep
 * @param setDistance Effective distance (may differ for pace-target sets)
 * @param gear        Gear being worn (null = no gear)
 */
export function pairTime(
  lapTimeMs: number,
  pool: Swimmer[],
  statsCache: StatsCache,
  stroke: string,
  intensity: IntensityLevel | undefined,
  setDistance: number,
  gear: string | null,
): Assignment | null {
  if (stroke === 'IM') return null
  if (pool.length === 0) return null

  const intensityKey = intensity ?? 'moderate'
  const effectiveStroke = (s: Swimmer) =>
    stroke === 'Form' ? (s.form_stroke ?? 'Free') : stroke

  let bestId: string | null = null
  let bestError = Infinity
  let bestSource: AssignmentSource = 'no_data'
  let bestSampleCount = 0

  for (const swimmer of pool) {
    const es = effectiveStroke(swimmer)
    const result = cacheEntryToPrediction(swimmer.id, es, setDistance, intensityKey, gear, statsCache)
    if (!result) continue

    const errorMs = Math.abs(lapTimeMs - result.pred.expectedTimeMs)
    if (errorMs < bestError) {
      bestError = errorMs
      bestId = swimmer.id
      bestSource = result.source
      bestSampleCount = result.sampleCount
    }
  }

  if (bestId === null) {
    return { swimmerId: pool[0].id, errorMs: Infinity, source: 'seed', sampleCount: 0 }
  }

  return { swimmerId: bestId, errorMs: bestError, source: bestSource, sampleCount: bestSampleCount }
}

// ─── Full ranking for swap modal ─────────────────────────────────────────────

export function rankSwimmers(
  lapTimeMs: number,
  pool: Swimmer[],
  statsCache: StatsCache,
  stroke: string,
  intensity: IntensityLevel | undefined,
  setDistance: number,
  gear: string | null,
): Array<{
  swimmerId: string
  swimmerName: string
  expectedTimeMs: number
  errorMs: number
  errorSec: number
  source: AssignmentSource
  sampleCount: number
}> {
  if (stroke === 'IM') return []
  if (pool.length === 0) return []

  const intensityKey = intensity ?? 'moderate'
  const effectiveStroke = (s: Swimmer) =>
    stroke === 'Form' ? (s.form_stroke ?? 'Free') : stroke

  const results = pool.map(swimmer => {
    const es = effectiveStroke(swimmer)
    const result = cacheEntryToPrediction(swimmer.id, es, setDistance, intensityKey, gear, statsCache)
    if (!result) {
      return {
        swimmerId: swimmer.id,
        swimmerName: swimmer.name,
        expectedTimeMs: 0,
        errorMs: Infinity,
        errorSec: Infinity,
        source: 'seed' as AssignmentSource,
        sampleCount: 0,
      }
    }
    const errorMs = Math.abs(lapTimeMs - result.pred.expectedTimeMs)
    return {
      swimmerId: swimmer.id,
      swimmerName: swimmer.name,
      expectedTimeMs: result.pred.expectedTimeMs,
      errorMs,
      errorSec: errorMs / 1000,
      source: result.source,
      sampleCount: result.sampleCount,
    }
  })

  results.sort((a, b) => a.errorMs - b.errorMs)
  return results
}