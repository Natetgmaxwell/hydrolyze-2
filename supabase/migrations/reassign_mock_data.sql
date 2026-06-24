-- Fix: Reassign mock data to your current coach account
-- If you created your account after the mock data was seeded, 
-- the mock swimmers were attached to a different (older) coach ID.

DO $$
DECLARE
  v_nathan_coach_id uuid;
BEGIN
  -- Find the coach ID associated with your 'nathan' swimmer, 
  -- or fallback to the most recently created coach account.
  SELECT coach_id INTO v_nathan_coach_id 
  FROM swimmers 
  WHERE first_name ILIKE '%nathan%' 
  LIMIT 1;

  IF v_nathan_coach_id IS NULL THEN
    SELECT id INTO v_nathan_coach_id FROM coaches ORDER BY created_at DESC LIMIT 1;
  END IF;

  IF v_nathan_coach_id IS NULL THEN
    RAISE EXCEPTION 'Could not find your coach ID!';
  END IF;

  RAISE NOTICE 'Reassigning mock data to coach: %', v_nathan_coach_id;

  -- 1. Reassign Mock Swimmers
  UPDATE swimmers 
  SET coach_id = v_nathan_coach_id 
  WHERE first_name = 'Mock' OR name LIKE 'Mock %';

  -- 2. Reassign Mock Workouts
  UPDATE workouts
  SET coach_id = v_nathan_coach_id
  WHERE title = 'Mock Pairing Test Workout';

  -- 3. Reassign Mock Sessions
  UPDATE sessions
  SET coach_id = v_nathan_coach_id
  WHERE workout_id IN (SELECT id FROM workouts WHERE title = 'Mock Pairing Test Workout');

  -- 4. Reassign Wave Assignments (if any)
  UPDATE wave_assignments
  SET coach_id = v_nathan_coach_id
  WHERE swimmer_id IN (SELECT id FROM swimmers WHERE first_name = 'Mock' OR name LIKE 'Mock %');

  RAISE NOTICE 'Successfully reassigned mock data to your account!';
END $$;
