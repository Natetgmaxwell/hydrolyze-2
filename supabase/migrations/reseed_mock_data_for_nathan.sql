-- ============================================================
-- Hydrolyze Mock Data Re-Seed Script (Targeted Fix)
-- ============================================================

DO $$
DECLARE
  v_coach_id       uuid;
  v_workout_id     uuid := gen_random_uuid();
  v_set_id         uuid := gen_random_uuid();
  v_session_id     uuid := gen_random_uuid();

  -- 8 Mock Swimmer UUIDs
  v_s1 uuid := gen_random_uuid();
  v_s2 uuid := gen_random_uuid();
  v_s3 uuid := gen_random_uuid();
  v_s4 uuid := gen_random_uuid();
  v_s5 uuid := gen_random_uuid();
  v_s6 uuid := gen_random_uuid();
  v_s7 uuid := gen_random_uuid();
  v_s8 uuid := gen_random_uuid();

BEGIN
  -- 1. Find the exact coach ID that owns the 'nathan' swimmer
  SELECT coach_id INTO v_coach_id FROM swimmers WHERE first_name ILIKE '%nathan%' LIMIT 1;
  
  IF v_coach_id IS NULL THEN
    -- Fallback just in case
    SELECT id INTO v_coach_id FROM coaches ORDER BY created_at DESC LIMIT 1;
  END IF;

  IF v_coach_id IS NULL THEN
    RAISE EXCEPTION 'Could not find any coach account! Are you logged in?';
  END IF;

  RAISE NOTICE 'Targeting coach: %', v_coach_id;

  -- 2. Cleanup any old mock data to avoid duplicates
  DELETE FROM recorded_times WHERE session_id IN (SELECT id FROM sessions WHERE workout_id IN (SELECT id FROM workouts WHERE title = 'Mock Pairing Test Workout'));
  DELETE FROM sessions WHERE workout_id IN (SELECT id FROM workouts WHERE title = 'Mock Pairing Test Workout');
  DELETE FROM workout_sets WHERE workout_id IN (SELECT id FROM workouts WHERE title = 'Mock Pairing Test Workout');
  DELETE FROM workouts WHERE title = 'Mock Pairing Test Workout';
  DELETE FROM swimmer_pbs WHERE swimmer_id IN (SELECT id FROM swimmers WHERE first_name = 'Mock');
  DELETE FROM swimmer_stats WHERE swimmer_id IN (SELECT id FROM swimmers WHERE first_name = 'Mock');
  DELETE FROM swimmers WHERE first_name = 'Mock';

  -- 3. Insert 8 Mock Swimmers (Providing both the old 'name' column and the new first_name/last_name to satisfy constraints)
  INSERT INTO swimmers (id, coach_id, name, first_name, last_name, form_stroke) VALUES
    (v_s1, v_coach_id, 'Mock Alice',   'Mock', 'Alice',   'Free'),
    (v_s2, v_coach_id, 'Mock Bob',     'Mock', 'Bob',     'Free'),
    (v_s3, v_coach_id, 'Mock Charlie', 'Mock', 'Charlie', 'Free'),
    (v_s4, v_coach_id, 'Mock Diana',   'Mock', 'Diana',   'Free'),
    (v_s5, v_coach_id, 'Mock Ethan',   'Mock', 'Ethan',   'Free'),
    (v_s6, v_coach_id, 'Mock Fiona',   'Mock', 'Fiona',   'Free'),
    (v_s7, v_coach_id, 'Mock George',  'Mock', 'George',  'Free'),
    (v_s8, v_coach_id, 'Mock Hannah',  'Mock', 'Hannah',  'Free');

  -- 4. Insert Swimmer Stats (Rolling averages)
  INSERT INTO swimmer_stats (swimmer_id, distance, stroke, intensity, mean_time_ms, stddev_time_ms, sample_count) VALUES
    (v_s1, 50, 'Free', 'moderate', 27400, 300,  20),
    (v_s2, 50, 'Free', 'moderate', 27800, 350,  18),
    (v_s3, 50, 'Free', 'moderate', 28500, 500,  15),
    (v_s4, 50, 'Free', 'moderate', 29100, 600,  12),
    (v_s5, 50, 'Free', 'moderate', 30200, 800,  10),
    (v_s6, 50, 'Free', 'moderate', 31000, 900,   8),
    (v_s7, 50, 'Free', 'moderate', 32500, 1500,  6),
    (v_s8, 50, 'Free', 'moderate', 34100, 2000,  5);

  -- 5. Insert Swimmer PBs
  INSERT INTO swimmer_pbs (swimmer_id, distance, stroke, time_ms) VALUES
    (v_s1, 50, 'Free', 26800),
    (v_s2, 50, 'Free', 27200),
    (v_s3, 50, 'Free', 27900),
    (v_s4, 50, 'Free', 28400),
    (v_s5, 50, 'Free', 29500),
    (v_s6, 50, 'Free', 30100),
    (v_s7, 50, 'Free', 31200),
    (v_s8, 50, 'Free', 32800);

  -- 6. Create a Mock Workout + Set
  INSERT INTO workouts (id, coach_id, title, status, scheduled_at, am_pm)
    VALUES (v_workout_id, v_coach_id, 'Mock Pairing Test Workout', 'complete', CURRENT_DATE, 'AM');

  INSERT INTO workout_sets (id, workout_id, order_index, reps, distance, stroke)
    VALUES (v_set_id, v_workout_id, 1, 1, 50, 'Free');

  -- 7. Create a Mock Session
  INSERT INTO sessions (id, workout_id, coach_id, started_at, completed_at)
    VALUES (v_session_id, v_workout_id, v_coach_id, now() - interval '1 hour', now());

  -- 8. Insert 8 Recorded Times (unassigned)
  INSERT INTO recorded_times (session_id, workout_id, workout_set_id, swimmer_id, rep_index, time_ms, source, stroke, pace_distance) VALUES
    (v_session_id, v_workout_id, v_set_id, NULL, 1, 28500, 'unassigned', 'Free', 50),
    (v_session_id, v_workout_id, v_set_id, NULL, 2, 27400, 'unassigned', 'Free', 50),
    (v_session_id, v_workout_id, v_set_id, NULL, 3, 32500, 'unassigned', 'Free', 50),
    (v_session_id, v_workout_id, v_set_id, NULL, 4, 30200, 'unassigned', 'Free', 50),
    (v_session_id, v_workout_id, v_set_id, NULL, 5, 27800, 'unassigned', 'Free', 50),
    (v_session_id, v_workout_id, v_set_id, NULL, 6, 34100, 'unassigned', 'Free', 50),
    (v_session_id, v_workout_id, v_set_id, NULL, 7, 29100, 'unassigned', 'Free', 50),
    (v_session_id, v_workout_id, v_set_id, NULL, 8, 31000, 'unassigned', 'Free', 50);

  RAISE NOTICE '✅ Fresh Mock data seeded successfully specifically for your active coach account!';
END $$;
