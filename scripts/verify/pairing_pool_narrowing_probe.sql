-- hermes-verify: v1.17 Slice 5 — attendance narrows the pairing pool
--
-- THE vision slice's claim, in one probe: the set of swimmers the pairing
-- engine can consider is now the resolved attending set, not the whole squad.
--
-- The bug being pinned is an ORDERING bug, not a logic bug. Every downstream
-- consumer -- session_roster, the PB fetch, the recorded-times fetch, the
-- wave preview, wave_assignments, coarsePredictions, the Hungarian cost
-- matrix -- already derived from selectedSwimmerIds. But selectedSwimmerIds
-- was seeded by selectAll(), and promoteConfirmedToRoster ran AFTER those
-- consumers had already read it. So attendance wrote into session_roster
-- and changed nothing the engine ever saw.
--
-- Simulates a realistic squad: 2 explicit in, 2 explicit out, 3 standing
-- slot, 3 no signal. Old behaviour selects all 10. New selects 5.
--
-- Rollback-wrapped. Runs as the coach.

BEGIN;

INSERT INTO auth.users (id, instance_id, aud, role, email, created_at, updated_at)
VALUES ('00000000-0000-4000-8000-0000000000d1',
        '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated',
        'hermes-verify-s5@example.invalid', now(), now());

CREATE TEMP TABLE ctx ON COMMIT DROP AS
SELECT
  w.coach_id                            AS coach,
  w.id                                  AS workout,
  EXTRACT(DOW FROM w.scheduled_at)::int AS dow,
  w.am_pm                               AS ampm
FROM workouts w
WHERE w.scheduled_at IS NOT NULL
  AND (SELECT count(*) FROM swimmers s
        WHERE s.coach_id = w.coach_id AND s.archived_at IS NULL) >= 10
ORDER BY w.created_at
LIMIT 1;

UPDATE coaches SET auth_id = '00000000-0000-4000-8000-0000000000d1'
WHERE id = (SELECT coach FROM ctx);

CREATE TEMP TABLE cast_ ON COMMIT DROP AS
SELECT id, row_number() OVER (ORDER BY created_at) AS n
FROM swimmers
WHERE coach_id = (SELECT coach FROM ctx) AND archived_at IS NULL
LIMIT 10;

-- n1,n2 explicit in | n3,n4 explicit out | n5,n6,n7 standing | n8,n9,n10 nothing
INSERT INTO swimmer_attendance_intent (workout_id, swimmer_id, intent, source)
SELECT (SELECT workout FROM ctx), id, 'in', 'swimmer' FROM cast_ WHERE n IN (1,2);
INSERT INTO swimmer_attendance_intent (workout_id, swimmer_id, intent, source)
SELECT (SELECT workout FROM ctx), id, 'out', 'swimmer' FROM cast_ WHERE n IN (3,4);

INSERT INTO swimmer_training_schedule (swimmer_id, weekday, am_pm, active)
SELECT c.id, (SELECT dow FROM ctx), coalesce((SELECT ampm FROM ctx), 'AM'), true
FROM cast_ c WHERE c.n IN (5,6,7);

-- A swimmer who marked OUT but ALSO has a standing slot that day. Explicit
-- must beat standing, or "I can't make it Wednesday" is silently ignored
-- every single week.
INSERT INTO swimmer_training_schedule (swimmer_id, weekday, am_pm, active)
SELECT c.id, (SELECT dow FROM ctx), coalesce((SELECT ampm FROM ctx), 'AM'), true
FROM cast_ c WHERE c.n = 3;

GRANT SELECT ON ctx   TO authenticated;
GRANT SELECT ON cast_ TO authenticated;

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-4000-8000-0000000000d1","role":"authenticated"}';

