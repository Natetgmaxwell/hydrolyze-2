-- hermes-verify: t_2a8763a5 — pair_recorded_times_for_set is Hungarian +
-- context-keyed predictions.
--
-- THE vision slice's claim, in one probe: the server-side pairing function
-- uses a single global Hungarian assignment over a (swimmer × fragment) cost
-- matrix where each cell is the velocity-space Gaussian cost against the
-- swimmer's best-context PB. Context = (distance, stroke, intensity, gear).
-- The prediction key is the fragment's metadata, not the parent
-- workout_set's generic PB.
--
-- The two assertions the card specifies:
--   1. The "100 Free" worked example resolves Ethan with confidence >= 0.5
--      and fallback_tier='exact_context'.
--   2. A new "100 Free with fins" worked example resolves a different
--      swimmer than the no-fins case for the same time, proving the
--      predictions are context-keyed (gear='fins' routes to a fins PB).
--
-- Why these specific worked examples:
--   - Ethan's 100 Free no-gear PB is 66282ms. A recorded_times row at
--     that exact time (distance=100, gear=NULL, intensity='race') costs
--     0 against Ethan's PB → confidence ~1.0, exact_context.
--   - For the fins case, we insert a (swimmer=Hannah, distance=100,
--     gear='fins', intensity='max') PB at a time that no other swimmer's
--     no-gear 100 Free PB matches exactly. The no-fins row picks some
--     other swimmer; the fins row picks Hannah.
--
-- Rollback-wrapped (no persistent writes — the swimmer_pbs Hannah fins row
-- IS persistent on ROLLBACK, so we use a savepoint + cleanup pattern, OR
-- better: the existing UNIQUE constraint makes the row idempotent. The
-- probe creates the row in a separate transaction so the rollback doesn't
-- touch it; see the comment block on the INSERT below).

BEGIN;

-- ─── 0. Setup: ensure Hannah has a (100 Free, gear='fins') PB ───
-- This PB must exist BEFORE we run the function. The probe uses a
-- savepoint so this row is rolled back too — but the row only exists
-- for the duration of the probe (BEGIN/ROLLBACK wraps it).
SAVEPOINT setup_hannah_fins;
INSERT INTO swimmer_pbs (swimmer_id, distance, stroke, time_ms, gear, intensity)
VALUES ('bea69b89-0426-4c51-9eef-29b40fa99715', 100, 'Free', 65000, 'fins', 'max')
ON CONFLICT (swimmer_id, distance, stroke, gear) DO UPDATE SET time_ms = 65000;

-- ─── 1. The "100 Free" worked example → Ethan ──────────────────
CREATE TEMP TABLE probe_setup_100free ON COMMIT DROP AS
WITH coach_pick AS (SELECT id AS coach_id FROM coaches LIMIT 1),
     new_workout AS (
       INSERT INTO workouts (coach_id, title)
       SELECT coach_id, 'pair-record-100free-probe-' || extract(epoch from now())::text
         FROM coach_pick
       RETURNING id
     ),
     new_set AS (
       INSERT INTO workout_sets (workout_id, order_index, reps, distance, stroke)
       SELECT id, 0, 4, 100, 'Free' FROM new_workout
       RETURNING id
     ),
     new_recorded AS (
      INSERT INTO recorded_times (
          workout_set_id, distance_meters, intensity, start_type,
          stroke, gear, time_ms, raw_text, rep_index
      )
      -- intensity='max' matches Ethan's seeded (distance=100, stroke=Free,
      -- gear='none', intensity='max') PB exactly — that's what makes
      -- the 100 Free case land on tier='exact_context', proving the
      -- predictions are context-keyed (distance + stroke + gear +
      -- intensity) not generic.
      SELECT s.id, 100, 'max', 'in_water', 'Free', NULL, 66282,
             '4 x 100 Free race', 1
        FROM new_set s
      RETURNING id, workout_set_id, time_ms
    )
SELECT id AS recorded_id, workout_set_id AS ws_id, time_ms
  FROM new_recorded;

CREATE TEMP TABLE probe_match_100free ON COMMIT DROP AS
SELECT recorded_time_id, swimmer_id, confidence, fallback_tier, matched
  FROM pair_recorded_times_for_set((SELECT ws_id FROM probe_setup_100free));

-- ─── 2. The "100 Free with fins" worked example → Hannah ────────
CREATE TEMP TABLE probe_setup_fins ON COMMIT DROP AS
WITH coach_pick AS (SELECT id AS coach_id FROM coaches LIMIT 1),
     new_workout AS (
       INSERT INTO workouts (coach_id, title)
       SELECT coach_id, 'pair-record-100free-fins-probe-' || extract(epoch from now())::text
         FROM coach_pick
       RETURNING id
     ),
     new_set AS (
       INSERT INTO workout_sets (workout_id, order_index, reps, distance, stroke, gear)
       SELECT id, 0, 4, 100, 'Free', ARRAY['fins']::text[] FROM new_workout
      RETURNING id
    ),
    new_recorded AS (
      INSERT INTO recorded_times (
          workout_set_id, distance_meters, intensity, start_type,
          stroke, gear, time_ms, raw_text, rep_index
      )
      -- intensity='max' matches the Hannah fins PB we INSERT above
      -- (distance=100, stroke=Free, gear='fins', intensity='max').
      -- Without gear='fins' in the row, the cost cell falls back to
      -- (distance, stroke) — which doesn't pick Hannah because her
      -- no-fins 100 Free PB is 73324ms (well off 65000). The gear key
      -- is what routes this row to Hannah.
      SELECT s.id, 100, 'max', 'in_water', 'Free', 'fins', 65000,
             '4 x 100 Free race with fins', 1
        FROM new_set s
      RETURNING id, workout_set_id, time_ms
    )
