// ─── Core types ─────────────────────────────────────────────────────────────

export type Stroke = 'Free' | 'Back' | 'Breast' | 'Fly' | 'IM' | 'Form'

export type GearType = 'paddles' | 'pull_buoy' | 'fins' | 'kickboard' | 'dragSuit'

export type IntensityLevel = 'easy' | 'moderate' | 'hard' | 'race'

export type DataSource = 'recorded' | 'curve' | 'seed'

// ─── Swimmer ─────────────────────────────────────────────────────────────────

export interface Swimmer {
  id: string
  /** For "Form" stroke resolution */
  formStroke: Stroke | null
}

// ─── Stats store (Layer 1: recorded training data) ───────────────────────────

export interface StatsRecord {
  meanTimeMs: number
  stddevMs: number
  sampleCount: number
}

// ─── PB store (Layer 2: personal bests → speed curve) ───────────────────────

export interface PB {
  distance: number
  pbMs: number
}

// ─── Prediction ──────────────────────────────────────────────────────────────

export interface Prediction {
  /** Where the expected time came from */
  source: DataSource
  /** Expected mean time for this swimmer in this context (ms) */
  expectedTimeMs: number
  /** Stddev for this swimmer in this context (ms) */
  stddevMs: number
  /** Number of samples that informed this prediction */
  sampleCount: number
  /** Gear multiplier applied (1.0 = no gear) */
  gearMultiplier: number
  /** Intensity multiplier applied (1.0 = race) */
  intensityMultiplier: number
}

// ─── Ranked swimmer ─────────────────────────────────────────────────────────

export interface RankedSwimmer {
  swimmerId: string
  expectedTimeMs: number
  stddevMs: number
  zScore: number
  source: DataSource
  /** How much closer this swimmer is vs the runner-up (runnerUpError / winnerError) */
  marginRatio: number | null // null when only one swimmer
  /** Raw error in ms: |lapTime - expected| */
  errorMs: number
  /** Error in seconds (human readable) */
  errorSec: number
  /** Lap is suspicious: all residuals > threshold (e.g. 4s) */
  suspicious: boolean
}

// ─── Lap result ─────────────────────────────────────────────────────────────

export interface LapResult {
  lapTimeMs: number
  rankedSwimmers: RankedSwimmer[]
}

// ─── Set context ─────────────────────────────────────────────────────────────

export interface SetContext {
  distance: number
  stroke: Stroke
  intensity: IntensityLevel
  gear: GearType | null
}

// ─── Pool context ────────────────────────────────────────────────────────────

export interface PoolContext {
  swimmers: Swimmer[]
  statsStore: StatsStore
  pbStore: PBStore
  gearCalStore?: GearCalibrationStore
  context: SetContext
}

// ─── Gear calibration ─────────────────────────────────────────────────────────

export interface GearCalibration {
  swimmerId: string
  gear: GearType
  /** e.g. 1.08 = 8% slower with this gear than bare hand */
  adjustmentFactor: number
  sampleCount: number
}

// ─── Gear calibration store ──────────────────────────────────────────────────

export class GearCalibrationStore {
  private map = new Map<string, GearCalibration>()

  add(cal: GearCalibration): void {
    this.map.set(`${cal.swimmerId}:${cal.gear}`, cal)
  }

  get(swimmerId: string, gear: GearType): GearCalibration | undefined {
    return this.map.get(`${swimmerId}:${gear}`)
  }

  effectiveMultiplier(swimmerId: string, gear: GearType | null): number {
    if (!gear) return 1.0
    return this.get(swimmerId, gear)?.adjustmentFactor ?? GEAR_PENALTIES[gear] ?? 1.0
  }
}

// ─── Stats store ─────────────────────────────────────────────────────────────

export class StatsStore {
  private map = new Map<string, StatsRecord>()

  set(swimmerId: string, stroke: Stroke, distance: number, intensity: IntensityLevel, gear: GearType | null, record: StatsRecord): void {
    this.map.set(key(swimmerId, stroke, distance, intensity, gear), record)
  }

  get(swimmerId: string, stroke: Stroke, distance: number, intensity: IntensityLevel, gear: GearType | null): StatsRecord | undefined {
    // Exact match
    return this.map.get(key(swimmerId, stroke, distance, intensity, gear))
    // Fallback: try bare hand (no gear)
    ?? this.map.get(key(swimmerId, stroke, distance, intensity, null))
  }

  has(swimmerId: string, stroke: Stroke, distance: number, intensity: IntensityLevel, gear: GearType | null): boolean {
    return this.get(swimmerId, stroke, distance, intensity, gear) !== undefined
  }
}

// ─── PB store ────────────────────────────────────────────────────────────────

export class PBStore {
  private map = new Map<string, PB[]>()

  set(swimmerId: string, stroke: Stroke, pbs: PB[]): void {
    this.map.set(`${swimmerId}:${stroke}`, [...pbs].sort((a, b) => a.distance - b.distance))
  }

  get(swimmerId: string, stroke: Stroke): PB[] {
    return this.map.get(`${swimmerId}:${stroke}`) ?? []
  }

  has(swimmerId: string, stroke: Stroke): boolean {
    return this.map.has(`${swimmerId}:${stroke}`)
  }
}

// ─── Key helper ──────────────────────────────────────────────────────────────

function key(swimmerId: string, stroke: Stroke, distance: number, intensity: IntensityLevel, gear: GearType | null): string {
  return `${swimmerId}:${stroke}:${distance}:${intensity}:${gear ?? 'bare'}`
}