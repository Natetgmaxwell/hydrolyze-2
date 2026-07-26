-- hermes-verify: v1.17 Slice 1 behavioural probe
-- Ad-hoc verification, NOT a test suite. Impersonates a swimmer through RLS
-- and asserts the attendance read/write path actually admits the right rows.
-- Existence checks (already run) prove objects exist; this proves POLICIES work.
-- Everything runs inside a transaction that is ROLLED BACK.

BEGIN;

-- swimmers.auth_id has an FK to auth.users, so mint a throwaway auth user.
-- Rolled back at the end; nothing persists.
INSERT INTO auth.users (id, instance_id, aud, role, email, created_at, updated_at)
VALUES ('00000000-0000-4000-8000-00000000beef',
        '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated',
        'hermes-verify@example.invalid', now(), now());

-- Give one seeded swimmer that identity so RLS has something to match.
UPDATE swimmers
SET auth_id = '00000000-0000-4000-8000-00000000beef'
WHERE id = (SELECT id FROM swimmers WHERE archived_at IS NULL ORDER BY created_at LIMIT 1);

-- Seed the writes as the owner first, then verify visibility as the swimmer.
INSERT INTO swimmer_training_schedule (swimmer_id, weekday, am_pm)
SELECT id, 3, 'AM' FROM swimmers WHERE auth_id = '00000000-0000-4000-8000-00000000beef';

INSERT INTO swimmer_attendance_intent (workout_id, swimmer_id, intent, source)
SELECT (SELECT id FROM workouts ORDER BY created_at LIMIT 1),
       id, 'in', 'swimmer'
FROM swimmers WHERE auth_id = '00000000-0000-4000-8000-00000000beef';

-- Capture ground truth BEFORE the role switch, or the "want" side would be
-- RLS-filtered too and every assertion would be tautologically true.
CREATE TEMP TABLE expected ON COMMIT DROP AS
SELECT
  (SELECT count(*) FROM workouts w
   WHERE w.coach_id = (SELECT coach_id FROM swimmers
                       WHERE auth_id = '00000000-0000-4000-8000-00000000beef')
  ) AS own_coach_workouts,
  (SELECT count(*) FROM workouts) AS all_workouts;

GRANT SELECT ON expected TO authenticated;

-- Now become the swimmer. Every count below is RLS-filtered.
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-4000-8000-00000000beef","role":"authenticated"}';

WITH probe(n, label, got, want) AS (
  SELECT 1, 'swimmer sees only own swimmer row',
         (SELECT count(*) FROM swimmers), 1
  UNION ALL SELECT 2, 'swimmer reads own coach''s workouts (0 before RLS fix)',
         (SELECT count(*) FROM workouts),
         (SELECT own_coach_workouts FROM expected)
  UNION ALL SELECT 9, 'foreign coach''s workouts are hidden',
         (SELECT all_workouts - own_coach_workouts FROM expected)
         - ((SELECT all_workouts FROM expected) - (SELECT count(*) FROM workouts)), 0
  UNION ALL SELECT 3, 'swimmer reads own squad only',
         (SELECT count(*) FROM groups), 1
  UNION ALL SELECT 4, 'swimmer reads own membership only',
         (SELECT count(*) FROM swimmer_groups), 1
  UNION ALL SELECT 5, 'swimmer reads own squad session slots (Mon-Fri AM)',
         (SELECT count(*) FROM squad_session_slot), 5
  UNION ALL SELECT 6, 'swimmer sees no foreign squad slots',
         (SELECT count(*) FROM squad_session_slot
            WHERE group_id NOT IN (SELECT group_id FROM swimmer_groups)), 0
  UNION ALL SELECT 7, 'swimmer reads own standing schedule',
         (SELECT count(*) FROM swimmer_training_schedule), 1
  UNION ALL SELECT 8, 'swimmer reads own intent',
         (SELECT count(*) FROM swimmer_attendance_intent), 1
)
SELECT n, label, got, want,
       CASE WHEN got = want THEN 'PASS' ELSE 'FAIL' END AS result
FROM probe ORDER BY n;

ROLLBACK;
