/**
 * Main pairing function — combines prediction pipeline with confidence scoring.
 *
 * Takes a lap time and a pool of swimmers, returns a ranked list of candidates
 * with confidence scores, plus the winning assignment.
 *
 * This is the only function the app integration layer needs to call.
 */

import type {
  SwimmerWithForm,
  LapEvent,
  SwimmerPrediction,
  PairingResult,
  CandidateResult,
} from './types.js'
import { StatsStore, PBStore, GearCalibrationStore, predictPool } from './prediction.js'
import { scoreConfidence } from './confidence.js'

// ─── Input to a pairing run ────────────────────────────────────────────────────

export interface PoolContext {
  swimmers: SwimmerWithForm[]
  /** Recorded stats (Layer 1). Initialize from swimmer_stats table. */
  statsStore: StatsStore
  /** PB records (Layer 2). Initialize from swimmer_pbs table. */
  pbStore: PBStore
  /** Per-swimmer gear calibrations. */
  gearCalStore?: GearCalibrationStore
}

// ─── Main pairing function ─────────────────────────────────────────────────────

/**
 * Assign a lap time to the most likely swimmer in the pool.
 *
 * @param lap         Lap event: time, distance, stroke, intensity, gear
 * @param context     Pool context: swimmers + data stores
 * @returns Full pairing result with winner, all candidates ranked, diagnostics
 */
export function pairLap(
  lap: LapEvent,
  context: PoolContext,
): PairingResult {
  const { swimmers, statsStore, pbStore } = context
  const gearCalStore = context.gearCalStore ?? new GearCalibrationStore()

  // IM is always manual — no pairing possible
  if (lap.stroke === 'IM') {
    return makeNullResult(lap.timeMs, swimmers.map(s => s.id))
  }

  if (swimmers.length === 0) {
    return makeNullResult(lap.timeMs, [])
  }

  // ── Step 1: Run prediction pipeline for all swimmers ─────────────────────────
  const predictions = predictPool(
    swimmers,
    lap.setDistance,
    lap.stroke,
    lap.intensity,
    lap.gear,
    statsStore,
    pbStore,
    gearCalStore,
  )

  // ── Step 2: Compute z-scores for all swimmers ─────────────────────────────────
  interface Candidate {
    swimmerId: string
    prediction: SwimmerPrediction
    zScore: number
  }
  const candidates: Candidate[] = []

  for (const swimmer of swimmers) {
    const pred = predictions[swimmer.id]
    if (!pred) continue
    if (pred.statsType === 'no_data') continue

    const stddev = pred.stddevMs > 0 ? pred.stddevMs : Math.max(pred.meanTimeMs * 0.1, 100)
    const zScore = Math.abs(lap.timeMs - pred.meanTimeMs) / stddev

    candidates.push({ swimmerId: swimmer.id, prediction: pred, zScore })
  }

  // Sort by z-score ascending (lowest z = closest to mean = most likely)
  candidates.sort((a, b) => a.zScore - b.zScore)

  const unassignable = swimmers
    .map(s => s.id)
    .filter(id => !candidates.find(c => c.swimmerId === id))

  // No assignable swimmers → return first with no_data
  if (candidates.length === 0) {
    return {
      winnerId: swimmers[0].id,
      confidence: 0,
      statsType: 'no_data',
      zScore: Infinity,
      poolDistinctiveness: 1,
      allCandidates: [],
      unassignable: swimmers.map(s => s.id),
      diagnostic: makeDiagnostic(lap.timeMs, candidates, candidates[0]?.zScore ?? Infinity),
    }
  }

  const winner = candidates[0]
  const runnerUp = candidates[1]
  const runnerUpZ = runnerUp?.zScore ?? Infinity
  const maxZ = Math.max(...candidates.map(c => c.zScore))

  // ── Step 3: Score confidence ──────────────────────────────────────────────────
  const winnerConfidence = scoreConfidence(
    winner.zScore,
    runnerUpZ,
    maxZ,
    winner.prediction.confidenceCeiling,
  )

  // ── Step 4: Score all candidates ────────────────────────────────────────────
  const allCandidates: CandidateResult[] = candidates.map((c, i) => {
    const nextZ = candidates[i + 1]?.zScore ?? Infinity
    const conf = scoreConfidence(c.zScore, nextZ, maxZ, c.prediction.confidenceCeiling)
    return {
      swimmerId: c.swimmerId,
      zScore: c.zScore,
      confidence: conf,
      statsType: c.prediction.statsType,
      gearPenalty: c.prediction.gearPenalty,
      sourceLabel: c.prediction.sourceLabel,
      meanTimeMs: c.prediction.meanTimeMs,
      stddevMs: c.prediction.stddevMs,
    }
  })

  const poolDistinctiveness = runnerUpZ === Infinity ? 1 : runnerUpZ / winner.zScore

  return {
    winnerId: winner.swimmerId,
    confidence: winnerConfidence,
    statsType: winner.prediction.statsType,
    zScore: winner.zScore,
    poolDistinctiveness,
    allCandidates,
    unassignable,
    diagnostic: makeDiagnostic(lap.timeMs, candidates, winner.zScore, runnerUpZ, maxZ),
  }
}

// ─── Helpers ───────────────────────────────────────────────────────────────────

function makeNullResult(lapMs: number, swimmerIds: string[]): PairingResult {
  return {
    winnerId: null,
    confidence: 0,
    statsType: 'no_data',
    zScore: Infinity,
    poolDistinctiveness: 1,
    allCandidates: [],
    unassignable: swimmerIds,
    diagnostic: makeDiagnostic(lapMs, [], Infinity),
  }
}

function makeDiagnostic(
  lapMs: number,
  candidates: { swimmerId: string; zScore: number; prediction: SwimmerPrediction }[],
  winnerZ: number,
  runnerUpZ?: number,
  maxZ?: number,
) {
  const allZs = candidates.map(c => ({
    swimmerId: c.swimmerId,
    zScore: c.zScore,
    confidence: 0, // filled by caller
  }))
  return {
    lapMs,
    poolDistinctiveness: runnerUpZ !== undefined ? (runnerUpZ === Infinity ? 1 : runnerUpZ / winnerZ) : 1,
    winnerZ,
    runnerUpZ: runnerUpZ ?? Infinity,
    maxZ: maxZ ?? winnerZ,
    winnerMeanMs: candidates[0]?.prediction.meanTimeMs ?? 0,
    winnerStddevMs: candidates[0]?.prediction.stddevMs ?? 0,
    winnerGearPenalty: candidates[0]?.prediction.gearPenalty ?? 1,
    allZs,
  }
}