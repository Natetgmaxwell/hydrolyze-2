-- hermes-verify: v1.17 Slice 7 — coach-side squad slot + visibility writes
--
-- Exercises the exact queries ScheduleService.setSquadSlot /
-- updateGroupSettings issue, under real RLS as the coach. Slice 1/2/4
-- probes already cover the read paths; this one pins the writes — the
-- part that ships the editor's value.
--
-- Rollback-wrapped. Runs as the coach.

BEGIN;

INSERT INTO auth.users (id, instance_id, aud, role, email, created_at, updated_at)
VALUES ('00000000-0000-4000-8000-0000000000e1',
        '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated',
        'hermes-verify-s7@example.invalid', now(), now());

-- Stash the coach and group ids in plain text columns so the rest of the
-- script has no nested subqueries. `group` is reserved in Postgres, so the
-- column is named `gid`; `coach` would alias but it's unused below.
CREATE TEMP TABLE ctx ON COMMIT DROP AS
SELECT
  (SELECT id FROM coaches WHERE name IS NOT NULL ORDER BY created_at LIMIT 1) AS coach_id,
  (SELECT id FROM groups WHERE coach_id = (SELECT id FROM coaches
                                    WHERE name IS NOT NULL ORDER BY created_at LIMIT 1)
                       LIMIT 1) AS gid;

UPDATE coaches SET auth_id = '00000000-0000-4000-8000-0000000000e1'
WHERE id = (SELECT coach_id FROM ctx);

GRANT SELECT ON ctx TO authenticated;

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-4000-8000-0000000000e1","role":"authenticated"}';

-- Mirror setSquadSlot: upsert on (group_id, weekday, am_pm). Saturday AM
-- "sprint" slot, then mutate to "pumpkin" and pause it.
INSERT INTO squad_session_slot (group_id, weekday, am_pm, label, active)
SELECT gid, 6, 'AM', 'sprint', true FROM ctx
ON CONFLICT (group_id, weekday, am_pm) DO UPDATE SET label = EXCLUDED.label;

UPDATE squad_session_slot SET label = 'pumpkin', active = false
WHERE group_id = (SELECT gid FROM ctx) AND weekday = 6 AND am_pm = 'AM';

-- Re-activate (the tap-to-recover path).
INSERT INTO squad_session_slot (group_id, weekday, am_pm, label, active)
SELECT gid, 6, 'AM', 'pumpkin', true FROM ctx
ON CONFLICT (group_id, weekday, am_pm) DO UPDATE SET active = EXCLUDED.active;

-- Mirror updateGroupSettings: toggle the visibility both ways.
UPDATE groups SET settings = jsonb_set(settings, '{attendance_visibility}', '"squad"')
WHERE id = (SELECT gid FROM ctx);
UPDATE groups SET settings = jsonb_set(settings, '{attendance_visibility}', '"private"')
WHERE id = (SELECT gid FROM ctx);

-- Every probe value is cast to text so the UNION types agree without
-- per-row gymnastics. Counts and booleans round-trip cleanly.
WITH probe(n, label, got, want) AS (
  SELECT 1, 'slot exists at the (group, weekday, am_pm) key',
         (SELECT count(*)::text FROM squad_session_slot
            WHERE group_id = (SELECT gid FROM ctx) AND weekday = 6 AND am_pm = 'AM'),
         '1'
  UNION ALL SELECT 2, 'label was updated to "pumpkin"',
         (SELECT label FROM squad_session_slot
            WHERE group_id = (SELECT gid FROM ctx) AND weekday = 6 AND am_pm = 'AM'),
         'pumpkin'
  UNION ALL SELECT 3, 're-activation reset active=true',
         (SELECT active::text FROM squad_session_slot
            WHERE group_id = (SELECT gid FROM ctx) AND weekday = 6 AND am_pm = 'AM'),
         'true'
  UNION ALL SELECT 4, 'exactly one row per (group, slot) key',
         (SELECT count(*)::text FROM squad_session_slot
            WHERE group_id = (SELECT gid FROM ctx) AND weekday = 6 AND am_pm = 'AM'),
         '1'
  UNION ALL SELECT 5, 'settings jsonb is still an object',
         (SELECT jsonb_typeof(settings) FROM groups WHERE id = (SELECT gid FROM ctx)),
         'object'
  UNION ALL SELECT 6, 'attendance_visibility round-trips',
         (SELECT settings->>'attendance_visibility' FROM groups
            WHERE id = (SELECT gid FROM ctx)),
         'private'
  UNION ALL SELECT 7, 'coach reads all their slots incl. inactive',
         (SELECT count(*)::text FROM squad_session_slot WHERE group_id = (SELECT gid FROM ctx)),
         (SELECT count(*)::text FROM squad_session_slot WHERE group_id = (SELECT gid FROM ctx))
)
SELECT n, label, got, want,
       CASE WHEN got = want THEN 'PASS' ELSE 'FAIL' END AS result
FROM probe ORDER BY n;

ROLLBACK;
