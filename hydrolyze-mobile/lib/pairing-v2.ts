/**
 * Prediction pipeline — Layer 1 → 2 → 3 lookup.
 * Core pairing engine for Hydrolyze.
 *
 * For a swimmer + set context, find the best available prediction of their
 * expected time and variance. Priority:
 *   Layer 1: recorded stats (real training data — best quality)
 *   Layer 2: speed curve from PBs (estimated)
 *   Layer 3: population average (cold start — low quality)
 */

import { INTENSITY_MULTIPLIERS } from "./set-parser";
import type { IntensityLevel } from "./set-parser";

// ─── Shared types (also used by ml-pairing.ts) ──────────────────────────────

export type Stroke =
  | "Free"
  | "Back"
  | "Breast"
  | "Fly"
  | "IM"
  | "Form"
  | "Pull"
  | "Choice";

export interface Swimmer {
  id: string;
  name: string;
  form_stroke: Stroke | null;
}

export interface SwimmerStats {
  mean_time_ms: number;
  stddev_time_ms: number;
  sample_count: number;
  is_estimated: boolean;
  assignmentSource: AssignmentSource;
  pb_predicted_ms?: number;
  intensityMultipliers?: Partial<Record<IntensityLevel, number>>;
}

export type StatsCache = Record<string, SwimmerStats>;

// ─── Data source labels ─────────────────────────────────────────────────────────

export type AssignmentSource = "recorded" | "curve" | "seed" | "no_data";

export type DataSource = AssignmentSource;

// ─── Population defaults (cold start) ─────────────────────────────────────────

const POPULATION_SPEEDS: Record<string, number> = {
  Free: 1.45,
  Back: 1.35,
  Breast: 1.3,
  Fly: 1.38,
  IM: 1.35,
  Form: 1.45,
};
const INTENSITY_MULT: Record<IntensityLevel, number> = {
  easy: 1.25,
  moderate: 1.1,
  hard: 1.03,
  race: 1.0,
};
const STDDEV_FRACTION: Record<string, number> = {
  "25": 0.03,
  "50": 0.05,
  "100": 0.06,
  "200": 0.08,
  "400": 0.1,
  "800": 0.12,
  "1500": 0.15,
};

// ─── Prediction ────────────────────────────────────────────────────────────────

export interface Prediction {
  source: DataSource;
  expectedTimeMs: number;
  stddevMs: number;
  sampleCount: number;
  gearMultiplier: number;
  intensityMultiplier: number;
}

function populationSeed(
  stroke: string,
  distance: number,
  intensity: IntensityLevel,
): Prediction {
  const speedMps = POPULATION_SPEEDS[stroke] ?? 1.35;
  const racePaceMs = (distance / speedMps) * 1000;
  const intMult = INTENSITY_MULT[intensity] ?? 1.1;
  const stddevFrac = STDDEV_FRACTION[String(distance)] ?? 0.1;
  return {
    source: "seed",
    expectedTimeMs: Math.round(racePaceMs * intMult),
    stddevMs: Math.max(racePaceMs * stddevFrac, 200),
    sampleCount: 1,
    gearMultiplier: 1.0,
    intensityMultiplier: intMult,
  };
}

// ─── Gear multiplier (universal factors — cold start) ────────────────────────

const GEAR_PENALTIES: Record<string, number> = {
  paddles: 1.05,
  pull_buoy: 1.03,
  fins: 0.88,
  kickboard: 1.04,
  dragSuit: 1.1,
};
function gearMult(gear: string | null): number {
  return gear ? (GEAR_PENALTIES[gear] ?? 1.0) : 1.0;
}

// ─── Speed curve from PBs (Layer 2) ──────────────────────────────────────

const DEFAULT_B = -0.165;

