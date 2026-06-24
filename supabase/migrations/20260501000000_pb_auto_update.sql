-- Migration: PB auto-update trigger
-- Automatically updates or inserts a record in swimmer_pbs if a new recorded_time
-- is faster than the current PB for that swimmer/distance/stroke/gear combo.

CREATE OR REPLACE FUNCTION update_swimmer_pbs()
RETURNS TRIGGER AS $$
DECLARE
  v_stroke text;
  v_distance integer;
  v_gear text;
  v_current_pb integer;
BEGIN
  -- 1. Get context from the workout set
  SELECT stroke, distance, gear 
  INTO v_stroke, v_distance, v_gear
  FROM workout_sets 
  WHERE id = NEW.workout_set_id;

  -- 2. Resolve 'Form' stroke to swimmer's specialty
  IF v_stroke = 'Form' THEN
    SELECT form_stroke INTO v_stroke FROM swimmers WHERE id = NEW.swimmer_id;
  END IF;

  -- 3. Skip if we don't have enough info or if it's IM (IM PBs aren't usually used for pairing)
  IF v_stroke IS NULL OR v_stroke = 'IM' OR v_distance IS NULL THEN
    RETURN NEW;
  END IF;

  -- 4. Check for existing PB
  SELECT time_ms INTO v_current_pb
  FROM swimmer_pbs
  WHERE swimmer_id = NEW.swimmer_id
    AND stroke = v_stroke
    AND distance = v_distance
    AND (gear = v_gear OR (gear IS NULL AND v_gear IS NULL))
  LIMIT 1;

  -- 5. If no PB exists OR this new time is faster, upsert
  IF v_current_pb IS NULL OR NEW.time_ms < v_current_pb THEN
    INSERT INTO swimmer_pbs (swimmer_id, stroke, distance, gear, time_ms, recorded_at)
    VALUES (NEW.swimmer_id, v_stroke, v_distance, v_gear, NEW.time_ms, now())
    ON CONFLICT (swimmer_id, stroke, distance, gear) DO UPDATE
    SET time_ms = EXCLUDED.time_ms,
        recorded_at = EXCLUDED.recorded_at;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_update_swimmer_pbs ON recorded_times;
CREATE TRIGGER trg_update_swimmer_pbs
  AFTER INSERT ON recorded_times
  FOR EACH ROW
  WHEN (NEW.swimmer_id IS NOT NULL AND NEW.workout_set_id IS NOT NULL)
  EXECUTE FUNCTION update_swimmer_pbs();
