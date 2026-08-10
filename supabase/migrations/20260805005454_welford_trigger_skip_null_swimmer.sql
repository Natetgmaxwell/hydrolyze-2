-- t_be09a643 (2026-08-05): amend the Welford trigger to skip rows
-- with NULL swimmer_id. The new per-fragment CTA flow writes rows
-- with swimmer_id = NULL until the pairing handoff resolves;
-- the Welford calibration requires a swimmer to key on, so the
-- trigger must skip these rows without crashing.
--
-- The amended trigger is the same function as the original (no
-- behavior change for the matched case), with one new guard at
-- the top: IF NEW.swimmer_id IS NULL THEN RETURN NEW.

CREATE OR REPLACE FUNCTION public.welford_trigger_recorded_times() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_suit boolean;
  v_start_type text;
  v_distance int;
  v_stroke text;
BEGIN
  -- t_be09a643 (2026-08-05): skip rows that the per-fragment CTA
  -- flow wrote with swimmer_id = NULL (awaiting pairing). The
  -- Welford calibration keys on the swimmer; without one, leave
  -- the calibration tables untouched. The original guard is
  -- preserved below — both checks early-return without touching
  -- the calibration tables.
  IF NEW.swimmer_id IS NULL THEN
    RETURN NEW;
  END IF;

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
$$;

COMMENT ON FUNCTION public.welford_trigger_recorded_times() IS 'AFTER INSERT trigger on recorded_times. Reads context from workout_sets and applies Welford online updates to both swimmer_suits (T6) and swimmer_starts (T7). Skips null swimmer_id (t_be09a643), null times_ms, orphan workout_sets, and sets with null distance/stroke. T6 + T7, 2026-06-20; swimmer_id guard added 2026-08-05.';