function fitAndPredict(
  pbs: { distance: number; pbMs: number }[],
  distance: number,
): { timeMs: number; b: number } | null {
  const valid = pbs.filter(
    (p) => p.distance > 0 && p.pbMs > 0 && p.pbMs < 3_600_000,
  );
  if (valid.length === 0) return null;

  if (valid.length === 1) {
    const speed = (valid[0].distance / valid[0].pbMs) * 1000;
    const a = Math.log(speed) - DEFAULT_B * Math.log(valid[0].distance);
    const predSpeed = Math.exp(a + DEFAULT_B * Math.log(distance));
    return { timeMs: Math.round((distance / predSpeed) * 1000), b: DEFAULT_B };
  }

  // OLS in log-log space
  const xs = valid.map((p) => Math.log(p.distance));
  const ys = valid.map((p) => Math.log((p.distance / p.pbMs) * 1000));
  const n = xs.length;
  const xMean = xs.reduce((s, x) => s + x, 0) / n;
  const yMean = ys.reduce((s, y) => s + y, 0) / n;
  const SSxx = xs.reduce((s, x) => s + (x - xMean) ** 2, 0);
  const SSxy = xs.reduce((s, x, i) => s + (x - xMean) * (ys[i] - yMean), 0);
  if (SSxx === 0 || SSxy / SSxx >= 0) {
    const speed = (valid[0].distance / valid[0].pbMs) * 1000;
    const a = Math.log(speed) - DEFAULT_B * Math.log(valid[0].distance);
    const predSpeed = Math.exp(a + DEFAULT_B * Math.log(distance));
    return { timeMs: Math.round((distance / predSpeed) * 1000), b: DEFAULT_B };
  }
  const b = SSxy / SSxx;
  const a = yMean - b * xMean;
  const predSpeed = Math.exp(a + b * Math.log(distance));
  const timeMs = Math.round((distance / predSpeed) * 1000);
  if (timeMs < 20_000 || timeMs > 5_400_000) return null;
  return { timeMs, b };
}

export interface PBRecord {
  distance: number;
  pbMs: number;
}

// ─── Main predict function (Layer 1 → 2 → 3) ────────────────────────────────

export interface RecordedStats {
  meanTimeMs: number;
  stddevMs: number;
  sampleCount: number;
}

/**
 * Predict expected time + stddev for a swimmer in a specific set context.
 *
 * Priority:
 *   1. recordedStats → apply gear multiplier only (intensity already baked in)
 *   2. pbs → fit speed curve, apply gear + intensity
 *   3. population → universal cold-start estimate
 */
export function predict(
  recordedStats: RecordedStats | null,
  pbs: PBRecord[],
  stroke: string,
  distance: number,
  intensity: IntensityLevel,
  gear: string | null,
): Prediction {
  const gm = gearMult(gear);
  const intMult = INTENSITY_MULT[intensity] ?? 1.1;

  // Layer 1: recorded training stats
  if (recordedStats) {
    return {
      source: "recorded",
      expectedTimeMs: Math.round(recordedStats.meanTimeMs * gm),
      stddevMs: Math.max(recordedStats.stddevMs * gm, 100),
      sampleCount: recordedStats.sampleCount,
      gearMultiplier: gm,
      intensityMultiplier: 1.0,
    };
  }

  // Layer 2: speed curve from PBs
  if (pbs.length > 0) {
    const result = fitAndPredict(pbs, distance);
    if (result) {
      const sdFrac = STDDEV_FRACTION[String(distance)] ?? 0.1;
      return {
        source: "curve",
        expectedTimeMs: Math.round(result.timeMs * intMult * gm),
        stddevMs: Math.max(result.timeMs * sdFrac, 100),
        sampleCount: pbs.length,
        gearMultiplier: gm,
        intensityMultiplier: intMult,
      };
    }
  }

  // Layer 3: population average
  return populationSeed(stroke, distance, intensity);
}

// ─── Data maturity tiers ────────────────────────────────────────────────────

export type MaturityTier =
  | "none"
  | "seed"
  | "curve"
  | "learning"
  | "reliable"
  | "excellent";

