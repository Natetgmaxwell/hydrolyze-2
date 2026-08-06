-- Unmatched path test: distance=999 has no swimmer_pbs.
-- Expect: 1 row out, swimmer_id NULL, matched=false, fallback_tier='unmatched'.

BEGIN;

WITH new_workout AS (
  INSERT INTO workouts (coach_id, title)
  SELECT id, 'pair-unmatched-probe' FROM coaches LIMIT 1
  RETURNING id
),
new_set AS (
  INSERT INTO workout_sets (workout_id, order_index, reps, distance, stroke)
  SELECT id, 0, 1, 999, 'Free' FROM new_workout
  RETURNING id
)
INSERT INTO recorded_times (workout_set_id, distance_meters, intensity, start_type, stroke, gear, time_ms, raw_text, rep_index)
SELECT s.id, 999, 'max', 'in_water', 'Free', NULL, 600000, '1x999', 1 FROM new_set s;

CREATE TEMP TABLE unmatched_setup ON COMMIT DROP AS
SELECT workout_set_id FROM recorded_times WHERE raw_text = '1x999' LIMIT 1;

CREATE TEMP TABLE unmatched_result ON COMMIT DROP AS
SELECT recorded_time_id, swimmer_id, confidence, fallback_tier, matched
  FROM pair_recorded_times_for_set((SELECT workout_set_id FROM unmatched_setup));

-- Assertions
WITH probe(n, label, got, want) AS (
  SELECT 1, 'one row returned',
         (SELECT COUNT(*)::text FROM unmatched_result), '1'
  UNION ALL SELECT 2, 'swimmer_id is NULL',
         COALESCE((SELECT swimmer_id::text FROM unmatched_result), 'NULL'), 'NULL'
  UNION ALL SELECT 3, 'confidence is NULL',
         COALESCE((SELECT confidence::text FROM unmatched_result), 'NULL'), 'NULL'
  UNION ALL SELECT 4, 'fallback_tier = unmatched',
         (SELECT fallback_tier FROM unmatched_result), 'unmatched'
  UNION ALL SELECT 5, 'matched = false',
         (SELECT matched::text FROM unmatched_result), 'false'
)
SELECT n, label, got, want, CASE WHEN got = want THEN 'PASS' ELSE 'FAIL' END AS result
  FROM probe ORDER BY n;

ROLLBACK;
