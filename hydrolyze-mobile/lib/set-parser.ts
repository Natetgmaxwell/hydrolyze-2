import type { Stroke } from './ml-pairing'
import { WORD_NUMBERS, SWIM_DISTANCES } from './constants/swim-constants'

/**
 * Simplified 4-level intensity for the pairing algorithm.
 * Maps to training-time multipliers applied when predicting swimmer times.
 * More granular IntensityType (below) is preserved for display and DB storage.
 */
export type IntensityLevel = 'easy' | 'moderate' | 'hard' | 'race'

/** Global default multipliers — replaced per-swimmer as calibration data accumulates. */
export const INTENSITY_MULTIPLIERS: Record<IntensityLevel, number> = {
  easy:     1.25,
  moderate: 1.10,
  hard:     1.03,
  race:     1.00,
}

export type IntensityType =
  | 'easy'           // recovery, easy, aerobic
  | 'aerobic'        // steady state, cruise
  | 'threshold'      // T-pace, CSS, threshold
  | 'race_pace'      // race pace, RP
  | 'pace_target'    // "at 200 pace", "on 400 pace" — specific equivalent distance
  | 'sprint'         // all out, max, sprint
  | 'descend'        // descend 1-3 (each rep faster than last)
  | 'build'          // building effort through the rep
  | 'negative_split' // second half faster than first

export interface ParsedIntensity {
  type: IntensityType
  // Only set when type = 'pace_target': the equivalent distance being targeted
  // e.g. "at 200 pace" → paceDistance = 200
  paceDistance: number | null
  // Raw label for display, e.g. "200 pace", "descend 1-3", "build"
  label: string
}

export interface ParsedSet {
  reps: number | null
  distance: number | null
  stroke: Stroke | null
  interval: string | null
  intensity: ParsedIntensity | null
  /**
   * Per-rep intensity levels — length equals reps (once reps is known).
   * Used by the pairing algorithm to pick the right training-time multiplier
   * for each rep. "1 easy 1 fast" → ['easy','hard','easy','hard'].
   * Populated when intensities can be resolved; empty array otherwise.
   */
  intensityPattern: IntensityLevel[]
}

// ─── Normalizer ───────────────────────────────────────────────────────────────

function normalizeInput(input: string): string {
  let text = input.toLowerCase().trim()
  for (const [word, num] of Object.entries(WORD_NUMBERS)) {
    text = text.replace(new RegExp(`\\b${word}\\b`, 'g'), String(num))
  }
  text = text.replace(/(\d+)\s+and\s+a\s+half/g, (_, n) => String(parseFloat(n) + 0.5))
  return text
}

// ─── Interval parser ──────────────────────────────────────────────────────────

function parseInterval(text: string): string | null {
  // "on 1:30" or bare "1:30"
  const colonMatch = text.match(/(?:on\s+)?(\d+):(\d{2})(?:\s+(?:interval|rest|i\/?)?)?/)
  if (colonMatch) return `${colonMatch[1]}:${colonMatch[2]}`

  // "on 1 minute 30 seconds"
  const minSecMatch = text.match(/on\s+(\d+)\s*min(?:ute)?s?\s+(\d+)/)
  if (minSecMatch) return `${minSecMatch[1]}:${minSecMatch[2].padStart(2, '0')}`

  // "on 1.5 minutes" → "1:30"
  const decimalMinMatch = text.match(/on\s+(\d+\.5)\s*min(?:ute)?s?/)
  if (decimalMinMatch) {
    const total = parseFloat(decimalMinMatch[1])
    const mins = Math.floor(total)
    const secs = Math.round((total - mins) * 60)
    return `${mins}:${String(secs).padStart(2, '0')}`
  }

  // "on 2 minutes"
  const minMatch = text.match(/on\s+(\d+)\s*min(?:ute)?s?(?:\s|$)/)
  if (minMatch) return `${minMatch[1]}:00`

  // "on 90 seconds"
  const secMatch = text.match(/on\s+(\d+)\s*s(?:ec(?:ond)?s?)?(?:\s|$)/)
  if (secMatch) {
    const secs = parseInt(secMatch[1])
    return `${Math.floor(secs / 60)}:${String(secs % 60).padStart(2, '0')}`
  }

  return null
}

// ─── Intensity parser ─────────────────────────────────────────────────────────

/**
 * Detects the training intensity or effort prescription from natural language.
 *
 * Handles:
 *   Pace targets:   "at 200 pace", "on 400 pace", "200 effort", "sub-1:30 pace"
 *   Progressions:   "descend 1-3", "descend 1 to 4", "negative split", "build", "building"
 *   Effort zones:   "easy", "recovery", "aerobic", "steady", "threshold", "CSS",
 *                   "T-pace", "race pace", "RP", "sprint", "all out", "max effort"
 *
 * Why this matters: "4 x 100 at 200 pace" and "4 x 100 at 400 pace" must be
 * compared separately — they are completely different physiological efforts.
 * Storing intensity allows the ML to group like-for-like when computing swimmer stats.
 */
