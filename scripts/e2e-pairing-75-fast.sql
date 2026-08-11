-- e2e-pairing-75-fast.sql — t_24238efa: Verify pairing engine handoff for 75 fast segment
--
-- Simulates the full flow end-to-end against the LIVE database:
--   parse (done upstream: 4 x (75 fast / 25 easy) → fragments 75@fast, 25@easy)
--   → stopwatch rows persisted with fragment context (distance, intensity, start)
--   → pair_recorded_times_for_set() matches the 75 fast time to the correct swimmer.
--
-- The pairing engine must see "75m @ sprint from a dive" and pair apples-to-apples:
-- the swimmer whose 75m sprint PB is closest wins.
--
-- Pure SQL (no psql meta-commands) so it runs via the Supabase Management API
-- SQL endpoint or psql. Cleanup: run e2e-pairing-cleanup.sql afterwards
-- (deletes rows by 'E2E %' name prefix — idempotent, zero residue).

DO $$
DECLARE
  v_coach uuid := '264aae92-f61b-41a9-bd38-aeb911c743d9';  -- Nathan Maxwell (real, read-only)
  v_a uuid;
  v_b uuid;
  v_workout uuid;
  v_set uuid;
  v_75_swimmer uuid;
  v_75_tier text;
  v_75_matched boolean;
  v_25_matched boolean;
BEGIN
  -- ── 1. Fixture: two test swimmers ─────────────────────────────────────
  INSERT INTO swimmers (coach_id, name) VALUES (v_coach, 'E2E Swimmer A')
  RETURNING id INTO v_a;
  INSERT INTO swimmers (coach_id, name) VALUES (v_coach, 'E2E Swimmer B')
  RETURNING id INTO v_b;

  -- ── 2. Fixture: workout + workout_set (the worked example) ────────────
  INSERT INTO workouts (coach_id, title, status)
  VALUES (v_coach, 'E2E Parser Pairing', 'draft')
  RETURNING id INTO v_workout;

  INSERT INTO workout_sets (workout_id, order_index, reps, distance, stroke, intensity_type, intensity_label)
  VALUES (v_workout, 0, 4, 100, 'Free', 'sprint', 'fast')
  RETURNING id INTO v_set;

  -- ── 3. Fixture: PBs — A is the 75 sprint specialist (45.0s), B slower (50.0s) ──
  INSERT INTO swimmer_pbs (swimmer_id, distance, stroke, time_ms, gear, intensity) VALUES
    (v_a, 75, 'Free', 45000, 'none', 'sprint'),
    (v_b, 75, 'Free', 50000, 'none', 'sprint');

  -- ── 4. Fixture: stopwatch rows with fragment context (NULL swimmer) ────
  -- The 75 fast fragment timed at 45.2s from a dive; the 25 easy at 20.0s.
  INSERT INTO recorded_times (workout_set_id, rep_index, time_ms, intensity, stroke, distance_meters, start_type, source) VALUES
    (v_set, 0, 45200, 'sprint', 'Free', 75, 'dive', 'auto'),
    (v_set, 1, 20000, 'easy',   'Free', 25, 'wall', 'auto');

  -- ── 5. THE HANDOFF: pair the set ──────────────────────────────────────
  SELECT p.swimmer_id, p.fallback_tier, p.matched
    INTO v_75_swimmer, v_75_tier, v_75_matched
    FROM pair_recorded_times_for_set(v_set) p
    JOIN recorded_times rt ON rt.id = p.recorded_time_id
   WHERE rt.distance_meters = 75;

  -- ── 6. Assertions ─────────────────────────────────────────────────────
  IF v_75_swimmer IS DISTINCT FROM v_a THEN
    RAISE EXCEPTION 'FAIL: 75 fast matched to % (expected Swimmer A %)', v_75_swimmer, v_a;
  END IF;
  IF v_75_tier <> 'exact_context' THEN
    RAISE EXCEPTION 'FAIL: 75 fast tier = % (expected exact_context)', v_75_tier;
  END IF;
  IF NOT v_75_matched THEN
    RAISE EXCEPTION 'FAIL: 75 fast not matched';
  END IF;
  RAISE NOTICE 'PASS: 75 fast -> Swimmer A (exact_context, matched)';

  SELECT p.matched INTO v_25_matched
    FROM pair_recorded_times_for_set(v_set) p
    JOIN recorded_times rt ON rt.id = p.recorded_time_id
   WHERE rt.distance_meters = 25;

  IF v_25_matched THEN
    RAISE EXCEPTION 'FAIL: 25 easy should be unmatched (no 25m PB)';
  END IF;
  RAISE NOTICE 'PASS: 25 easy unmatched (no PB context) — correct fallback';

  -- ── 7. Persist the pairing result (the real caller's write-back) ──────
  UPDATE recorded_times rt
     SET swimmer_id = p.swimmer_id,
         assignment_confidence = p.confidence
    FROM pair_recorded_times_for_set(v_set) p
   WHERE rt.id = p.recorded_time_id
     AND p.matched;
  RAISE NOTICE 'PASS: write-back applied (swimmer_id + confidence)';
END $$;
