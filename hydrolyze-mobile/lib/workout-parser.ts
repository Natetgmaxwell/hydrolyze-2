/**
 * Workout-level natural language parser.
 *
 * Extends lib/set-parser.ts with:
 *   - Multi-set parsing: "4x100 free, 2x50 kick fins"
 *   - Gear extraction per set component
 *   - Pace target distance propagation to set components
 *   - Partial parse success (some sets parse, others don't)
 *
 * The raw parser is pure and fully unit-tested. The UI layer
 * (WorkoutBuilder screen) adds the manual editor fallback for unparsed text.
 */

import { parseSet, type ParsedSet } from './set-parser'
import type { Stroke } from './ml-pairing'

// ─── Gear types ─────────────────────────────────────────────────────────────

export type GearItem =
  | 'paddles'
  | 'pull_buoy'
  | 'fins'
  | 'kickboard'
  | 'dragSuit'

export type GearType = GearItem[] | null

// Universal gear penalty multipliers (Phase 1 default — per-swimmer in Phase 3).
// > 1 = slower (drag), < 1 = faster ( propulsion assistance).
// These factors apply to the predicted/pb_mean time at scoring time.
export const GEAR_PENALTIES: Record<GearItem, number> = {
  paddles:    1.12,   // more resistance → slower
  pull_buoy:  1.08,   // leg buoyancy removes kick, slightly slower
  fins:       0.88,   // propulsion assist → faster
  kickboard:  1.05,   // restricted arm movement → slower
  dragSuit:   1.18,   // drag suit → significantly slower
}

export function gearPenalty(gear: GearType): number {
  if (!gear || gear.length === 0) return 1.0
  // Apply penalties multiplicatively
  return gear.reduce((total, item) => total * (GEAR_PENALTIES[item] ?? 1.0), 1.0)
}

// ─── Gear extraction ─────────────────────────────────────────────────────────

const GEAR_PATTERNS: Array<[RegExp, GearItem]> = [
  [/\bfins\b/i, 'fins'],
  [/\bflippers\b/i, 'fins'],
  [/\bflipper\b/i, 'fins'],
  [/\bpaddles?\b/i, 'paddles'],
  [/\bpull[\s-]?buoy\b/i, 'pull_buoy'],
  [/\bbuoy\b(?!\s*rate)/i, 'pull_buoy'],
  [/\bkickboard\b/i, 'kickboard'],
  [/\bkick\s*board\b/i, 'kickboard'],
  [/\bboard\b/i, 'kickboard'],
  [/\bdrag\s*suit\b/i, 'dragSuit'],
]

/**
 * Detect all gear items from a natural-language set description.
 * E.g. "4x50 kick fins paddles" → ['fins', 'paddles']
 * Returns null if no gear keyword is found.
 */
export function parseGear(input: string): GearType {
  const detected = new Set<GearItem>()
  for (const [pattern, item] of GEAR_PATTERNS) {
    if (pattern.test(input)) detected.add(item)
  }
  return detected.size > 0 ? Array.from(detected) : null
}

// ─── Workout set output type ─────────────────────────────────────────────────

export interface WorkoutSetComponent {
  /** 0-indexed position in the workout */
  index: number
  /** True if parseSet produced a complete result (reps + distance known) */
  parsed: boolean
  /** The raw input text for this segment */
  rawText: string
  /** Parsed set data (null if parsed=false) */
  set: ParsedSet | null
  /** Detected gear for this set component */
  gear: GearType
  /**
   * Effective distance for stats cache lookup and pairing.
   * Equals set.distance if set.distance is known.
   * Equals set.intensity.paceDistance if intensity is pace_target and paceDistance is set.
   * Used by the pairing algorithm to resolve the correct PB curve.
   */
  effectiveDistance: number | null
}

// ─── Multi-set parser ────────────────────────────────────────────────────────