function parseIntensity(raw: string, normalized: string): ParsedIntensity | null {

  // ── Pace target: "at 200 pace" / "on 200 pace" / "200 effort" ─────────────
  // Also handles "50m pace", "200m pace"
  const paceMatch = normalized.match(
    /(?:at|on|@)\s+(\d+)\s*m?\s+(?:pace|effort|speed|intensity)/
  )
  if (paceMatch) {
    const pd = parseInt(paceMatch[1])
    if (SWIM_DISTANCES.has(pd)) {
      return { type: 'pace_target', paceDistance: pd, label: `${pd} pace` }
    }
  }

  // "50 pace" / "200 pace" without "at/on" — but only if the number is a known
  // distance that isn't the set distance (disambiguate: "4 x 50 free 100 pace")
  const barePaceMatch = normalized.match(/\b(\d+)\s+pace\b/)
  if (barePaceMatch) {
    const pd = parseInt(barePaceMatch[1])
    if (SWIM_DISTANCES.has(pd)) {
      return { type: 'pace_target', paceDistance: pd, label: `${pd} pace` }
    }
  }

  // ── Descend: "descend 1-3", "desc 1-3", "descending" ──────────────────────
  const descendMatch = normalized.match(
    /\bdesc(?:end(?:ing)?)?\s*(?:(\d+)\s*(?:-|to)\s*(\d+))?/
  )
  if (descendMatch) {
    const label = descendMatch[1] && descendMatch[2]
      ? `descend ${descendMatch[1]}–${descendMatch[2]}`
      : 'descend'
    return { type: 'descend', paceDistance: null, label }
  }

  // ── Negative split ─────────────────────────────────────────────────────────
  if (/\bneg(?:ative)?\s*split\b/i.test(raw)) {
    return { type: 'negative_split', paceDistance: null, label: 'negative split' }
  }

  // ── Build ──────────────────────────────────────────────────────────────────
  if (/\bbuild(?:ing)?\b/i.test(raw)) {
    return { type: 'build', paceDistance: null, label: 'build' }
  }

  // ── Sprint / max ───────────────────────────────────────────────────────────
  if (/\b(?:sprint|all[\s-]?out|max(?:\s+effort)?|blast|fast)\b/i.test(raw)) {
    return { type: 'sprint', paceDistance: null, label: 'sprint' }
  }

  // ── Race pace / bare "race" ───────────────────────────────────────────────
  if (/\b(?:race(?:\s+pace)?|r\.?p\.?|goal\s+pace)\b/i.test(raw)) {
    return { type: 'race_pace', paceDistance: null, label: 'race pace' }
  }

  // ── Threshold / CSS / T-pace ───────────────────────────────────────────────
  if (/\b(?:threshold|css|critical\s+swim\s+speed|t[\s-]?pace|lactate)\b/i.test(raw)) {
    return { type: 'threshold', paceDistance: null, label: 'threshold' }
  }

  // ── Aerobic / steady ───────────────────────────────────────────────────────
  if (/\b(?:aerobic|steady|cruise|moderate|comfortable)\b/i.test(raw)) {
    return { type: 'aerobic', paceDistance: null, label: 'aerobic' }
  }

  // ── Easy / recovery ────────────────────────────────────────────────────────
  if (/\b(?:easy|recovery|recover|warm[\s-]?up|cool[\s-]?down|loosen)\b/i.test(raw)) {
    return { type: 'easy', paceDistance: null, label: 'easy' }
  }

  return null
}

// ─── Per-rep intensity pattern helpers ───────────────────────────────────────

/**
 * Map from word → IntensityLevel for the per-rep block parser.
 * "1 easy 1 fast" → easy maps to 'easy', fast maps to 'hard'.
 */
const LEVEL_ALIASES: Record<string, IntensityLevel> = {
  easy: 'easy', ez: 'easy', recovery: 'easy', loosen: 'easy',
  mod: 'moderate', moderate: 'moderate', aerobic: 'moderate', steady: 'moderate', cruise: 'moderate',
  hard: 'hard', fast: 'hard', strong: 'hard', tempo: 'hard', threshold: 'hard',
  race: 'race', sprint: 'race', max: 'race', allout: 'race',
}

/**
 * Try to parse a "N level N level" repeating block from the beginning of `text`.
 * Returns the repeating unit if found, otherwise null.
 * e.g. "1 easy 1 fast" → ['easy','hard']
 *      "2 mod 1 fast"  → ['moderate','moderate','hard']
 */