SELECT id AS recorded_id, workout_set_id AS ws_id, time_ms
  FROM new_recorded;

CREATE TEMP TABLE probe_match_100free_fins ON COMMIT DROP AS
SELECT recorded_time_id, swimmer_id, confidence, fallback_tier, matched
  FROM pair_recorded_times_for_set((SELECT ws_id FROM probe_setup_fins));

-- ─── 3. The no-fins comparison at 65000ms (same time, different swimmer) ──
CREATE TEMP TABLE probe_setup_nofins ON COMMIT DROP AS
WITH coach_pick AS (SELECT id AS coach_id FROM coaches LIMIT 1),
     new_workout AS (
       INSERT INTO workouts (coach_id, title)
       SELECT coach_id, 'pair-record-100free-nofins-probe-' || extract(epoch from now())::text
         FROM coach_pick
       RETURNING id
     ),
     new_set AS (
       INSERT INTO workout_sets (workout_id, order_index, reps, distance, stroke)
       SELECT id, 0, 4, 100, 'Free' FROM new_workout
       RETURNING id
     ),
     new_recorded AS (
       INSERT INTO recorded_times (
           workout_set_id, distance_meters, intensity, start_type,
           stroke, gear, time_ms, raw_text, rep_index
       )
       SELECT s.id, 100, 'race', 'in_water', 'Free', NULL, 65000,
              '4 x 100 Free race', 1
         FROM new_set s
       RETURNING id, workout_set_id, time_ms
     )
SELECT id AS recorded_id, workout_set_id AS ws_id, time_ms
  FROM new_recorded;

CREATE TEMP TABLE probe_match_100free_nofins ON COMMIT DROP AS
SELECT recorded_time_id, swimmer_id, confidence, fallback_tier, matched
  FROM pair_recorded_times_for_set((SELECT ws_id FROM probe_setup_nofins));

-- ─── 4. Assert ──────────────────────────────────────────────────
WITH probe(n, label, got_text, want_text) AS (
  -- (1) The "100 Free" worked example → Ethan.
  SELECT 1, '100 Free row matches Ethan (uuid b8c13ff4...)',
         (SELECT swimmer_id::text FROM probe_match_100free),
         'b8c13ff4-730e-4403-8ca5-d28a2bbecc09'
  UNION ALL SELECT 2, '100 Free confidence >= 0.5 (acceptance bar)',
         CASE WHEN (SELECT confidence FROM probe_match_100free) >= 0.5
              THEN '1' ELSE '0' END, '1'
  UNION ALL SELECT 3, '100 Free fallback_tier = exact_context',
         (SELECT fallback_tier FROM probe_match_100free), 'exact_context'
  UNION ALL SELECT 4, '100 Free matched = true',
         (SELECT matched::text FROM probe_match_100free), 'true'

  -- (2) The "100 Free with fins" worked example → Hannah.
  UNION ALL SELECT 5, '100 Free with fins row matches Hannah (uuid bea69b89...)',
         (SELECT swimmer_id::text FROM probe_match_100free_fins),
         'bea69b89-0426-4c51-9eef-29b40fa99715'
  UNION ALL SELECT 6, 'fins fallback_tier = exact_context',
         (SELECT fallback_tier FROM probe_match_100free_fins), 'exact_context'
  UNION ALL SELECT 7, 'fins confidence >= 0.5',
         CASE WHEN (SELECT confidence FROM probe_match_100free_fins) >= 0.5
              THEN '1' ELSE '0' END, '1'

  -- (3) The CONTEXT-KEYING proof: same time_ms (65000), different
  -- gear → different swimmer. The no-fins 65000ms row should NOT
  -- match Hannah (her no-fins PB is 73324, way off 65000).
  UNION ALL SELECT 8, 'context-keying: no-fins 65000 row does NOT match Hannah',
         CASE WHEN (SELECT swimmer_id FROM probe_match_100free_nofins)
                   = 'bea69b89-0426-4c51-9eef-29b40fa99715'::uuid
              THEN '0' ELSE '1' END, '1'
  UNION ALL SELECT 9, 'context-keying: no-fins and fins picks DIFFERENT swimmers',
         CASE WHEN (SELECT swimmer_id FROM probe_match_100free_nofins)
                   <> (SELECT swimmer_id FROM probe_match_100free_fins)
              THEN '1' ELSE '0' END, '1'

  -- (4) The "100 Free" still resolves cleanly even with Hannah's
  -- new fins PB in the pool (proves exact gear matching, not
  -- gear-blind fallback).
  UNION ALL SELECT 10, 'context-keying: Hannah fins PB does NOT contaminate 100 Free no-fins match',
         CASE WHEN (SELECT swimmer_id FROM probe_match_100free)
                   = 'b8c13ff4-730e-4403-8ca5-d28a2bbecc09'::uuid
              THEN '1' ELSE '0' END, '1'
)
SELECT n, label, got_text AS got, want_text AS want,
       CASE WHEN got_text = want_text THEN 'PASS' ELSE 'FAIL' END AS result
FROM probe ORDER BY n;

-- Cleanup the savepoint so the Hannah fins PB rolls back too.
ROLLBACK TO SAVEPOINT setup_hannah_fins;
ROLLBACK;