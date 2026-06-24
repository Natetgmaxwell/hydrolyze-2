/**
 * Rank swimmers by likelihood of having swum a given lap time.
 *
 * Algorithm:
 *   residual_i = |lapTime - expected_i|   (raw gap in ms)
 *   sort ascending by residual → lowest gap = most likely
 *
 * The residual is what the coach actually cares about: "was this within
 * 2 seconds of what I expected, or 10 seconds?"
 *
 * We do NOT normalize by stddev (z-score) because:
 *   - It masks the raw gap ("z=0.4" tells coach nothing about seconds)
 *   - Swimmers with large stddevs would rank first just by having loose expectations
 *
 * We DO show z-score in the output as secondary info, for cases where
 * comparing across different variance levels matters.
 *
 * Edge case: swimmers with very different expected times.
 *   A: 25s, B: 32s. Lap=28s. Residual: A=3s, B=4s → A wins.
 *   The z-score is: A=3/0.3=10, B=4/0.5=8 → B "wins" in z-space.
 *   → Raw residual is what the coach actually knows ("A was 3s off, B was 4s off")
 *
 * When all residuals are high → flag "suspicious lap" for the coach.
 * When top two residuals are close → flag "ambiguous" for manual resolution.
 */

import type { Swimmer, RankedSwimmer, SetContext, LapResult } from './types.js'
import { StatsStore, PBStore } from './types.js'
import { predict, predictPool } from './predict.js'

export interface RankLapResult extends RankedSwimmer {
  /** Raw gap in milliseconds */
  errorMs: number
  /** Error in seconds (for human readability) */
  errorSec: number
  /** z-score: error / stddev */
  zScore: number
  /** Is this lap suspicious for the whole pool? (all residuals > 4s) */
  suspicious: boolean
}

/**
 * Rank swimmers by likelihood for a single lap time.
 *
 * @param lapTimeMs    Raw tap time (ms)
 * @param swimmers     Pool of swimmers present
 * @param ctx          Set context (distance, stroke, intensity, gear)
 * @param statsStore   Layer 1: recorded stats
 * @param pbStore      Layer 2: PBs → speed curve
 * @param gearCalStore Optional: per-swimmer gear calibrations
 * @param thresholdSec Manual override: flag lap suspicious if best residual > this (ms). Default 4000.
 */
export function rankLap(
  lapTimeMs: number,
  swimmers: Swimmer[],
  ctx: SetContext,
  statsStore: StatsStore,
  pbStore: PBStore,
  gearCalStore?: GearCalibrationStore,
  thresholdMs = 4000,
): RankLapResult[] {
  if (swimmers.length === 0) return []
  if (ctx.stroke === 'IM') return []

  const predictions = predictPool(swimmers, ctx, statsStore, pbStore, gearCalStore)

  const withResidual = swimmers.map(swimmer => {
    const pred = predictions.get(swimmer.id)
    if (!pred) {
      return {
        swimmerId: swimmer.id,
        errorMs: Infinity,
        errorSec: Infinity,
        zScore: Infinity,
        expectedTimeMs: 0,
        stddevMs: 0,
        source: 'seed' as const,
        suspicious: false,
      }
    }
    const stddev = pred.stddevMs > 0 ? pred.stddevMs : Math.max(pred.expectedTimeMs * 0.1, 100)
    const errorMs = Math.abs(lapTimeMs - pred.expectedTimeMs)
    const zScore = errorMs / stddev
    return {
      swimmerId: swimmer.id,
      errorMs,
      errorSec: errorMs / 1000,
      zScore,
      expectedTimeMs: pred.expectedTimeMs,
      stddevMs: pred.stddevMs,
      source: pred.source,
      suspicious: false,
    }
  })

  // Sort by residual ascending (lowest = most likely)
  withResidual.sort((a, b) => a.errorMs - b.errorMs)

  // Flag suspicious: best residual > threshold (e.g. 4s means something's off)
  const bestErrorMs = withResidual[0]?.errorMs ?? Infinity
  const suspicious = bestErrorMs > thresholdMs

  // Compute margin ratio (runnerUp error / winner error)
  return withResidual.map((item, i) => ({
    swimmerId: item.swimmerId,
    expectedTimeMs: item.expectedTimeMs,
    stddevMs: item.stddevMs,
    errorMs: item.errorMs,
    errorSec: item.errorSec,
    zScore: item.zScore,
    source: item.source,
    suspicious,
    marginRatio: (i < withResidual.length - 1 && item.errorMs > 0)
      ? withResidual[i + 1].errorMs / item.errorMs
      : null,
  }))
}

/**
 * Rank all laps in a set independently.
 * Note: does NOT resolve multi-lap conflicts (same swimmer assigned to 2 laps).
 * For conflict resolution, use rankSetGreedy() or rankSetHungarian().
 */
export function rankSet(
  lapTimes: number[],
  swimmers: Swimmer[],
  ctx: SetContext,
  statsStore: StatsStore,
  pbStore: PBStore,
  gearCalStore?: GearCalibrationStore,
): LapResult[] {
  return lapTimes.map(lap => ({
    lapTimeMs: lap,
    rankedSwimmers: rankLap(lap, swimmers, ctx, statsStore, pbStore, gearCalStore),
  }))
}

/**
 * Greedy conflict resolution: assign each lap to the best available swimmer,
 * skipping swimmers already assigned to an earlier (lower index) lap.
 * Best for: coach taps LAP in pool order.
 */
export function rankSetGreedy(
  lapTimes: number[],
  swimmers: Swimmer[],
  ctx: SetContext,
  statsStore: StatsStore,
  pbStore: PBStore,
  gearCalStore?: GearCalibrationStore,
): (RankLapResult & { lapTimeMs: number; conflict: boolean })[] {
  const assigned = new Set<string>()
  return lapTimes.map(lap => {
    const ranked = rankLap(lap, swimmers, ctx, statsStore, pbStore, gearCalStore)
    const pick = ranked.find(r => !assigned.has(r.swimmerId)) ?? ranked[0]
    const conflict = assigned.has(pick.swimmerId)
    assigned.add(pick.swimmerId)
    return { lapTimeMs: lap, ...pick, conflict }
  })
}