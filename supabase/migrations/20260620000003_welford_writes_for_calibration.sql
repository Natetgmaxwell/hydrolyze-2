-- Migration: Welford write path for calibration tables (T6 + T7, Phase 1)
-- Date: 2026-06-20
-- Author: Hermes Agent (TARS)
-- Filename: 20260620000003_welford_writes_for_calibration.sql
--
-- Phase 1 (T6 + T7): when a `recorded_times` row is inserted, the
-- per-(swimmer, X, distance, stroke) calibration stat in BOTH
-- `swimmer_suits` (T6) and `swimmer_starts` (T7) is updated via the
-- canonical Welford online update formula:
--
--   count_new = count_old + 1
--   delta    = x_new - mean_old
--   mean_new = mean_old + delta / count_new
--   M2_new   = M2_old + delta * (x_new - mean_new)
--   stddev   = sqrt(M2_new / (count_new - 1))   -- sample stddev, n-1 denom
--
-- The m2 column (added in T1.5, 2026-06-20) is the Welford accumulator.
-- It is stored in the table; stddev is derived on each update.
--
-- Follows the pattern of the existing `trg_update_swimmer_pbs` trigger
-- (AFTER INSERT on recorded_times, calling a plpgsql function that
-- reads context from `workout_sets`).
--
-- T6 + T7 ship in one migration because the trigger is shared (one
-- INSERT fires both helper updates in the same function).
--
-- Idempotent. The functions use CREATE OR REPLACE; the trigger is
-- dropped and recreated. Safe to re-run.
--
-- SCOPE NOTES (2026-06-20):
--   1. Only AFTER INSERT is covered. UPDATE and DELETE on
--      recorded_times are out of scope for T6/T7. A coach correction
--      would require a separate recalibration pass; a deleted
--      recorded_time would leave the Welford slightly high. Both
--      are future work.
--   2. The 1414 existing `recorded_times` rows are NOT backfilled
--      by this migration (the trigger only fires on new INSERTs).
--      Backfilling is a separate operation; see the plan v3 open
--      questions.

BEGIN;

-- ══════════════════════════════════════════════════════════════════════════════
-- Helper 1 (T6): update swimmer_suits via Welford online update
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION welford_update_suits(
  p_swimmer_id uuid,
  p_time_ms int,
  p_suit boolean,
  p_distance int,
  p_stroke text
) RETURNS void AS $$
DECLARE
  v_existing_count int;
  v_existing_mean double precision;
  v_existing_m2 double precision;
  v_new_count int;
  v_new_mean double precision;
  v_new_m2 double precision;
  v_new_stddev double precision;
BEGIN
  -- Look up the existing row for this (swimmer, suit, distance, stroke)
  SELECT sample_count, mean_time_ms, m2
    INTO v_existing_count, v_existing_mean, v_existing_m2
    FROM swimmer_suits
   WHERE swimmer_id = p_swimmer_id
     AND suit = p_suit
     AND distance = p_distance
     AND stroke = p_stroke;

  IF NOT FOUND THEN
    -- First observation for this bucket: mean = the new value,
    -- m2 = 0, count = 1, stddev = 0 (sample stddev is undefined for n=1).
    INSERT INTO swimmer_suits
      (swimmer_id, suit, distance, stroke, mean_time_ms, m2, sample_count, stddev_time_ms, updated_at)
    VALUES
      (p_swimmer_id, p_suit, p_distance, p_stroke, p_time_ms::double precision, 0, 1, 0, now());
  ELSE
    -- Welford online update (numerically stable; O(1) per observation).
    v_new_count := v_existing_count + 1;
    v_new_mean  := v_existing_mean + (p_time_ms - v_existing_mean) / v_new_count;
    v_new_m2    := v_existing_m2   + (p_time_ms - v_existing_mean) * (p_time_ms - v_new_mean);
    IF v_new_count > 1 THEN
      v_new_stddev := sqrt(v_new_m2 / (v_new_count - 1));
    ELSE
      v_new_stddev := 0;
    END IF;

    UPDATE swimmer_suits
       SET mean_time_ms   = v_new_mean,
           m2             = v_new_m2,
           sample_count   = v_new_count,
           stddev_time_ms = v_new_stddev,
           updated_at     = now()
     WHERE swimmer_id = p_swimmer_id
       AND suit = p_suit
       AND distance = p_distance
       AND stroke = p_stroke;
  END IF;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION welford_update_suits(uuid, int, boolean, int, text) IS
  'Welford online update for the swimmer_suits calibration table. T6, 2026-06-20. '
  'Idempotent on (swimmer, suit, distance, stroke): inserts on first observation, '
  'updates on subsequent. The m2 column is the Welford accumulator; stddev is '
  'derived on each update.';

