-- hermes-verify: v1.17 S5 — squad visibility: swimmer reads teammates
--
-- The new policy is permissive ONLY when (a) the calling swimmer is a
-- member of the same group as the target swimmer, (b) that group is
-- scoped to the same coach, and (c) the group's settings has
-- attendance_visibility = 'squad'. The default 'private' must NOT
-- leak rows under any of the other predicates.
--
-- Rollback-wrapped. Two separate transactions so each scenario's
-- SET LOCAL role+jwt pair is independent and the rows reach stdout.

BEGIN;

INSERT INTO auth.users (id, instance_id, aud, role, email, created_at, updated_at)
VALUES ('00000000-0000-4000-8000-0000000000f1',
        '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated',
        'hermes-verify-s5@example.invalid', now(), now());

-- Stash the relevant ids in non-reserved columns.
CREATE TEMP TABLE ctx ON COMMIT DROP AS
SELECT
  (SELECT id FROM coaches WHERE name IS NOT NULL ORDER BY created_at LIMIT 1) AS coach_id,
  (SELECT id FROM groups WHERE coach_id = (SELECT id FROM coaches
                                    WHERE name IS NOT NULL ORDER BY created_at LIMIT 1)
                       LIMIT 1) AS group_id,
  (SELECT id FROM swimmers WHERE coach_id = (SELECT id FROM coaches
                                       WHERE name IS NOT NULL ORDER BY created_at LIMIT 1)
                       AND archived_at IS NULL ORDER BY created_at LIMIT 1) AS me_id,
  (SELECT id FROM swimmers WHERE coach_id = (SELECT id FROM coaches
                                       WHERE name IS NOT NULL ORDER BY created_at LIMIT 1)
                       AND archived_at IS NULL ORDER BY created_at OFFSET 1 LIMIT 1) AS them_id,
  (SELECT id FROM workouts WHERE scheduled_at IS NOT NULL
                       AND coach_id = (SELECT id FROM coaches
                                       WHERE name IS NOT NULL ORDER BY created_at LIMIT 1)
                       ORDER BY created_at LIMIT 1) AS workout_id;

-- 'me' authenticates as the swimmer; 'them' is a teammate.
UPDATE swimmers SET auth_id = '00000000-0000-4000-8000-0000000000f1'
WHERE id = (SELECT me_id FROM ctx);

-- Make sure 'me' and 'them' are both enrolled in the same group.
INSERT INTO swimmer_groups (swimmer_id, group_id)
SELECT id, (SELECT group_id FROM ctx) FROM swimmers
WHERE id IN (SELECT me_id FROM ctx) AND NOT EXISTS (
  SELECT 1 FROM swimmer_groups sg WHERE sg.swimmer_id = swimmers.id);

-- 'them' explicitly marks 'in' on the workout.
INSERT INTO swimmer_attendance_intent (workout_id, swimmer_id, intent, source)
SELECT (SELECT workout_id FROM ctx), (SELECT them_id FROM ctx), 'in', 'swimmer';

-- The squad is in 'squad' visibility mode for this scenario.
UPDATE groups SET settings = jsonb_set(settings, '{attendance_visibility}', '"squad"')
WHERE id = (SELECT group_id FROM ctx);

GRANT SELECT ON ctx TO authenticated;

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-4000-8000-0000000000f1","role":"authenticated"}';

WITH probe(n, label, got, want) AS (
  SELECT 1, 'squad mode: me reads them''s intent',
         (SELECT count(*)::text FROM swimmer_attendance_intent
            WHERE swimmer_id = (SELECT them_id FROM ctx)), '1'
  UNION ALL SELECT 2, 'squad mode: own intent still readable',
         (SELECT count(*)::text FROM swimmer_attendance_intent
            WHERE swimmer_id = (SELECT me_id FROM ctx)), '0'
  UNION ALL SELECT 3, 'squad mode: total visible',
         (SELECT count(*)::text FROM swimmer_attendance_intent), '1'
)
SELECT n, label, got, want,
       CASE WHEN got = want THEN 'PASS' ELSE 'FAIL' END AS result
FROM probe ORDER BY n;

ROLLBACK;
