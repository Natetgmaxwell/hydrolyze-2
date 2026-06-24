/**
 * Speed-distance curve fitting from personal bests.
 *
 * Model: power law in log-log space
 *   speed = a × distance^b
 *   where speed = distance / time_ms × 1000  (m/s)
 *
 * Fitting:
 *   1 PB  → fix b = -0.165 (swimming literature), solve for a
 *   2+ PBs → OLS in log-log space, estimate both a and b
 *
 * Then predict: time(d) = 1000 × d / speed(d)
 */

import type { PB } from './types.js'

// Swimming literature: speed ~ distance^(-0.165)
// Each doubling of distance costs ~10.8% in speed.
const DEFAULT_B = -0.165

export interface SpeedCurve {
  a: number   // log-log intercept
  b: number   // log-log slope (negative for swimmers)
  /** PB distances used to fit this curve */
  fitDistances: number[]
  fitMethod: 'single_pb_fixed_slope' | 'ols_regression'
}

/**
 * Fit a speed curve from PB records for one swimmer + stroke.
 * Returns null if no valid PBs.
 */
export function fitCurve(pbs: PB[]): SpeedCurve | null {
  const valid = pbs.filter(p => p.distance > 0 && p.pbMs > 0 && p.pbMs < 3_600_000)
  if (valid.length === 0) return null

  if (valid.length === 1) {
    return singlePB(valid[0].distance, valid[0].pbMs)
  }

  // OLS in log-log space
  const xs = valid.map(p => Math.log(p.distance))
  const ys = valid.map(p => Math.log(p.distance / p.pbMs * 1000))
  const n = xs.length

  const xMean = xs.reduce((s, x) => s + x, 0) / n
  const yMean = ys.reduce((s, y) => s + y, 0) / n

  const SSxx = xs.reduce((s, x) => s + (x - xMean) ** 2, 0)
  const SSxy = xs.reduce((s, x, i) => s + (x - xMean) * (ys[i] - yMean), 0)

  // Degenerate: all PBs at same distance
  if (SSxx === 0) {
    return singlePB(valid[0].distance, valid[0].pbMs)
  }

  const b = SSxy / SSxx

  // Impossible: speed increases with distance (non-swimmer data)
  if (b >= 0) {
    const mid = valid[Math.floor(valid.length / 2)]
    return singlePB(mid.distance, mid.pbMs)
  }

  const a = yMean - b * xMean
  return {
    a,
    b,
    fitDistances: [...new Set(valid.map(p => p.distance))].sort((x, y) => x - y),
    fitMethod: 'ols_regression',
  }
}

function singlePB(distance: number, pbMs: number): SpeedCurve {
  const speed = distance / pbMs * 1000
  return {
    a: Math.log(speed) - DEFAULT_B * Math.log(distance),
    b: DEFAULT_B,
    fitDistances: [distance],
    fitMethod: 'single_pb_fixed_slope',
  }
}

/**
 * Predict expected race-pace time (ms) at target distance.
 * Returns null if prediction is physically implausible.
 */
export function predictRacePace(curve: SpeedCurve, distance: number): number | null {
  if (distance <= 0) return null
  const speed = Math.exp(curve.a + curve.b * Math.log(distance))
  const timeMs = Math.round(distance / speed * 1000)
  // Sanity: 20s to 90min
  if (timeMs < 20_000 || timeMs > 5_400_000) return null
  return timeMs
}

/**
 * Classify where the target distance falls relative to the fit data.
 */
export function classify(curve: SpeedCurve, targetDistance: number): 'exact' | 'interpolated' | 'extrapolated' {
  if (curve.fitDistances.includes(targetDistance)) return 'exact'
  const min = Math.min(...curve.fitDistances)
  const max = Math.max(...curve.fitDistances)
  return targetDistance > min && targetDistance < max ? 'interpolated' : 'extrapolated'
}

/**
 * Convenience: fit curve from PBs and predict in one call.
 */
export function fitAndPredict(pbs: PB[], distance: number): { timeMs: number; curve: SpeedCurve; classification: 'exact' | 'interpolated' | 'extrapolated' } | null {
  const curve = fitCurve(pbs)
  if (!curve) return null
  const timeMs = predictRacePace(curve, distance)
  if (timeMs === null) return null
  return { timeMs, curve, classification: classify(curve, distance) }
}