/**
 * Parse a natural-language workout description into structured set components.
 *
 * Handles:
 *   - Comma-separated set list: "4x100 free, 2x50 kick fins, 200 easy"
 *   - Repeats/Rounds: "3 rounds: 2x50, 2x25" or "4x (50 free, 50 back)"
 *   - Gear detection per set: "... kick fins" → gear=fins
 *   - Pace target resolution: "at 200 pace" sets effectiveDistance=200
 *   - Partial success: first set parsed, second unparseable → both returned
 *
 * @param input Full workout text, e.g. "4x100 free @1:30, 4x50 kick fins @1:00"
 * @returns Array of WorkoutSetComponent, ordered as they appear in the input
 */
export function parseWorkout(input: string): WorkoutSetComponent[] {
  const expandedStrings = expandBlocks(input)
  const result: WorkoutSetComponent[] = []

  expandedStrings.forEach((line) => {
    const set = parseSet(line)
    const gear = parseGear(line)
    const parsed = set.reps !== null && set.distance !== null

    // Effective distance: use pace target distance when set, else set distance
    let effectiveDistance: number | null = null
    if (set.distance !== null) {
      effectiveDistance = set.distance
    }
    if (parsed && set.intensity?.type === 'pace_target' && set.intensity.paceDistance != null) {
      effectiveDistance = set.intensity.paceDistance
    }

    result.push({
      index: result.length,
      parsed,
      rawText: line,
      set,
      gear,
      effectiveDistance,
    })
  })

  return result
}

/**
 * Pre-processor to expand rounds and grouped repeats.
 * E.g. "2 rounds: 4x50, 100 easy" -> ["4x50", "100 easy", "4x50", "100 easy"]
 * E.g. "4x (25 fly, 25 free)" -> ["25 fly", "25 free", "25 fly", "25 free", ...]
 */
function expandBlocks(input: string): string[] {
  // Normalize: replace newlines with commas and clean up spacing
  let text = input.replace(/\n/g, ',').trim()
  if (!text) return []

  // 1. Handle "N rounds: ..." prefix
  const roundsMatch = text.match(/^(\d+)\s*rounds?[:\s]+(.+)$/i)
  if (roundsMatch) {
    const count = parseInt(roundsMatch[1], 10)
    const content = roundsMatch[2]
    const subSets = splitByCommas(content)
    const expanded: string[] = []
    for (let i = 0; i < count; i++) {
      expanded.push(...subSets)
    }
    return expanded
  }

  // 2. Handle nested repeats like "4x (50 free, 50 back)"
  // This is a simplified bracket expansion.
  const bracketRegex = /(\d+)\s*[x×]\s*\(([^)]+)\)/gi
  let match
  let hasBrackets = false
  
  // For now, if we detect brackets, we do a single pass expansion.
  // "A, 2x (B, C), D"
  if (text.includes('(')) {
    // This is tricky to do with just regex if there are multiple comma-separated parts.
    // Let's split by top-level commas first.
    const parts = splitByCommas(text)
    const expanded: string[] = []
    
    parts.forEach(part => {
      const bMatch = part.match(/(\d+)\s*[x×]\s*\(([^)]+)\)/i)
      if (bMatch) {
        const count = parseInt(bMatch[1], 10)
        const content = bMatch[2]
        const subSets = splitByCommas(content)
        for (let i = 0; i < count; i++) {
          expanded.push(...subSets)
        }
      } else {
        expanded.push(part)
      }
    })
    return expanded
  }

  // 3. Fallback: simple comma split
  return splitByCommas(text)
}

/**
 * Split a string by commas, but ignore commas inside parentheses.
 */
function splitByCommas(text: string): string[] {
  const result: string[] = []
  let current = ''
  let depth = 0
  
  for (let i = 0; i < text.length; i++) {
    const char = text[i]
    if (char === '(') depth++
    if (char === ')') depth--
    
    if (char === ',' && depth === 0) {
      result.push(current.trim())
      current = ''
    } else {
      current += char
    }
  }
  
  if (current.trim()) {
    result.push(current.trim())
  }
  
  return result.filter(s => s.length > 0)
}

