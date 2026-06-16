/**
 * Continuous confidence scoring based on probability theory.
 *
 * Model: Two competing signals drive confidence:
 *   1. Positional — how close is the lap to the swimmer's mean? (Gaussian)
 *   2. Distinctive — how unlikely is this time for the WHOLE POOL? (outlier signal)
 *
 * Formula:
 *   if (winnerZ > 5) {
 *     // Extreme outlier: distinctive, not uncertain.
 *     // confidence = scale(winnerZ, 5→0%, 35→90%) * ceiling
 *     // = (winnerZ - 5) / 30 * 0.9 * ceiling
 *   } else {
 *     // Normal range: Gaussian positional * margin factor
 *     confidence = positional(z) * (0.5 + 0.5 * marginFactor)
 *   }
 *
 * Plus outlier bonus (+10) when maxZ > 3 (pool has an extreme swimmer).
 * Result always capped at confidenceCeiling.
 */

import type { ConfidenceTrace } from './types.js'

/** Gaussian probability density → percentage [0, 100] */
export function positionalScore(z: number): number {
  return Math.exp(-0.5 * z * z) * 100
}

/**
 * Margin factor: how much better is the winner than the runner-up?
 * 0.0 = tied, 1.0 = large gap (runner-up 2× further from mean)
 */
export function computeMarginFactor(winnerZ: number, runnerUpZ: number): number {
  if (runnerUpZ <= winnerZ) return 0
  return Math.min(1, Math.max(0, (runnerUpZ / winnerZ - 1.0) / 1.5))
}

/** Outlier bonus when the pool contains extreme swimmers */
export function computeOutlierBonus(maxZInPool: number): number {
  if (maxZInPool > 5) return 15
  if (maxZInPool > 3) return 10
  return 0
}

/**
 * Compute final confidence score for a winner swimmer.
 *
 * @param winnerZ         z-score of the winner swimmer
 * @param runnerUpZ       z-score of the runner-up swimmer (Infinity if only 1 swimmer)
 * @param maxZInPool      Maximum z-score in the pool
 * @param ceiling         Maximum confidence allowed (from prediction source)
 */
export function scoreConfidence(
  winnerZ: number,
  runnerUpZ: number,
  maxZInPool: number,
  ceiling: number,
): number {
  if (winnerZ === 0) return Math.min(ceiling, 100)
  if (ceiling === 0) return 0

  let confidence: number

  // Extreme regime: the formula gives 0→90% directly from z-score.
  // The outlier bonus does NOT apply here — the formula already accounts
  // for the distinctive nature of extreme times.
  if (winnerZ > 5) {
    confidence = ((winnerZ - 5) / 30) * 90
  } else {
    // Normal range: Gaussian positional * (0.5 + 0.5 * margin)
    const positional = positionalScore(winnerZ)
    const marginFactor = computeMarginFactor(winnerZ, runnerUpZ)
    confidence = positional * (0.5 + 0.5 * marginFactor)
  }

  // Outlier bonus: pool has extreme swimmers → distinctive time identification
  confidence += computeOutlierBonus(maxZInPool)

  return Math.round(Math.min(ceiling, Math.max(0, confidence)))
}

// ─── Band labels (for display) ────────────────────────────────────────────────

export type ConfidenceBand = 'certain' | 'high' | 'medium' | 'low' | 'none'

export function confidenceBand(confidence: number): ConfidenceBand {
  if (confidence >= 90) return 'certain'
  if (confidence >= 70) return 'high'
  if (confidence >= 50) return 'medium'
  if (confidence > 0)   return 'low'
  return 'none'
}

export function confidenceLabel(confidence: number): string {
  switch (confidenceBand(confidence)) {
    case 'certain': return 'certain'
    case 'high':    return 'high confidence'
    case 'medium':  return 'medium confidence'
    case 'low':     return 'low confidence'
    case 'none':    return 'manual assignment required'
  }
}

// ─── Debug trace ───────────────────────────────────────────────────────────────

export function traceConfidence(winnerZ: number, runnerUpZ: number, maxZ: number, ceiling: number): ConfidenceTrace {
  const positional = positionalScore(winnerZ)
  const marginFactor = computeMarginFactor(winnerZ, runnerUpZ)
  const outlierBonus = computeOutlierBonus(maxZ)

  let confidence: number
  let regime: 'normal' | 'extreme'
  if (winnerZ > 5) {
    confidence = ((winnerZ - 5) / 30) * 90
    regime = 'extreme'
  } else {
    confidence = positional * (0.5 + 0.5 * marginFactor)
    regime = 'normal'
  }

  confidence += outlierBonus
  const final = Math.round(Math.min(ceiling, Math.max(0, confidence)))

  return {
    winnerZ,
    runnerUpZ,
    maxZ,
    positional,
    marginFactor,
    outlierBonus,
    regime,
    raw: confidence,
    ceiling,
    final,
  }
}