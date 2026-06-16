// ─── Stroke & Gear types ──────────────────────────────────────────────────────

export type Stroke = 'Free' | 'Back' | 'Breast' | 'Fly' | 'IM' | 'Form'

export type GearType = 'paddles' | 'pull_buoy' | 'fins' | 'kickboard' | 'dragSuit'

export type IntensityLevel = 'easy' | 'moderate' | 'hard' | 'race'

// ─── Swimmer pool (internal to pairing engine) ──────────────────────────────

export interface SwimmerWithForm {
  id: string
  formStroke: Stroke | null
}

// ─── Speed curve (from swimmer_pbs power-law fit) ────────────────────────────

export interface CurvePB {
  distance: number // metres
  pbMs: number     // milliseconds
}

export interface SpeedCurve {
  a: number
  b: number
  pbDistances: number[]
  fitMethod: 'regression' | 'single_pb_fixed_slope'
}

// ─── Swimmer stats (from swimmer_stats table) ─────────────────────────────────

export interface SwimmerStatsRecord {
  meanTimeMs: number
  stddevMs: number
  sampleCount: number
}

// ─── Gear calibration (per-swimmer adjustments) ──────────────────────────────

export interface GearCalibration {
  swimmerId: string
  gear: GearType
  adjustmentFactor: number // multiplier applied to bare-hand mean
  sampleCount: number
  computedAt: string // ISO date
}

// ─── The core prediction object ─────────────────────────────────────────────

export interface SwimmerPrediction {
  /** Source of this prediction — drives the confidence ceiling */
  statsType: 'recorded' | 'curve' | 'seed' | 'no_data'
  /** Effective mean time for this swimmer in this context */
  meanTimeMs: number
  /** Standard deviation of the swimmer's training times in this context */
  stddevMs: number
  /** Number of samples used (real for recorded, projected for curve/seed) */
  sampleCount: number
  /** Human-readable description of where this prediction came from */
  sourceLabel: string
  /** Gear penalty multiplier applied (1.0 = none) */
  gearPenalty: number
  /** Fitted speed curve (present only when statsType === 'curve') */
  curve?: SpeedCurve
  /** Maximum confidence allowed for this prediction source */
  confidenceCeiling: number
}

// ─── Lap event ────────────────────────────────────────────────────────────────

export interface LapEvent {
  timeMs: number
  setDistance: number
  stroke: Stroke
  intensity: IntensityLevel
  gear: GearType | null
}

// ─── Assignment output ────────────────────────────────────────────────────────

export interface CandidateResult {
  swimmerId: string
  zScore: number
  confidence: number
  statsType: SwimmerPrediction['statsType']
  gearPenalty: number
  sourceLabel: string
  meanTimeMs: number
  stddevMs: number
}

export interface PairingResult {
  /** The swimmer assigned to this lap */
  winnerId: string | null
  /** 0–100 continuous confidence score */
  confidence: number
  /** Where the winner's prediction came from */
  statsType: SwimmerPrediction['statsType']
  /** z-score of the winner */
  zScore: number
  /** runnerUpZ / winnerZ ratio — how clear the win was */
  poolDistinctiveness: number
  /** All candidates ranked by confidence (winner is index 0) */
  allCandidates: CandidateResult[]
  /** SwimmerIds with no data at all (unassignable) */
  unassignable: string[]
  /** Full diagnostic for debugging */
  diagnostic: {
    lapMs: number
    poolDistinctiveness: number
    winnerZ: number
    runnerUpZ: number
    maxZ: number
    winnerMeanMs: number
    winnerStddevMs: number
    winnerGearPenalty: number
    allZs: { swimmerId: string; zScore: number; confidence: number }[]
  }
}

// ─── Confidence trace (debug output) ─────────────────────────────────────────

export interface ConfidenceTrace {
  winnerZ: number
  runnerUpZ: number
  maxZ: number
  positional: number
  marginFactor: number
  outlierBonus: number
  regime: 'normal' | 'extreme'
  raw: number
  ceiling: number
  final: number
}