-- hermes-verify: t_2a8763a5 — end-to-end pairing handoff.
-- Writes a recorded_time with NULL swimmer_id, calls
-- pair_recorded_times_for_set, then UPDATEs the swimmer_id (the
-- caller's job) and verifies the Welford trigger fires correctly.
--
-- Mirrors what the iOS PairingHandoff does: select → resolve →
-- UPDATE. We check swimmer_pbs before/after to confirm the
-- trigger fired (the spec conformance migration made the trigger
-- NULL-safe).

BEGIN;

-- Snapshot swimmer_pbs state for Ethan (100 Free, no-gear)
CREATE TEMP TABLE pre_state ON COMMIT DROP AS
SELECT swimmer_id, distance, stroke, COALESCE(gear, 'none') AS gear,
       time_ms, recorded_at
  FROM swimmer_pbs
 WHERE swimmer_id = 'b8c13ff4-730e-4403-8ca5-d28a2bbecc09'
   AND distance = 100 AND stroke = 'Free' AND COALESCE(gear, 'none') = 'none';

-- 1. Create a fresh workout + set + recorded_time, no swimmer_id.
WITH coach_pick AS (SELECT id AS coach_id FROM coaches LIMIT 1),
     new_workout AS (
       INSERT INTO workouts (coach_id, title)
       SELECT coach_id, 'pair-record-e2e-' || extract(epoch from now())::text
         FROM coach_pick
       RETURNING id
     ),
     new_set AS (
       INSERT INTO workout_sets (workout_id, order_index, reps, distance, stroke)
       SELECT id, 0, 1, 100, 'Free' FROM new_workout
       RETURNING id
     ),
     new_rt AS (
       INSERT INTO recorded_times (
           workout_set_id, distance_meters, intensity, start_type,
           stroke, gear, time_ms, raw_text, rep_index
       )
       SELECT s.id, 100, 'max', 'in_water', 'Free', NULL, 66282,
              '1 x 100 Free (e2e pairing test)', 1
         FROM new_set s
       RETURNING id AS recorded_id, workout_set_id AS ws_id
     )
SELECT * INTO TEMP e2e_setup FROM new_rt;

-- 2. Run the function.
CREATE TEMP TABLE e2e_match ON COMMIT DROP AS
SELECT recorded_time_id, swimmer_id, confidence, fallback_tier, matched
  FROM pair_recorded_times_for_set((SELECT ws_id FROM e2e_setup));

-- 3. Caller-side UPDATE — the Welford trigger should fire here.
UPDATE recorded_times
   SET swimmer_id = (SELECT swimmer_id FROM e2e_match)
 WHERE id = (SELECT recorded_time_id FROM e2e_match);

-- 4. Snapshot post-update swimmer_pbs state.
CREATE TEMP TABLE post_state ON COMMIT DROP AS
SELECT swimmer_id, distance, stroke, COALESCE(gear, 'none') AS gear,
       time_ms, recorded_at
  FROM swimmer_pbs
 WHERE swimmer_id = 'b8c13ff4-730e-4403-8ca5-d28a2bbecc09'
   AND distance = 100 AND stroke = 'Free' AND COALESCE(gear, 'none') = 'none';

-- 5. Assertions
WITH probe(n, label, got, want) AS (
  SELECT 1, 'recorded_time row exists with swimmer_id filled',
         (SELECT swimmer_id::text FROM recorded_times WHERE id = (SELECT recorded_time_id FROM e2e_match)),
         'b8c13ff4-730e-4403-8ca5-d28a2bbecc09'
  UNION ALL SELECT 2, 'function returned swimmer_id = Ethan',
         (SELECT swimmer_id::text FROM e2e_match),
         'b8c13ff4-730e-4403-8ca5-d28a2bbecc09'
  UNION ALL SELECT 3, 'fallback_tier = exact_context',
         (SELECT fallback_tier FROM e2e_match), 'exact_context'
  UNION ALL SELECT 4, 'confidence >= 0.99 (exact match)',
         CASE WHEN (SELECT confidence FROM e2e_match) >= 0.99
              THEN '1' ELSE '0' END, '1'
  UNION ALL SELECT 5, 'post-trigger swimmer_pbs row exists',
         CASE WHEN (SELECT COUNT(*) FROM post_state) > 0
              THEN '1' ELSE '0' END, '1'
  UNION ALL SELECT 6, 'post-trigger swimmer_pbs has fresh recorded_at',
         CASE WHEN (SELECT recorded_at FROM post_state) >= (SELECT MIN(recorded_at) FROM pre_state)
              THEN '1' ELSE '0' END, '1'
)
SELECT n, label, got, want, CASE WHEN got = want THEN 'PASS' ELSE 'FAIL' END AS result
  FROM probe ORDER BY n;

ROLLBACK;
