-- Backfill: populate swimmer_suits + swimmer_starts from existing
-- recorded_times. The Welford trigger (migration 0003) only fires on
-- new INSERTs; the 1,414 existing recorded_times rows need a one-shot
-- replay through the same welford_update_* helpers so the calibration
-- tables reflect historical data.
--
-- Author: Hermes Agent (TARS)
-- Date: 2026-06-22
-- Run: supabase db query --linked -f scripts/backfill_calibration_from_recorded_times.sql
--
-- IDEMPOTENT: clears swimmer_suits + swimmer_starts first, then re-derives
-- from scratch. Safe to re-run. The DELETE pattern (not TRUNCATE) is
-- intentional — keeps the operation within the normal transaction
-- envelope and doesn't break FK semantics on the swim suite
-- downstream.
--
-- SCOPE:
--   - Uses paired_swimmer_id with fallback to swimmer_id (the
--     pairing engine may have re-attributed a time; calibration
--     follows the attribution, not the raw swimmer)
--   - Joins through workout_set_id → workout_sets for suit +
--     start_type + distance + stroke
--   - Falls back to recorded_times.pace_distance + recorded_times.stroke
--     (added in the v1.17 model upgrade) when workout_sets values
--     are missing
--   - Chronological order for stable Welford accumulation

DO $$
DECLARE
  rt_record RECORD;
  v_count int := 0;
  v_skipped int := 0;
BEGIN
  -- Reset calibration tables (clean slate; recompute from recorded_times)
  DELETE FROM swimmer_suits;
  DELETE FROM swimmer_starts;

  FOR rt_record IN
    SELECT
      COALESCE(rt.paired_swimmer_id, rt.swimmer_id) AS swimmer_id,
      rt.time_ms,
      ws.suit,
      ws.start_type,
      COALESCE(rt.pace_distance, ws.distance) AS distance,
      COALESCE(rt.stroke, ws.stroke) AS stroke
    FROM recorded_times rt
    JOIN workout_sets ws ON rt.workout_set_id = ws.id
    WHERE COALESCE(rt.paired_swimmer_id, rt.swimmer_id) IS NOT NULL
      AND rt.time_ms IS NOT NULL
    ORDER BY rt.created_at ASC
  LOOP
    -- Sanity: skip if any of the calibration dimensions are NULL
    IF rt_record.suit IS NULL
       OR rt_record.start_type IS NULL
       OR rt_record.distance IS NULL
       OR rt_record.stroke IS NULL
    THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    PERFORM welford_update_suits(
      rt_record.swimmer_id, rt_record.time_ms, rt_record.suit,
      rt_record.distance, rt_record.stroke
    );
    PERFORM welford_update_starts(
      rt_record.swimmer_id, rt_record.time_ms, rt_record.start_type,
      rt_record.distance, rt_record.stroke
    );
    v_count := v_count + 1;
  END LOOP;

  RAISE NOTICE 'Backfill complete: % recorded_times rows processed, % skipped', v_count, v_skipped;
END $$;
