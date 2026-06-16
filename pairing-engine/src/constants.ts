import type { GearType, IntensityLevel } from './types.js'

// ─── Confidence ceilings per source ────────────────────────────────────────────

export const CONFIDENCE_CEILING: Record<string, number> = {
  recorded: 95,
  curve:    70,
  seed:     55,
  no_data:   0,
}

// ─── Intensity multipliers (fraction of race-pace time = slower = higher ms) ─

/**
 * Maps a training intensity to a time multiplier vs race-pace.
 * e.g. 'easy' 1.25 → a "easy" 100m takes 25% longer than their race-pace 100m.
 *
 * These are population averages — per-swimmer calibration overrides in Phase 3.
 */
export const INTENSITY_MULTIPLIERS: Record<IntensityLevel, number> = {
  easy:     1.25,
  moderate: 1.10,
  hard:     1.03,
  race:     1.00,
}

// ─── Gear penalty / bonus multipliers ─────────────────────────────────────────

/**
 * Per-gear adjustment to effective mean time.
 * Values > 1.0 → slower (paddles add resistance, drag suit adds drag).
 * Values < 1.0 → faster (fins add propulsion).
 *
 * These are universal cold-start values. Per-swimmer calibration replaces these.
 * Key: gearType string (from GearType union)
 */
export const GEAR_PENALTIES: Record<string, number> = {
  paddles:   1.05,
  pull_buoy: 1.03,
  fins:      0.88,  // ← fins make swimmers FASTER (less drag, more propulsion)
  kickboard: 1.04,
  dragSuit:  1.10,
}

// ─── Stddev as fraction of mean, by distance ───────────────────────────────────

/**
 * Training variance (stddev as fraction of mean) varies with distance.
 * Sprint distances (25-50m) are more repeatable. Distance events have more variance.
 *
 * stddevMs = stddevFraction[distance] * meanTimeMs
 *
 * For distances not in the table, uses linear interpolation.
 * For recorded stats, the actual stddev from the DB overrides this.
 */
export const STDDEV_FRACTION: Record<string, number> = {
  '25':  0.030,  // 3%  — very tight, sprint repeatability
  '50':  0.050,  // 5%  — sprint
  '100': 0.060,  // 6%  — mid-distance
  '200': 0.080,  // 8%  — middle distance
  '400': 0.100,  // 10% — distance
  '800': 0.120,  // 12% — long distance
  '1500':0.150,  // 15% — endurance
}

/**
 * Get the stddev fraction for a given distance.
 * Falls back to linear interpolation between nearest entries.
 */
export function getStddevFraction(distanceMetres: number): number {
  const distStr = String(distanceMetres)
  if (distStr in STDDEV_FRACTION) return STDDEV_FRACTION[distStr]

  const keys = Object.keys(STDDEV_FRACTION)
    .map(Number)
    .sort((a, b) => a - b)

  if (distanceMetres <= keys[0]) return STDDEV_FRACTION[String(keys[0])]
  if (distanceMetres >= keys[keys.length - 1]) return STDDEV_FRACTION[String(keys[keys.length - 1])]

  // Linear interpolate
  for (let i = 0; i < keys.length - 1; i++) {
    if (distanceMetres > keys[i] && distanceMetres < keys[i + 1]) {
      const t = (distanceMetres - keys[i]) / (keys[i + 1] - keys[i])
      return STDDEV_FRACTION[String(keys[i])] * (1 - t) + STDDEV_FRACTION[String(keys[i + 1])] * t
    }
  }

  return 0.10 // ultimate fallback
}

// ─── Gear penalty lookup ───────────────────────────────────────────────────────

export function getGearPenalty(gear: GearType | null): number {
  if (gear === null) return 1.0
  return GEAR_PENALTIES[gear] ?? 1.0
}

// ─── Cold-start seed values (population averages, metres per second) ──────────

/**
 * Population average speeds by stroke (m/s) for adult competitive swimmers.
 * Used as cold-start when no per-swimmer data exists.
 *
 * Key: stroke
 * Value: speed in m/s (e.g. 1.4 = 1.4 m/s ≈ 85s/100m)
 *
 * These represent moderate training effort, not race pace.
 * Multiply by (1 / INTENSITY_MULTIPLIERS.moderate) to get race-pace speed.
 */
export const POPULATION_SPEEDS: Record<string, number> = {
  Free:   1.45,  // ~69s/100m at moderate
  Back:   1.35,  // ~74s/100m
  Breast: 1.30,  // ~77s/100m
  Fly:    1.38,  // ~72s/100m
  IM:     1.35,
}

// ─── Sample count for synthetic predictions ───────────────────────────────────

export const SAMPLE_COUNT = {
  curve: 3,   // Power-law fit from PBs (rough estimate)
  seed:  1,   // Cold-start — single observation used to seed
}