-- ══════════════════════════════════════════════════════════════════════════════
-- Helper 2 (T7): update swimmer_starts via Welford online update
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION welford_update_starts(
  p_swimmer_id uuid,
  p_time_ms int,
  p_start_type text,
  p_distance int,
  p_stroke text
) RETURNS void AS $$
DECLARE
  v_existing_count int;
  v_existing_mean double precision;
  v_existing_m2 double precision;
  v_new_count int;
  v_new_mean double precision;
  v_new_m2 double precision;
  v_new_stddev double precision;
BEGIN
  SELECT sample_count, mean_time_ms, m2
    INTO v_existing_count, v_existing_mean, v_existing_m2
    FROM swimmer_starts
   WHERE swimmer_id = p_swimmer_id
     AND start_type = p_start_type
     AND distance = p_distance
     AND stroke = p_stroke;

  IF NOT FOUND THEN
    INSERT INTO swimmer_starts
      (swimmer_id, start_type, distance, stroke, mean_time_ms, m2, sample_count, stddev_time_ms, updated_at)
    VALUES
      (p_swimmer_id, p_start_type, p_distance, p_stroke, p_time_ms::double precision, 0, 1, 0, now());
  ELSE
    v_new_count := v_existing_count + 1;
    v_new_mean  := v_existing_mean + (p_time_ms - v_existing_mean) / v_new_count;
    v_new_m2    := v_existing_m2   + (p_time_ms - v_existing_mean) * (p_time_ms - v_new_mean);
    IF v_new_count > 1 THEN
      v_new_stddev := sqrt(v_new_m2 / (v_new_count - 1));
    ELSE
      v_new_stddev := 0;
    END IF;

    UPDATE swimmer_starts
       SET mean_time_ms   = v_new_mean,
           m2             = v_new_m2,
           sample_count   = v_new_count,
           stddev_time_ms = v_new_stddev,
           updated_at     = now()
     WHERE swimmer_id = p_swimmer_id
       AND start_type = p_start_type
       AND distance = p_distance
       AND stroke = p_stroke;
  END IF;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION welford_update_starts(uuid, int, text, int, text) IS
  'Welford online update for the swimmer_starts calibration table. T7, 2026-06-20. '
  'Same shape as welford_update_suits but for the start_type dimension.';

-- ══════════════════════════════════════════════════════════════════════════════
-- Trigger: orchestrates both updates on each recorded_times insert
-- (T6 + T7 share this trigger; they ship together per the v3 plan)
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION welford_trigger_recorded_times() RETURNS trigger AS $$
DECLARE
  v_suit boolean;
  v_start_type text;
  v_distance int;
  v_stroke text;
BEGIN
  -- Defensive: skip if the new time is null (a coach saving an
  -- incomplete lap; the calibration should not be polluted with
  -- nulls). The existing `update_swimmer_pbs` trigger has the
  -- same defensive check shape.
  IF NEW.time_ms IS NULL THEN
    RETURN NEW;
  END IF;

  -- Resolve the workout_set context (suit + start_type + distance + stroke).
  -- The workout_set is the source of truth for the calibration fields
  -- per the v3 plan: "Both fields are on workout_sets only. recorded_times
  -- inherits the context via JOIN."
  SELECT suit, start_type, distance, stroke
    INTO v_suit, v_start_type, v_distance, v_stroke
    FROM workout_sets
   WHERE id = NEW.workout_set_id;

  IF NOT FOUND THEN
    -- Orphan recorded_time (no workout_set). Skip the calibration
    -- update; the recorded_time itself still goes through.
    RETURN NEW;
  END IF;

  -- The calibration requires both distance and stroke. If either is
  -- null (the workout_set was created before these fields were
  -- required, or for a non-standard set), skip the update.
  IF v_distance IS NULL OR v_stroke IS NULL THEN
    RETURN NEW;
  END IF;

  -- Update both calibration tables. PERFORM discards the function
  -- result; both helpers are RETURNS void.
  PERFORM welford_update_suits(NEW.swimmer_id, NEW.time_ms, v_suit, v_distance, v_stroke);
  PERFORM welford_update_starts(NEW.swimmer_id, NEW.time_ms, v_start_type, v_distance, v_stroke);

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION welford_trigger_recorded_times() IS
  'AFTER INSERT trigger on recorded_times. Reads context from workout_sets '
  'and applies Welford online updates to both swimmer_suits (T6) and '
  'swimmer_starts (T7). Skips null times_ms, orphan workout_sets, and '
  'sets with null distance/stroke. T6 + T7, 2026-06-20.';

-- Idempotent: drop and recreate the trigger.
DROP TRIGGER IF EXISTS welford_calibration_trigger ON recorded_times;

CREATE TRIGGER welford_calibration_trigger
AFTER INSERT ON recorded_times
FOR EACH ROW
EXECUTE FUNCTION welford_trigger_recorded_times();

COMMENT ON TRIGGER welford_calibration_trigger ON recorded_times IS
  'Phase 1 (T6 + T7) calibration write path. Fires on every recorded_times '
  'insert; calls welford_trigger_recorded_times() to apply the Welford '
  'online update to swimmer_suits and swimmer_starts. 2026-06-20.';

COMMIT;
