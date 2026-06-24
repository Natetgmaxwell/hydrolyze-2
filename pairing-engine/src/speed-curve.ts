/**
 * Speed-distance curve fitting for swimmer PBs.
 *
 * Model: power law in log-log space
 *   ln(speed) = a + b * ln(distance)
 *   where speed = distance / time_ms * 1000  (m/s)
 *
 * From this: time_ms(d) = 1000 * d^(1 - b) * exp(-a)
 *
 * Fitting:
 *   1 PB  → fix b = -0.165 (swimming literature), solve for a
 *   2+ PBs → OLS least-squares in log-log space
 *
 * Literature: speed decays ~d^(-0.165) for trained swimmers.
 * Each doubling of distance costs ~10.8% in speed.
 */

import type { CurvePB, SpeedCurve } from './types.js'

// Literature consensus for trained swimmers: speed decays ~d^(-0.165)
const DEFAULT_B = -0.165

// ─── Curve fitting ─────────────────────────────────────────────────────────────

/**
 * Fit a SpeedCurve from a set of PBs for one swimmer+stroke.
 * Returns null if there are no valid PBs.
 */
export function fitSpeedCurve(pbs: CurvePB[]): SpeedCurve | null {
  const valid = pbs.filter(p => p.distance > 0 && p.pbMs > 0)
  if (valid.length === 0) return null

  if (valid.length === 1) {
    return singlePBCurve(valid[0].distance, valid[0].pbMs)
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
    const meanPbMs = valid.reduce((s, p) => s + p.pbMs, 0) / valid.length
    return singlePBCurve(valid[0].distance, meanPbMs)
  }

  const b = SSxy / SSxx

  // Biologically impossible: speed doesn't decrease with distance
  // Fall back to single PB fix
  if (b >= 0) {
    const sorted = [...valid].sort((a, z) => a.distance - z.distance)
    const mid = sorted[Math.floor(sorted.length / 2)]
    return singlePBCurve(mid.distance, mid.pbMs)
  }

  const a = yMean - b * xMean
  const pbDistances = [...new Set(valid.map(p => p.distance))].sort((x, y) => x - y)

  return { a, b, pbDistances, fitMethod: 'regression' }
}

function singlePBCurve(distance: number, pbMs: number): SpeedCurve {
  const speed = distance / pbMs * 1000
  const b = DEFAULT_B
  const a = Math.log(speed) - b * Math.log(distance)
  return { a, b, pbDistances: [distance], fitMethod: 'single_pb_fixed_slope' }
}

// ─── Prediction ────────────────────────────────────────────────────────────────

/**
 * Predict expected time (ms) at targetDistance using a fitted curve.
 * Returns null if the prediction is physically implausible.
 */
export function predictTime(curve: SpeedCurve, targetDistance: number): number | null {
  if (targetDistance <= 0) return null

  const predictedSpeed = Math.exp(curve.a + curve.b * Math.log(targetDistance))
  const predictedTimeMs = Math.round(targetDistance / predictedSpeed * 1000)

  // Sanity: 20s to 90min for any realistic swim
  if (predictedTimeMs < 20_000 || predictedTimeMs > 5_400_000) return null

  return predictedTimeMs
}

/**
 * Classify a prediction by where the target distance falls relative to
 * the PB distances used to fit the curve.
 */
export function classifyPrediction(curve: SpeedCurve, targetDistance: number): 'exact' | 'interpolated' | 'extrapolated' {
  if (curve.pbDistances.includes(targetDistance)) return 'exact'
  const min = Math.min(...curve.pbDistances)
  const max = Math.max(...curve.pbDistances)
  return targetDistance > min && targetDistance < max ? 'interpolated' : 'extrapolated'
}

/**
 * Convenience: fit a curve from raw PBs and predict in one call.
 * Returns null only when there are no valid PBs at all.
 */
export function predictFromPBs(pbs: CurvePB[], targetDistance: number): { timeMs: number; classification: 'exact' | 'interpolated' | 'extrapolated'; curve: SpeedCurve } | null {
  const curve = fitSpeedCurve(pbs)
  if (!curve) return null
  const timeMs = predictTime(curve, targetDistance)
  if (timeMs === null) return null
  return { timeMs, classification: classifyPrediction(curve, targetDistance), curve }
}

// ─── Convenience: one-liner curve fitting and prediction ───────────────────────

export function fitAndPredict(pbs: CurvePB[], targetDistance: number) {
  return predictFromPBs(pbs, targetDistance)
}