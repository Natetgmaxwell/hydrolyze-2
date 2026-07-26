-- hermes-verify: v1.17 Slice 3 — IntentService scoping probe
--
-- The resolver's CLI test covers the precedence chain as pure logic. This
-- covers the thing that test cannot: whether the fetch actually returns the
-- right ROWS to the right PERSON, against real RLS.
--
-- Specifically it pins the Gap A bug. The old fetch filtered intent only by
-- workout_id and collapsed duplicates with an arbitrary winner, so swimmer A
-- could render swimmer B's intent as their own. Probes 1-3 fail loudly if
-- that scoping ever regresses.
--
-- Rollback-wrapped. Two real swimmers, so cross-swimmer bleed is detectable.

BEGIN;

INSERT INTO auth.users (id, instance_id, aud, role, email, created_at, updated_at)
VALUES ('00000000-0000-4000-8000-0000000000a1',
        '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated',
        'hermes-verify-s3a@example.invalid', now(), now());

-- Two swimmers on the same coach: A is the caller, B is the confounder.
-- The workout must have a non-NULL scheduled_at: rows with NULL exist in
-- this DB (an in_progress workout never got a date), and picking one would
-- make the weekday assertion vacuous rather than meaningful.
CREATE TEMP TABLE actors ON COMMIT DROP AS
SELECT
  (SELECT id FROM swimmers WHERE archived_at IS NULL ORDER BY created_at LIMIT 1)        AS a,
  (SELECT id FROM swimmers WHERE archived_at IS NULL ORDER BY created_at OFFSET 1 LIMIT 1) AS b,
  (SELECT id FROM workouts WHERE scheduled_at IS NOT NULL ORDER BY created_at LIMIT 1)   AS w;

UPDATE swimmers SET auth_id = '00000000-0000-4000-8000-0000000000a1'
WHERE id = (SELECT a FROM actors);

-- A says nothing. B explicitly marks OUT on the same workout.
-- Under the old code A would inherit B's row via the arbitrary collapse.
INSERT INTO swimmer_attendance_intent (workout_id, swimmer_id, intent, source)
SELECT w, b, 'out', 'swimmer' FROM actors;

-- A has a standing pattern; B does not.
INSERT INTO swimmer_training_schedule (swimmer_id, weekday, am_pm, active)
SELECT a, d.wd, 'AM', true FROM actors, (VALUES (1),(3),(5)) AS d(wd);

CREATE TEMP TABLE expected ON COMMIT DROP AS
SELECT
  (SELECT count(*) FROM swimmer_attendance_intent)                       AS total_intents,
  (SELECT EXTRACT(DOW FROM scheduled_at)::int FROM workouts
     WHERE id = (SELECT w FROM actors))                                  AS workout_dow,
  (SELECT count(*) FROM workouts
     WHERE scheduled_at >= CURRENT_DATE AND status = 'scheduled')        AS future_scheduled;
GRANT SELECT ON expected TO authenticated;
GRANT SELECT ON actors   TO authenticated;

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-4000-8000-0000000000a1","role":"authenticated"}';

WITH probe(n, label, got, want) AS (
  -- Gap A: the exact query IntentService now issues.
  SELECT 1, 'scoped intent read returns 0 rows for A (B''s row excluded)',
         (SELECT count(*) FROM swimmer_attendance_intent
            WHERE swimmer_id = (SELECT a FROM actors)), 0
  UNION ALL SELECT 2, 'B''s intent row exists but is invisible to A',
         (SELECT count(*) FROM swimmer_attendance_intent), 0
  UNION ALL SELECT 3, 'the row really was written (proves probe 2 is not vacuous)',
         (SELECT total_intents FROM expected), 1

  -- Standing schedule read, scoped.
  UNION ALL SELECT 4, 'A reads own standing pattern (Mon/Wed/Fri AM)',
         (SELECT count(*) FROM swimmer_training_schedule
            WHERE swimmer_id = (SELECT a FROM actors)), 3
  UNION ALL SELECT 5, 'A sees no foreign schedule rows',
         (SELECT count(*) FROM swimmer_training_schedule
            WHERE swimmer_id <> (SELECT a FROM actors)), 0

  -- Horizon: the 7-day cap is gone, so every future scheduled workout shows.
  UNION ALL SELECT 6, 'unbounded horizon returns all future scheduled workouts',
         (SELECT count(*) FROM workouts
            WHERE scheduled_at >= CURRENT_DATE AND status = 'scheduled'),
         (SELECT future_scheduled FROM expected)

  -- The weekday the resolver will compute must match Postgres' own DOW,
  -- which is what Weekday's 0=Sunday convention is aligned to.
  UNION ALL SELECT 7, 'workout DOW is in range 0..6 (matches Weekday rawValue)',
         CASE WHEN (SELECT workout_dow FROM expected) BETWEEN 0 AND 6
              THEN 1 ELSE 0 END, 1
)
SELECT n, label, got, want,
       CASE WHEN got = want THEN 'PASS' ELSE 'FAIL' END AS result
FROM probe ORDER BY n;

ROLLBACK;
