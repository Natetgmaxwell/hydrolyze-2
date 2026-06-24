/**
 * Workout Parser V2 — Type Definitions
 *
 * 5-level hierarchy: Workout → Section → NamedSet → RepGroup → Rep
 * Aligns with Designer's spec for real-world workout parsing.
 */

import type { Stroke } from "./ml-pairing";

// ─── Intensity ─────────────────────────────────────────────────────────────────

export type IntensityLevel = "easy" | "moderate" | "hard" | "race";

export interface PercentRange {
  type: "percent_range";
  low: number; // e.g. 75
  high: number; // e.g. 85
  label: string; // e.g. "75–85%"
}

export interface PaceTarget {
  type: "pace_target";
  distance: number;
  label: string;
}

export type IntensityType =
  | "easy"
  | "aerobic"
  | "threshold"
  | "race_pace"
  | "pace_target"
  | "sprint"
  | "descend"
  | "build"
  | "negative_split"
  | "percent_range";

export interface ParsedIntensity {
  type: IntensityType;
  label: string;
  // For pace_target
  paceDistance?: number;
  // For percent_range
  percentLow?: number;
  percentHigh?: number;
}

export const INTENSITY_MULTIPLIERS: Record<IntensityLevel, number> = {
  easy: 1.25,
  moderate: 1.1,
  hard: 1.03,
  race: 1.0,
};

export function intensityTypeToLevel(type: IntensityType): IntensityLevel {
  switch (type) {
    case "easy":
      return "easy";
    case "aerobic":
      return "moderate";
    case "threshold":
      return "hard";
    case "race_pace":
      return "race";
    case "pace_target":
      return "race";
    case "sprint":
      return "race";
    case "descend":
      return "moderate";
    case "build":
      return "moderate";
    case "negative_split":
      return "moderate";
    case "percent_range":
      return "hard";
  }
}

// ─── Rep Pattern (per-rep structure) ───────────────────────────────────────────

export interface DrillSwimRep {
  type: "drill_swim";
  drillMeters: number | null; // e.g. 25 from "25 drill + 75 swim"
  swimMeters: number | null; // e.g. 75 from "25 drill + 75 swim"
  // raw text if not parseable into drill/swim split
  rawText?: string;
}

export interface OddEvenRep {
  type: "odd_even";
  odd: string; // e.g. "underwater dolphin kick (breakout + easy to wall)"
  even: string; // e.g. "freestyle kick build to strong"
}

export interface SimpleRep {
  type: "simple";
  meters: number;
  stroke: Stroke | null;
  note?: string; // e.g. "(long strokes)" from "pull (long strokes)"
  intensity?: ParsedIntensity; // e.g. from "build to ~75%"
  pacing?: string | null; // "build", "smooth", "strong", "moderate" when parsed from text
}

export type Rep = DrillSwimRep | OddEvenRep | SimpleRep;

// ─── RepGroup ─────────────────────────────────────────────────────────────────

export interface RepGroup {
  reps: number | null; // e.g. 4 from "4x100"
  distance: number | null; // e.g. 100 from "4x100"
  stroke: Stroke | null;
  interval: string | null; // "1:30" format
  intensity: ParsedIntensity | null;
  pacing: string | null; // "build", "smooth", "strong", "moderate" — qualifier before intensity
  pattern: Rep[]; // one Rep per sub-piece within the group
  patternType:
    | "simple"
    | "drill_swim"
    | "odd_even"
    | "ascending"
    | "descending"
    | null;
  connectors: Array<"and" | "+">;
  note: string | null; // e.g. "(Paddles optional)" or "(very fast)"
  gear: string[] | null; // e.g. ["paddles"]
  gearOptional: boolean; // true if "optional" follows gear
  descend: string | null; // e.g. "1-4" from "Descend 1-4"
  details: string[] | null; // catch-all for any unmatched descriptive tokens
}

// ─── NamedSet ─────────────────────────────────────────────────────────────────

export interface NamedSet {
  label: string | null; // e.g. "Aerobic Build" or "Stroke Activation"
  note: string | null; // e.g. "connect technique under light aerobic load" (trailing prose)
  repGroups: RepGroup[];
}

// ─── Section ──────────────────────────────────────────────────────────────────

export interface Section {
  title: string | null; // "Warm Up", "Main — Sprint", null for implicit
  namedSets: NamedSet[];
}

// ─── Workout ──────────────────────────────────────────────────────────────────

export interface Workout {
  title: string | null;
  sections: Section[];
}

// ─── Intensity badge color ────────────────────────────────────────────────────

export function intensityColor(type: IntensityType): string {
  switch (type) {
    case "easy":
      return "#34C759";
    case "aerobic":
      return "#30D158";
    case "threshold":
      return "#FF9500";
    case "race_pace":
      return "#FF3B30";
    case "pace_target":
      return "#007AFF";
    case "sprint":
      return "#FF2D55";
    case "descend":
      return "#5856D6";
    case "build":
      return "#AF52DE";
    case "negative_split":
      return "#5AC8FA";
    case "percent_range":
      return "#FF9500";
  }
}

// ─── Legacy types (kept for migration compatibility in Stage 4) ─────────────────

export interface LegacyWorkoutSetComponent {
  index: number;
  parsed: boolean;
  rawText: string;
  set: LegacyParsedSet | null;
  gear: string[] | null;
  effectiveDistance: number | null;
}

export interface LegacyParsedSet {
  reps: number | null;
  distance: number | null;
  stroke: Stroke | null;
  interval: string | null;
  intensity: ParsedIntensity | null;
  intensityPattern: IntensityLevel[];
}
