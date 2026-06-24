-- Migration: Per-rep intensity on recorded_times + swimmer intensity calibration table
-- Enables the pairing algorithm to use per-swimmer learned intensity multipliers.

-- ── 1. recorded_times: track which IntensityLevel each rep was swum at ─────────
-- 'easy' | 'moderate' | 'hard' | 'race'
-- NULL for times recorded before this migration or when no intensity was specified.
ALTER TABLE recorded_times
  ADD COLUMN IF NOT EXISTS intensity text;

-- ── 2. swimmer_intensity_calibrations ─────────────────────────────────────────
-- Stores a Welford running mean/M2 of the ratio:
--   actual_training_time_ms / curve_predicted_time_ms
-- per (swimmer, stroke, intensity_level).
--
-- A ratio > 1 means the swimmer is slower than the curve predicts at that effort.
-- A ratio < 1 means they are faster (possible for race-effort short reps).
-- The mean ratio replaces the global INTENSITY_MULTIPLIERS default once
-- sample_count >= 3.
CREATE TABLE IF NOT EXISTS swimmer_intensity_calibrations (
  swimmer_id    uuid    NOT NULL REFERENCES swimmers(id) ON DELETE CASCADE,
  stroke        text    NOT NULL,
  intensity     text    NOT NULL,   -- 'easy' | 'moderate' | 'hard' | 'race'
  multiplier_mean float NOT NULL DEFAULT 1.0,   -- Welford running mean
  multiplier_m2   float NOT NULL DEFAULT 0.0,   -- Welford M2 accumulator (for stddev)
  sample_count  integer NOT NULL DEFAULT 0,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (swimmer_id, stroke, intensity)
);

-- ── 3. RLS ─────────────────────────────────────────────────────────────────────
ALTER TABLE swimmer_intensity_calibrations ENABLE ROW LEVEL SECURITY;

CREATE POLICY "coach_own_intensity_calibrations" ON swimmer_intensity_calibrations
  FOR ALL USING (
    swimmer_id IN (SELECT id FROM swimmers WHERE coach_id = auth.uid()::text)
  );
