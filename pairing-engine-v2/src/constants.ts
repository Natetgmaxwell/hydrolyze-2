/**
 * Gear penalty multipliers.
 * Value > 1.0 → swimmer is SLOWER (higher time).
 * Value < 1.0 → swimmer is FASTER (lower time).
 *
 * Cold-start universal values. Per-swimmer calibration overrides when available.
 */

export const GEAR_PENALTIES: Record<string, number> = {
  paddles:   1.05,  // 5% slower with paddles
  pull_buoy: 1.03,  // 3% slower
  fins:     0.88, // 12% faster with fins (less drag, more propulsion)
  kickboard: 1.04,  // 4% slower
  dragSuit:  1.10,  // 10% slower
}

/**
 * Intensity multipliers vs race-pace (baseline = 1.00).
 * Applied to the race-pace expected time to get training effort time.
 *
 * e.g. swimmer's 50m Free race pace = 27s.
 *   Moderate effort: 27s × 1.10 = 29.7s expected training time
 *   Hard effort: 27s × 1.03 = 27.8s
 *   Easy effort: 27s × 1.25 = 33.75s
 *
 * NOTE: If we have real recorded training data at this intensity,
 * the multiplier is already baked into the mean — don't double-apply.
 * Multipliers are used for Layer 2 (speed curve) and Layer 3 (seed).
 */
export const INTENSITY_MULTIPLIERS: Record<string, number> = {
  easy:     1.25,
  moderate: 1.10,
  hard:     1.03,
  race:     1.00,
}

/**
 * Stddev as fraction of mean, by distance.
 *
 * Training variance is tighter at sprint distances, looser at distance events.
 * Used for Layer 2 (speed curve predictions) and Layer 3 (population seed).
 *
 * stddev = fraction × mean
 * e.g. 50m: stddev = 0.05 × 27000ms = 1350ms
 * e.g. 400m: stddev = 0.10 × 270000ms = 27000ms
 */
export const STDDEV_FRACTION: Record<string, number> = {
  '25':   0.030,  // 3%  — very tight sprint repeatability
  '50':   0.050,  // 5%  — sprint
  '100':  0.060,  // 6%  — mid-distance
  '200':  0.080,  // 8%  — middle distance
  '400':  0.100,  // 10% — distance
  '800':  0.120,  // 12% — long distance
  '1500': 0.150,  // 15% — endurance
}

export function stddevFraction(distance: number): number {
  const str = String(distance)
  if (str in STDDEV_FRACTION) return STDDEV_FRACTION[str]
  const keys = Object.keys(STDDEV_FRACTION).map(Number).sort((a, b) => a - b)
  if (distance <= keys[0]) return STDDEV_FRACTION[String(keys[0])]
  if (distance >= keys[keys.length - 1]) return STDDEV_FRACTION[String(keys[keys.length - 1])]
  for (let i = 0; i < keys.length - 1; i++) {
    if (distance > keys[i] && distance < keys[i + 1]) {
      const t = (distance - keys[i]) / (keys[i + 1] - keys[i])
      return STDDEV_FRACTION[String(keys[i])] * (1 - t) + STDDEV_FRACTION[String(keys[i + 1])] * t
    }
  }
  return 0.10 // fallback
}

/**
 * Population average speeds (m/s) for adult competitive swimmers.
 * Race-pace speed. Used for Layer 3 cold-start only.
 *
 * e.g. Free 1.45 m/s → 50m race pace = 50000/1.45 ≈ 34.5s
 */
export const POPULATION_SPEEDS: Record<string, number> = {
  Free:   1.45,  // ~69s/100m
  Back:   1.35,  // ~74s/100m
  Breast: 1.30,  // ~77s/100m
  Fly:    1.38,  // ~72s/100m
  IM:     1.35,
}