function parseRepBlock(text: string): IntensityLevel[] | null {
  const tokenRe = /(\d+)\s+([a-z-]+)/g
  const result: IntensityLevel[] = []
  let lastIndex = 0
  let match: RegExpExecArray | null

  while ((match = tokenRe.exec(text)) !== null) {
    const count = parseInt(match[1], 10)
    const level = LEVEL_ALIASES[match[2]]
    if (!level) break
    for (let i = 0; i < count; i++) result.push(level)
    lastIndex = tokenRe.lastIndex
  }

  // Valid if we consumed a meaningful portion of the string with results
  if (result.length >= 2 && lastIndex > 0) return result
  return null
}

/** Map the richer IntensityType to the 4-level simplified IntensityLevel. */
export function intensityTypeToLevel(type: IntensityType): IntensityLevel {
  switch (type) {
    case 'easy':          return 'easy'
    case 'aerobic':       return 'moderate'
    case 'threshold':     return 'hard'
    case 'race_pace':     return 'race'
    case 'pace_target':   return 'race'
    case 'sprint':        return 'race'
    case 'descend':       return 'moderate'  // midpoint of the range
    case 'build':         return 'moderate'
    case 'negative_split':return 'moderate'
  }
}

/**
 * Build an IntensityLevel[] of length `reps` given a ParsedIntensity and
 * an optional per-rep block that overrides it (e.g. "1 easy 1 fast").
 *
 * Priority:
 *   1. Explicit per-rep block detected in the input string (highest fidelity)
 *   2. Descend/build/negative_split → gradient pattern
 *   3. Single intensity type → fill all reps
 *   4. No intensity → fill with 'moderate' (safest default)
 */
export function buildIntensityPattern(
  reps: number,
  intensity: ParsedIntensity | null,
  repBlock: IntensityLevel[] | null,
): IntensityLevel[] {
  // 1. Explicit block — cycle to fill reps
  if (repBlock && repBlock.length > 0) {
    return Array.from({ length: reps }, (_, i) => repBlock[i % repBlock.length])
  }

  if (!intensity) {
    return Array(reps).fill('moderate')
  }

  // 2. Gradient patterns
  if (intensity.type === 'descend') {
    return buildGradient(['easy', 'moderate', 'hard', 'race'], reps)
  }
  if (intensity.type === 'build') {
    return buildGradient(['easy', 'moderate', 'hard', 'race'], reps)
  }
  if (intensity.type === 'negative_split') {
    // First half moderate, second half hard
    return Array.from({ length: reps }, (_, i) =>
      i < Math.ceil(reps / 2) ? 'moderate' : 'hard'
    )
  }

  // 3. Single level — fill all reps
  const level = intensityTypeToLevel(intensity.type)
  return Array(reps).fill(level)
}

function buildGradient(template: IntensityLevel[], reps: number): IntensityLevel[] {
  if (reps === 1) return [template[Math.floor(template.length / 2)]]
  return Array.from({ length: reps }, (_, i) =>
    template[Math.round((i / (reps - 1)) * (template.length - 1))]
  )
}

// ─── Main parser ──────────────────────────────────────────────────────────────