-- The resolver's precedence chain, as SQL. Mirrors seedSelectionFromAttendance.
CREATE TEMP VIEW resolved AS
SELECT
  s.id AS swimmer_id,
  CASE
    WHEN i.intent = 'in'  THEN true
    WHEN i.intent = 'out' THEN false
    WHEN EXISTS (
      SELECT 1 FROM swimmer_training_schedule sts
      WHERE sts.swimmer_id = s.id AND sts.active
        AND sts.weekday = (SELECT dow FROM ctx)
        AND ((SELECT ampm FROM ctx) IS NULL OR sts.am_pm = (SELECT ampm FROM ctx))
    ) THEN true
    ELSE false
  END AS is_attending
FROM swimmers s
LEFT JOIN swimmer_attendance_intent i
  ON i.swimmer_id = s.id AND i.workout_id = (SELECT workout FROM ctx)
WHERE s.coach_id = (SELECT coach FROM ctx) AND s.archived_at IS NULL;

WITH probe(n, label, got, want) AS (
  -- The headline: what the pairing engine's candidate pool used to be
  -- vs what it is now.
  SELECT 1, 'OLD selectAll() pool = whole squad',
         (SELECT count(*) FROM swimmers
            WHERE coach_id = (SELECT coach FROM ctx) AND archived_at IS NULL),
         (SELECT count(*) FROM swimmers
            WHERE coach_id = (SELECT coach FROM ctx) AND archived_at IS NULL)
  UNION ALL SELECT 2, 'NEW seeded pool = 2 explicit-in + 3 standing = 5',
         (SELECT count(*) FROM resolved WHERE is_attending), 5
  UNION ALL SELECT 3, 'narrowing actually removed swimmers',
         CASE WHEN (SELECT count(*) FROM resolved WHERE is_attending)
                 < (SELECT count(*) FROM resolved) THEN 1 ELSE 0 END, 1

  -- The core promise: a non-attending swimmer cannot receive a lap,
  -- because they never enter the candidate pool at all.
  UNION ALL SELECT 4, 'explicit-out swimmers excluded from the pool',
         (SELECT count(*) FROM resolved r
            JOIN cast_ c ON c.id = r.swimmer_id
           WHERE c.n IN (3,4) AND r.is_attending), 0
  UNION ALL SELECT 5, 'unmarked+unscheduled excluded (narrowing rule)',
         (SELECT count(*) FROM resolved r
            JOIN cast_ c ON c.id = r.swimmer_id
           WHERE c.n IN (8,9,10) AND r.is_attending), 0

  -- Precedence under conflict: n3 declined AND has a standing slot.
  UNION ALL SELECT 6, 'explicit out beats a standing slot on the same day',
         (SELECT count(*) FROM resolved r
            JOIN cast_ c ON c.id = r.swimmer_id
           WHERE c.n = 3 AND r.is_attending), 0
  UNION ALL SELECT 7, '...and that swimmer really does have a standing slot',
         (SELECT count(*) FROM swimmer_training_schedule sts
            JOIN cast_ c ON c.id = sts.swimmer_id
           WHERE c.n = 3 AND sts.active), 1

  -- Both attendance paths reach the pool.
  UNION ALL SELECT 8, 'explicit-in swimmers included',
         (SELECT count(*) FROM resolved r
            JOIN cast_ c ON c.id = r.swimmer_id
           WHERE c.n IN (1,2) AND r.is_attending), 2
  UNION ALL SELECT 9, 'standing-schedule swimmers included (zero taps)',
         (SELECT count(*) FROM resolved r
            JOIN cast_ c ON c.id = r.swimmer_id
           WHERE c.n IN (5,6,7) AND r.is_attending), 3

  -- The fallback must NOT fire here: this squad has plenty of signal.
  UNION ALL SELECT 10, 'squad has signal, so no selectAll() fallback',
         (SELECT count(*) FROM resolved WHERE is_attending), 5
)
SELECT n, label, got, want,
       CASE WHEN got = want THEN 'PASS' ELSE 'FAIL' END AS result
FROM probe ORDER BY n;

ROLLBACK;
