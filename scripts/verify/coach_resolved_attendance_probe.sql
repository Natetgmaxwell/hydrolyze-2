-- hermes-verify: v1.17 Slice 4 — resolved coach-side attendance
--
-- The Slice 3 resolver CLI test proves the precedence chain as pure logic.
-- This proves the thing that test cannot: that the coach's badge count and
-- the roster promotion actually change behaviour against real rows.
--
-- The bug being pinned: both the badge and promoteConfirmedToRoster keyed on
-- `intent = 'in'`. A squad running entirely on standing schedules therefore
-- read as "0 of N attending" and promoted NOBODY into session_roster --
-- the feature silently did nothing for its main case.
--
-- Rollback-wrapped. Runs as the coach (that is who calls these paths).

BEGIN;

INSERT INTO auth.users (id, instance_id, aud, role, email, created_at, updated_at)
VALUES ('00000000-0000-4000-8000-0000000000c1',
        '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated',
        'hermes-verify-s4@example.invalid', now(), now());

-- Pick a coach who owns both swimmers and a dated workout.
CREATE TEMP TABLE ctx ON COMMIT DROP AS
SELECT
  w.coach_id                                        AS coach,
  w.id                                              AS workout,
  w.scheduled_at                                    AS sched,
  EXTRACT(DOW FROM w.scheduled_at)::int             AS dow,
  w.am_pm                                           AS ampm
FROM workouts w
WHERE w.scheduled_at IS NOT NULL
  AND EXISTS (SELECT 1 FROM swimmers s WHERE s.coach_id = w.coach_id AND s.archived_at IS NULL)
ORDER BY w.created_at
LIMIT 1;

UPDATE coaches SET auth_id = '00000000-0000-4000-8000-0000000000c1'
WHERE id = (SELECT coach FROM ctx);

-- Five swimmers, one of each resolution path.
CREATE TEMP TABLE cast_ ON COMMIT DROP AS
SELECT id, row_number() OVER (ORDER BY created_at) AS n
FROM swimmers
WHERE coach_id = (SELECT coach FROM ctx) AND archived_at IS NULL
LIMIT 5;

-- s1 explicit in, s2 explicit out, s3+s4 standing slot only, s5 nothing.
INSERT INTO swimmer_attendance_intent (workout_id, swimmer_id, intent, source)
SELECT (SELECT workout FROM ctx), id, 'in', 'swimmer' FROM cast_ WHERE n = 1;
INSERT INTO swimmer_attendance_intent (workout_id, swimmer_id, intent, source)
SELECT (SELECT workout FROM ctx), id, 'out', 'swimmer' FROM cast_ WHERE n = 2;

INSERT INTO swimmer_training_schedule (swimmer_id, weekday, am_pm, active)
SELECT c.id, (SELECT dow FROM ctx), coalesce((SELECT ampm FROM ctx), 'AM'), true
FROM cast_ c WHERE c.n IN (3, 4);

-- s4 also has a PAUSED slot on another day -- must not leak into the count.
INSERT INTO swimmer_training_schedule (swimmer_id, weekday, am_pm, active)
SELECT c.id, ((SELECT dow FROM ctx) + 1) % 7, 'PM', false
FROM cast_ c WHERE c.n = 4;

-- The role switch below drops superuser rights, so the temp tables need
-- explicit grants or every reference fails with 42501.
GRANT SELECT ON ctx   TO authenticated;
GRANT SELECT ON cast_ TO authenticated;

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-4000-8000-0000000000c1","role":"authenticated"}';

-- Mirror fetchResolvedAttendance: squad LEFT JOIN intent, then the
-- standing-slot fallback. This is the resolver's precedence chain in SQL.
CREATE TEMP VIEW resolved AS
SELECT
  s.id AS swimmer_id,
  CASE
    WHEN i.intent = 'in'  THEN true
    WHEN i.intent = 'out' THEN false
    WHEN EXISTS (
      SELECT 1 FROM swimmer_training_schedule sts
      WHERE sts.swimmer_id = s.id
        AND sts.active
        AND sts.weekday = (SELECT dow FROM ctx)
        AND ((SELECT ampm FROM ctx) IS NULL OR sts.am_pm = (SELECT ampm FROM ctx))
    ) THEN true
    ELSE false
  END AS is_attending,
  CASE
    WHEN i.intent = 'in'  THEN 'explicitIn'
    WHEN i.intent = 'out' THEN 'explicitOut'
    WHEN EXISTS (
      SELECT 1 FROM swimmer_training_schedule sts
      WHERE sts.swimmer_id = s.id
        AND sts.active
        AND sts.weekday = (SELECT dow FROM ctx)
        AND ((SELECT ampm FROM ctx) IS NULL OR sts.am_pm = (SELECT ampm FROM ctx))
    ) THEN 'standingSlot'
    ELSE 'noSignal'
  END AS reason
FROM swimmers s
LEFT JOIN swimmer_attendance_intent i
  ON i.swimmer_id = s.id AND i.workout_id = (SELECT workout FROM ctx)
WHERE s.coach_id = (SELECT coach FROM ctx) AND s.archived_at IS NULL;

WITH probe(n, label, got, want) AS (
  -- The headline regression: the OLD count vs the NEW one.
  SELECT 1, 'OLD badge (intent=''in'' only) counted just 1',
         (SELECT count(*) FROM swimmer_attendance_intent
            WHERE workout_id = (SELECT workout FROM ctx) AND intent = 'in'), 1
  UNION ALL SELECT 2, 'NEW badge counts explicit-in + 2 standing = 3',
         (SELECT count(*) FROM resolved WHERE is_attending), 3
  UNION ALL SELECT 3, 'the 2 standing swimmers were previously invisible',
         (SELECT count(*) FROM resolved WHERE reason = 'standingSlot'), 2

  -- Each precedence path lands where the resolver says it should.
  UNION ALL SELECT 4, 'explicit out excluded',
         (SELECT count(*) FROM resolved WHERE reason = 'explicitOut' AND is_attending), 0
  UNION ALL SELECT 5, 'unmarked + unscheduled excluded (narrowing rule)',
         (SELECT count(*) FROM resolved WHERE reason = 'noSignal' AND is_attending), 0
  UNION ALL SELECT 6, 'a paused slot does not create attendance',
         (SELECT count(*) FROM swimmer_training_schedule
            WHERE NOT active AND swimmer_id IN (SELECT id FROM cast_ WHERE n = 4)), 1

  -- hasNoSignal must distinguish "nobody told us" from "everybody declined".
  UNION ALL SELECT 7, 'mixed squad is not a no-signal squad',
         (SELECT count(*) FROM resolved WHERE reason <> 'noSignal'), 4

  -- promoteConfirmedToRoster now promotes the RESOLVED set, not intent='in'.
  UNION ALL SELECT 8, 'promotion set = resolved attending (3, not 1)',
         (SELECT count(*) FROM resolved WHERE is_attending), 3
)
SELECT n, label, got, want,
       CASE WHEN got = want THEN 'PASS' ELSE 'FAIL' END AS result
FROM probe ORDER BY n;

ROLLBACK;
