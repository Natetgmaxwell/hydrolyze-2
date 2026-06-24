/**
 * Swimmer progression stats — query helpers for the pool-deck chart.
 *
 * Strict match: exact (swimmer_id, distance, stroke, intensity) in the last 28 days.
 * Rep position ratio derived from stored rep_index + workout_sets.reps join.
 * PB fetched separately from swimmer_pbs.
 */

import { supabase } from "./supabase";
import { withTimeout } from "./supabase-helpers";

export interface ProgressionPoint {
  date: string; // ISO date string, e.g. "2026-05-08"
  timeMs: number;
  repPosition: number; // 0.0–1.0: (rep_index + 1) / reps
  isPB: boolean;
}

export interface SwimmerProgressionResult {
  points: ProgressionPoint[];
  pb: { timeMs: number; date: string } | null;
}

export interface PBPoint {
  timeMs: number;
  date: string;
}

export async function getSwimmerProgression(
  swimmerId: string,
  distance: number,
  stroke: string,
  intensity: string,
  gear: string | null,
  lookbackDays: number = 28,
): Promise<SwimmerProgressionResult> {
  const cutoff = new Date();
  cutoff.setDate(cutoff.getDate() - lookbackDays);
  const cutoffStr = cutoff.toISOString().slice(0, 10);

  const { data: rows, error } = await withTimeout(
    supabase
      .from("recorded_times")
      .select(
        `
        id,
        time_ms,
        rep_index,
        created_at,
        intensity,
        workout_set_id,
        workout_sets(distance, stroke, gear, reps)
      `,
      )
      .eq("swimmer_id", swimmerId)
      .eq("workout_sets.distance", distance)
      .eq("workout_sets.stroke", stroke)
      .eq("intensity", intensity)
      .gte("created_at", cutoffStr)
      .order("created_at", { ascending: true }),
    10000,
  );

  if (error || !rows) {
    console.error("[swimmer-stats] progression query error:", error);
    return { points: [], pb: null };
  }

  const typedRows = rows as unknown as Array<{
    id: string;
    time_ms: number;
    rep_index: number;
    created_at: string;
    intensity: string;
    workout_set_id: string;
    workout_sets: {
      distance: number;
      stroke: string;
      gear: string | null;
      reps: number;
    } | null;
  }>;

  const points: ProgressionPoint[] = typedRows
    .filter((r) => r.workout_sets != null)
    .map((r) => {
      const reps = r.workout_sets!.reps;
      const repPosition = reps > 0 ? (r.rep_index + 1) / reps : 0;
      return {
        date: r.created_at.slice(0, 10),
        timeMs: r.time_ms,
        repPosition: Math.min(1, Math.max(0, repPosition)),
        isPB: false,
      };
    });

  // PB lookup — most recent PB for this exact (swimmer, distance, stroke, gear)
  const { data: pbRows } = await withTimeout(
    supabase
      .from("swimmer_pbs")
      .select("time_ms, recorded_at")
      .eq("swimmer_id", swimmerId)
      .eq("distance", distance)
      .eq("stroke", stroke)
      .is("gear", gear == null ? null : gear)
      .order("recorded_at", { ascending: false })
      .limit(1),
    10000,
  );

  const pb =
    pbRows && pbRows.length > 0
      ? { timeMs: pbRows[0].time_ms, date: pbRows[0].recorded_at.slice(0, 10) }
      : null;

  // Mark points that match the PB time_ms as PB
  if (pb) {
    const pbTimeMs = pb.timeMs;
    const tolerance = 100; // 100ms tolerance for PB match
    for (const pt of points) {
      if (Math.abs(pt.timeMs - pbTimeMs) <= tolerance) {
        pt.isPB = true;
      }
    }
  }

  return { points, pb };
}