export function maturityTier(
  recordedCount: number,
  hasPB: boolean,
): MaturityTier {
  if (recordedCount >= 16) return "excellent";
  if (recordedCount >= 6) return "reliable";
  if (recordedCount >= 1) return "learning";
  if (hasPB) return "curve";
  return "seed";
}

export function maturityLabel(
  tier: MaturityTier,
  recordedCount: number,
): string {
  switch (tier) {
    case "none":
      return "No data — estimating from population";
    case "seed":
      return "No data — estimating from population";
    case "curve":
      return "Based on PB estimate";
    case "learning":
      return `${recordedCount} times recorded — learning`;
    case "reliable":
      return `${recordedCount} times recorded — reliable`;
    case "excellent":
      return `${recordedCount} times recorded — excellent`;
  }
}

export function maturityColor(tier: MaturityTier): string {
  switch (tier) {
    case "excellent":
      return "#16a34a";
    case "reliable":
      return "#22c55e";
    case "learning":
      return "#86efac";
    case "curve":
      return "#eab308";
    case "seed":
      return "#9ca3af";
    case "none":
      return "#6b7280";
  }
}

// ─── Ranking ───────────────────────────────────────────────────────────────

export interface RankedSwimmer {
  swimmerId: string;
  swimmerName: string;
  expectedTimeMs: number;
  stddevMs: number;
  errorMs: number;
  errorSec: number;
  zScore: number;
  source: DataSource;
  /** Lap is suspicious: best residual > 4s */
  suspicious: boolean;
  /** runnerUp error / winner error (null when errorMs=0) */
  marginRatio: number | null;
}

/**
 * Rank swimmers by likelihood for a single lap time.
 * Algorithm: residual = |lapTime − expected|. Sort ascending. Lower = most likely.
 *
 * @param lapTimeMs    Raw tap time (ms)
 * @param swimmers     Pool of swimmers present
 * @param stroke      Stroke key (e.g. 'Free')
 * @param distance     Distance in metres
 * @param intensity    Effort level
 * @param gear         Gear type (or null)
 * @param getPrediction fn(swimmerId): Prediction | null
 * @param thresholdMs  Flag lap suspicious if best residual > this (default 4000ms)
 */
export function rankLap(
  lapTimeMs: number,
  swimmers: Swimmer[],
  stroke: string,
  distance: number,
  intensity: IntensityLevel,
  gear: string | null,
  getPrediction: (swimmerId: string) => Prediction | null,
  thresholdMs = 4000,
): RankedSwimmer[] {
  if (swimmers.length === 0) return [];
  if (stroke === "IM") return [];

  const effectiveStroke = (s: Swimmer) =>
    stroke === "Form" ? (s.form_stroke ?? "Free") : stroke;

  const withR = swimmers.map((sw) => {
    const pred = getPrediction(sw.id);
    if (!pred) {
      return {
        swimmerId: sw.id,
        swimmerName: sw.name,
        errorMs: Infinity,
        errorSec: Infinity,
        zScore: Infinity,
        expectedTimeMs: 0,
        stddevMs: 0,
        source: "seed" as DataSource,
      };
    }
    const stddev =
      pred.stddevMs > 0
        ? pred.stddevMs
        : Math.max(pred.expectedTimeMs * 0.1, 100);
    const errorMs = Math.abs(lapTimeMs - pred.expectedTimeMs);
    return {
      swimmerId: sw.id,
      swimmerName: sw.name,
      errorMs,
      errorSec: errorMs / 1000,
      zScore: errorMs / stddev,
      expectedTimeMs: pred.expectedTimeMs,
      stddevMs: pred.stddevMs,
      source: pred.source,
    };
  });

  withR.sort((a, b) => a.errorMs - b.errorMs);

  const bestErrorMs = withR[0]?.errorMs ?? Infinity;
  const suspicious = bestErrorMs > thresholdMs;

  return withR.map((item, i) => ({
    ...item,
    suspicious,
    marginRatio:
      i < withR.length - 1 && item.errorMs > 0
        ? withR[i + 1].errorMs / item.errorMs
        : null,
  }));
}
