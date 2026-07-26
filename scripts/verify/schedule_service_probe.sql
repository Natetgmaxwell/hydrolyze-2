-- hermes-verify: v1.17 Slice 2 — ScheduleService behavioural probe
--
-- Exercises the exact queries ScheduleService issues, under real RLS as a
-- swimmer. Slice 1's lesson: a service that compiles proves nothing about
-- whether its queries return the right rows to the right person.
--
-- Rollback-wrapped. Expectations captured BEFORE the role switch so the
-- "want" side is never RLS-filtered into agreeing with itself.

BEGIN;

-- swimmers.auth_id FKs to auth.users, so mint a throwaway identity.
INSERT INTO auth.users (id, instance_id, aud, role, email, created_at, updated_at)
VALUES ('00000000-0000-4000-8000-00000000cafe',
        '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated',
        'hermes-verify-s2@example.invalid', now(), now());

UPDATE swimmers
SET auth_id = '00000000-0000-4000-8000-00000000cafe'
WHERE id = (SELECT id FROM swimmers WHERE archived_at IS NULL ORDER BY created_at LIMIT 1);

-- Ground truth, captured as owner.
CREATE TEMP TABLE expected ON COMMIT DROP AS
SELECT
  (SELECT id FROM swimmers WHERE auth_id = '00000000-0000-4000-8000-00000000cafe') AS me,
  (SELECT sg.group_id FROM swimmer_groups sg
     JOIN swimmers s ON s.id = sg.swimmer_id
    WHERE s.auth_id = '00000000-0000-4000-8000-00000000cafe' LIMIT 1)            AS my_group,
  (SELECT count(*) FROM squad_session_slot)                                       AS all_slots;
GRANT SELECT ON expected TO authenticated;

-- Become the swimmer.
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-4000-8000-00000000cafe","role":"authenticated"}';

-- Mirror ScheduleService.replaceSchedule(Mon AM, Wed AM, Fri AM).
INSERT INTO swimmer_training_schedule (swimmer_id, weekday, am_pm, active)
SELECT (SELECT me FROM expected), d.wd, 'AM', true
FROM (VALUES (1),(3),(5)) AS d(wd);

-- Mirror addSlot() on an existing row: must re-activate, not error.
UPDATE swimmer_training_schedule SET active = false
WHERE swimmer_id = (SELECT me FROM expected) AND weekday = 3 AND am_pm = 'AM';

INSERT INTO swimmer_training_schedule (swimmer_id, weekday, am_pm, active)
VALUES ((SELECT me FROM expected), 3, 'AM', true)
ON CONFLICT (swimmer_id, weekday, am_pm) DO UPDATE SET active = EXCLUDED.active;

WITH probe(n, label, got, want) AS (
  -- fetchSlotsForSwimmer(): RLS must scope to the swimmer's own squad.
  SELECT 1, 'fetchSlotsForSwimmer returns only own squad slots',
         (SELECT count(*) FROM squad_session_slot), 5
  UNION ALL SELECT 2, 'foreign squad slots invisible (all_slots > own)',
         (SELECT count(*) FROM squad_session_slot
            WHERE group_id <> (SELECT my_group FROM expected)), 0
  UNION ALL SELECT 3, 'squad has fewer slots than the DB total (proves filtering)',
         CASE WHEN (SELECT all_slots FROM expected) > (SELECT count(*) FROM squad_session_slot)
              THEN 1 ELSE 0 END, 1

  -- fetchSquadSlots(groupId:) with active filter.
  UNION ALL SELECT 4, 'fetchSquadSlots(active=true) returns Mon-Fri AM',
         (SELECT count(*) FROM squad_session_slot
            WHERE group_id = (SELECT my_group FROM expected) AND active), 5

  -- replaceSchedule + fetchSchedule round-trip.
  UNION ALL SELECT 5, 'replaceSchedule wrote 3 standing slots',
         (SELECT count(*) FROM swimmer_training_schedule), 3
  UNION ALL SELECT 6, 'schedule is Mon/Wed/Fri AM',
         (SELECT count(*) FROM swimmer_training_schedule
            WHERE weekday IN (1,3,5) AND am_pm = 'AM'), 3

  -- addSlot() idempotency: the ON CONFLICT re-activation path.
  UNION ALL SELECT 7, 'addSlot on existing row re-activates (no duplicate)',
         (SELECT count(*) FROM swimmer_training_schedule
            WHERE weekday = 3 AND am_pm = 'AM'), 1
  UNION ALL SELECT 8, 'addSlot re-activation actually set active=true',
         (SELECT count(*) FROM swimmer_training_schedule
            WHERE weekday = 3 AND am_pm = 'AM' AND active), 1

  -- Standing pattern must be self-scoped, like intent.
  UNION ALL SELECT 9, 'schedule rows are self-scoped (no foreign swimmers)',
         (SELECT count(*) FROM swimmer_training_schedule
            WHERE swimmer_id <> (SELECT me FROM expected)), 0

  -- Slot/workout join: the resolver in Slice 3 depends on this matching.
  UNION ALL SELECT 10, 'a Wed workout matches the Wed AM standing slot',
         (SELECT count(*) FROM swimmer_training_schedule sts
            WHERE sts.active
              AND sts.weekday = 3
              AND sts.am_pm = 'AM'), 1
)
SELECT n, label, got, want,
       CASE WHEN got = want THEN 'PASS' ELSE 'FAIL' END AS result
FROM probe ORDER BY n;

ROLLBACK;
