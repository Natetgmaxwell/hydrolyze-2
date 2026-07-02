-- Force Reassign Mock Data to your active Coach Account
-- This script forcefully grabs the most recently created coach account
-- and assigns all the mock data to it.

DO $$
DECLARE
  v_latest_coach_id uuid;
BEGIN
  -- Grab the most recently created coach account (which is your active one)
  SELECT id INTO v_latest_coach_id FROM coaches ORDER BY created_at DESC LIMIT 1;

  IF v_latest_coach_id IS NULL THEN
    RAISE EXCEPTION 'No coach accounts found!';
  END IF;

  RAISE NOTICE 'Assigning mock data to coach: %', v_latest_coach_id;

  -- Update swimmers
  UPDATE swimmers 
  SET coach_id = v_latest_coach_id 
  WHERE first_name = 'Mock' OR first_name LIKE 'Mock%';

  -- Update workouts
  UPDATE workouts
  SET coach_id = v_latest_coach_id
  WHERE title = 'Mock Pairing Test Workout';

  -- Update sessions
  UPDATE sessions
  SET coach_id = v_latest_coach_id
  WHERE workout_id IN (SELECT id FROM workouts WHERE title = 'Mock Pairing Test Workout');

  RAISE NOTICE 'Success! Refresh the app.';
END $$;
