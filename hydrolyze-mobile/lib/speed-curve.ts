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
 */

export type CurveSource = 'exact' | 'interpolated' | 'extrapolated' | 'no_data'

export interface CurvePB {
  distance: number  // metres
  pb_ms: number     // personal best in milliseconds
}

export interface SpeedCurve {
  a: number             // log-log intercept
  b: number             // log-log slope (always negative for real swimmers)
  pbDistances: number[] // sorted unique distances used in the fit
  fitMethod: 'regression' | 'single_pb_fixed_slope'
}

export interface CurvePrediction {
  predicted_time_ms: number
  curveSource: CurveSource
}

// Literature consensus for trained swimmers: speed decays as ~d^(-0.165)
// Each doubling of distance costs ~10.8% in speed.
const DEFAULT_B = -0.165

/**
 * Fit a SpeedCurve from a set of PBs for one swimmer+stroke.
 * Returns null if there are no valid PBs.
 */
export function fitSpeedCurve(pbs: CurvePB[]): SpeedCurve | null {
  const valid = pbs.filter(p => p.distance > 0 && p.pb_ms > 0)
  if (valid.length === 0) return null

  if (valid.length === 1) {
    return singlePBCurve(valid[0].distance, valid[0].pb_ms)
  }

  // OLS in log-log space
  const xs = valid.map(p => Math.log(p.distance))
  const ys = valid.map(p => Math.log(p.distance / p.pb_ms * 1000))

  const n = xs.length
  const xMean = xs.reduce((s, x) => s + x, 0) / n
  const yMean = ys.reduce((s, y) => s + y, 0) / n

  const SSxx = xs.reduce((s, x) => s + (x - xMean) ** 2, 0)
  const SSxy = xs.reduce((s, x, i) => s + (x - xMean) * (ys[i] - yMean), 0)

  // Degenerate: all PBs at same distance
  if (SSxx === 0) {
    const meanPbMs = valid.reduce((s, p) => s + p.pb_ms, 0) / valid.length
    return singlePBCurve(valid[0].distance, meanPbMs)
  }

  const b = SSxy / SSxx
  // Biologically impossible: speed increases with distance
  if (b >= 0) {
    // Fall back: use the median PB by distance
    const sorted = [...valid].sort((a, z) => a.distance - z.distance)
    const mid = sorted[Math.floor(sorted.length / 2)]
    return singlePBCurve(mid.distance, mid.pb_ms)
  }

  const a = yMean - b * xMean
  const pbDistances = [...new Set(valid.map(p => p.distance))].sort((x, y) => x - y)

  return { a, b, pbDistances, fitMethod: 'regression' }
}

function singlePBCurve(distance: number, pb_ms: number): SpeedCurve {
  const speed = distance / pb_ms * 1000
  const b = DEFAULT_B
  const a = Math.log(speed) - b * Math.log(distance)
  return { a, b, pbDistances: [distance], fitMethod: 'single_pb_fixed_slope' }
}

/**
 * Predict the expected time at targetDistance using a fitted curve.
 * Returns null if the prediction is physically implausible.
 */
export function predictTime(curve: SpeedCurve, targetDistance: number): CurvePrediction | null {
  if (targetDistance <= 0) return null

  const predictedSpeed = Math.exp(curve.a + curve.b * Math.log(targetDistance))
  const predicted_time_ms = Math.round(targetDistance / predictedSpeed * 1000)

  if (predicted_time_ms <= 0 || predicted_time_ms > 3_600_000) return null

  const curveSource = classifySource(curve, targetDistance)
  return { predicted_time_ms, curveSource }
}

function classifySource(curve: SpeedCurve, targetDistance: number): CurveSource {
  if (curve.pbDistances.includes(targetDistance)) return 'exact'
  if (curve.fitMethod === 'single_pb_fixed_slope') return 'extrapolated'
  const min = curve.pbDistances[0]
  const max = curve.pbDistances[curve.pbDistances.length - 1]
  return targetDistance >= min && targetDistance <= max ? 'interpolated' : 'extrapolated'
}

/**
 * Convenience: fit a curve from raw PBs and predict in one call.
 * Returns null only when there are no valid PBs at all.
 */
export function predictFromPBs(pbs: CurvePB[], targetDistance: number): CurvePrediction | null {
  const curve = fitSpeedCurve(pbs)
  if (!curve) return null
  return predictTime(curve, targetDistance)
}

/**
 * Evaluate the fitted curve at evenly-spaced log-distance points.
 * Used for drawing the curve line in the chart.
 * Returns an array of {distance, speed_ms} points.
 */
export function curvePoints(
  curve: SpeedCurve,
  minDist: number = 25,
  maxDist: number = 1500,
  count: number = 40,
): { distance: number; speed_ms: number }[] {
  const logMin = Math.log(minDist)
  const logMax = Math.log(maxDist)
  const points: { distance: number; speed_ms: number }[] = []

  for (let i = 0; i < count; i++) {
    const logD = logMin + (logMax - logMin) * (i / (count - 1))
    const d = Math.exp(logD)
    const speed = Math.exp(curve.a + curve.b * logD)
    points.push({ distance: d, speed_ms: speed })
  }

  return points
}