/**
 * Check if a workout is "complete" — every set component parsed successfully.
 * Used by WorkoutBuilder to decide whether to show the submit button.
 */
export function isWorkoutReady(workout: WorkoutSetComponent[]): boolean {
  return workout.length > 0 && workout.every(c => c.parsed)
}

/**
 * Count how many set components were successfully parsed.
 * Used to display progress: "3 of 4 sets parsed"
 */
export function parsedCount(workout: WorkoutSetComponent[]): number {
  return workout.filter(c => c.parsed).length
}

/**
 * Compute the total rep count across a workout (sum of all parsed reps).
 * Used to estimate how many laps will be recorded.
 * Unparsed sets contribute 0 reps.
 */
export function totalReps(workout: WorkoutSetComponent[]): number {
  return workout.reduce((sum, c) => sum + (c.set?.reps ?? 0), 0)
}

/**
 * Format a workout for display in the SetPicker screen.
 * Returns an array of human-readable labels, one per set component.
 */
export function formatWorkout(workout: WorkoutSetComponent[]): string[] {
  return workout.map(component => {
    if (!component.parsed) {
      return component.rawText
    }
    const parts: string[] = []
    const s = component.set!
    if (s.reps !== null && s.distance !== null) {
      parts.push(`${s.reps}×${s.distance}m`)
    }
    if (s.stroke) parts.push(s.stroke)
    if (component.gear && component.gear.length > 0) {
      parts.push(`(${component.gear.join(' + ')})`)
    }
    if (s.intensity?.label) parts.push(`@ ${s.intensity.label}`)
    if (s.interval) parts.push(`on ${s.interval}`)
    return parts.join(' ') || component.rawText
  })
}

// ─── StatsCache key generation ───────────────────────────────────────────────
// 5-dimension key: swimmerId + stroke + distance + intensity + gear

export function statsCacheKey(
  swimmerId: string,
  stroke: Stroke,
  distance: number,
  intensity: string,
  gear: GearType,
): string {
  // Sort gear to ensure consistent keys regardless of selection order
  const gearStr = gear && gear.length > 0 
    ? [...gear].sort().join(',') 
    : 'none'

  return [
    swimmerId,
    stroke,
    String(distance),
    intensity,
    gearStr,
  ].join(':')
}

// ─── Effective mean computation (for pairTime scoring) ──────────────────────

import { INTENSITY_MULTIPLIERS } from './set-parser'
import type { IntensityLevel } from './set-parser'

export interface SwimmerStatsPlus {
  mean_time_ms: number
  stddev_time_ms: number
  sample_count: number
  is_estimated: boolean
  assignmentSource: string
  /** Raw curve-predicted time before multiplier adjustment */
  pb_predicted_ms?: number
  /** Per-swimmer learned intensity multipliers, keyed by IntensityLevel */
  intensityMultipliers?: Partial<Record<IntensityLevel, number>>
}

/**
 * Compute the effective mean time for a swimmer + set combination.
 * Applies two adjustments in sequence:
 *   1. Intensity multiplier (easy/moderate/hard/race) from per-swimmer calibrations
 *   2. Gear penalty (paddles/fins/etc.) from universal GEAR_PENALTIES
 *
 * Used by the pairing algorithm to compare a lap time against the expected
 * time for the current set's gear + intensity combination.
 */
export function effectiveMean(
  stats: SwimmerStatsPlus,
  repIntensity: IntensityLevel | undefined,
  gear: GearType,
): number {
  // Start from raw mean (recorded data) or pb-predicted time (curve)
  const base = stats.pb_predicted_ms ?? stats.mean_time_ms

  // Apply intensity multiplier
  const intensityMult = stats.intensityMultipliers?.[repIntensity ?? 'moderate']
    ?? INTENSITY_MULTIPLIERS[repIntensity ?? 'moderate']

  // Apply gear penalty (universal factor — Phase 1)
  const gearMult = gearPenalty(gear)

  return base * intensityMult * gearMult
}