export function parseSet(input: string): ParsedSet {
  if (!input.trim()) {
    return { reps: null, distance: null, stroke: null, interval: null, intensity: null, intensityPattern: [] }
  }

  const normalized = normalizeInput(input)

  let reps: number | null = null
  let distance: number | null = null

  // Pattern 1: "4 x 50" / "4 by 50" / "4×50" / "4-50"
  const repDistMatch = normalized.match(/(\d+)\s*(?:x|×|by|-)\s*(\d+)/)
  if (repDistMatch) {
    const a = parseInt(repDistMatch[1])
    const b = parseInt(repDistMatch[2])
    if (SWIM_DISTANCES.has(b) && !SWIM_DISTANCES.has(a)) {
      reps = a; distance = b
    } else if (SWIM_DISTANCES.has(a) && !SWIM_DISTANCES.has(b)) {
      distance = a; reps = b
    } else if (SWIM_DISTANCES.has(b)) {
      reps = a; distance = b
    } else {
      reps = Math.min(a, b); distance = Math.max(a, b)
    }
  }

  // Pattern 2: "4 50s" — e.g. "four 50s free"
  if (!reps || !distance) {
    const pluralMatch = normalized.match(/(\d+)\s+(\d+)s\b/)
    if (pluralMatch) {
      const a = parseInt(pluralMatch[1])
      const b = parseInt(pluralMatch[2])
      if (SWIM_DISTANCES.has(b)) {
        reps = reps ?? a
        distance = distance ?? b
      }
    }
  }

  // Pattern 3: isolated number scan
  if (!distance || !reps) {
    // Exclude numbers that look like pace targets ("200 pace", "400 pace")
    // so they don't get mistaken for reps/distance
    const paceTokens = new Set<number>()
    for (const m of normalized.matchAll(/(\d+)\s*m?\s+pace\b/g)) {
      paceTokens.add(parseInt(m[1]))
    }

    const allNums = [...normalized.matchAll(/\b(\d+)\b/g)]
      .map(m => parseInt(m[1]))
      .filter(n => n > 0 && !paceTokens.has(n))

    if (!distance) {
      const distCandidates = allNums.filter(n => SWIM_DISTANCES.has(n))
      if (distCandidates.length > 0) distance = distCandidates[0]
    }
    if (!reps) {
      const repCandidates = allNums.filter(n => !SWIM_DISTANCES.has(n) && n >= 1 && n <= 64)
      if (repCandidates.length > 0) reps = repCandidates[0]
    }
  }

  // Stroke
  let stroke: Stroke | null = null
  for (const [pattern, s] of STROKE_PATTERNS) {
    if (pattern.test(input)) { stroke = s; break }
  }

  // Interval
  const interval = parseInterval(normalized)

  // Check for per-rep block first ("1 easy 1 fast") — strip it from the string
  // so it doesn't confuse the single-intensity parser
  let repBlock: IntensityLevel[] | null = null
  let intensityInput = input

  // Try to find a "N word N word" block by scanning the normalized remainder
  // (after removing NxM, stroke aliases, interval, and stroke keywords)
  const cleanedForBlock = normalized
    .replace(/^\d+\s*[x×by-]\s*\d+/, '')
    .replace(/@[\d:]+/, '')
    .replace(/\b(?:free|freestyle|back|backstroke|breast|breaststroke|fly|butterfly|im|medley|form)\b/gi, '')
    .trim()
  const blockCandidate = parseRepBlock(cleanedForBlock)
  if (blockCandidate) {
    repBlock = blockCandidate
    // Mask it so single-intensity parser doesn't double-fire on "fast"
    intensityInput = input.replace(/\d+\s+\w+/g, '').trim()
  }

  // Intensity (single type — used for display and DB, not for per-rep algorithm)
  const intensity = parseIntensity(intensityInput, normalizeInput(intensityInput))

  // Per-rep pattern for the algorithm
  const intensityPattern = reps != null
    ? buildIntensityPattern(reps, intensity, repBlock)
    : []

  return { reps, distance, stroke, interval, intensity, intensityPattern }
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

export function isSetReadyToSubmit(parsed: ParsedSet): boolean {
  return parsed.reps !== null && parsed.distance !== null
}

export function formatParsedSet(parsed: ParsedSet): string {
  const parts: string[] = []
  if (parsed.reps !== null && parsed.distance !== null) {
    parts.push(`${parsed.reps} × ${parsed.distance}m`)
  } else if (parsed.distance !== null) {
    parts.push(`${parsed.distance}m`)
  }
  if (parsed.stroke) parts.push(parsed.stroke)
  if (parsed.intensity) parts.push(`@ ${parsed.intensity.label}`)
  else if (parsed.intensityPattern.length > 0) parts.push(`@ ${summarisePattern(parsed.intensityPattern)}`)
  if (parsed.interval) parts.push(`on ${parsed.interval}`)
  return parts.join(' ') || '—'
}

/** Summarise an intensity pattern for display. */
export function summarisePattern(pattern: IntensityLevel[]): string {
  if (pattern.length === 0) return ''
  if (pattern.every(p => p === pattern[0])) return pattern[0]
  // Detect repeating cycle
  for (let len = 1; len <= Math.floor(pattern.length / 2); len++) {
    const unit = pattern.slice(0, len)
    if (pattern.every((v, i) => v === unit[i % len])) {
      return unit.join(' / ')
    }
  }
  // Descending?
  const desc = buildGradient(['easy', 'moderate', 'hard', 'race'], pattern.length)
  if (pattern.join() === desc.join()) return 'desc'
  return pattern.join(' → ')
}

/** Badge color for intensity type — used in chip UI */
export function intensityColor(type: IntensityType): string {
  switch (type) {
    case 'easy':          return '#34C759' // green
    case 'aerobic':       return '#30D158' // green
    case 'threshold':     return '#FF9500' // orange
    case 'race_pace':     return '#FF3B30' // red
    case 'pace_target':   return '#007AFF' // blue
    case 'sprint':        return '#FF2D55' // pink/red
    case 'descend':       return '#5856D6' // purple
    case 'build':         return '#AF52DE' // purple
    case 'negative_split':return '#5AC8FA' // light blue
  }
}
