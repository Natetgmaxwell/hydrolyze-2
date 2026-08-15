-- hermes-verify: V0.38 Slice 1 — 3MT mode RLS probe
--
-- The Slice 1 migration adds workouts.session_type and the
-- swimmer_test_profiles table with the same coach-owns-swimmer RLS pattern
-- as swimmer_pbs. Existence checks (run separately) prove the objects
-- exist; this probe proves the policies actually admit the right rows to
-- the right people, and that the iOS save path works under RLS.
--
-- Rollback-wrapped. Two impersonated coaches: the owner of the seeded
-- profile row, and an unrelated coach with no roster.

BEGIN;

-- Throwaway auth users: A is the owner coach; B is an unrelated coach.
-- Each INSERT triggers handle_new_user, which auto-creates a coach row
-- whose auth_id is set to the new user. Rolled back at the end so nothing
-- persists.
INSERT INTO auth.users (id, instance_id, aud, role, email, created_at, updated_at)
VALUES ('00000000-0000-4000-8000-00000000a301',
        '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated',
        'hermes-3mt-a@example.invalid', now(), now());

INSERT INTO auth.users (id, instance_id, aud, role, email, created_at, updated_at)
VALUES ('00000000-0000-4000-8000-00000000a302',
        '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated',
        'hermes-3mt-b@example.invalid', now(), now());

-- The handle_new_user trigger only fires on GoTrue signups, not on direct
-- auth.users INSERTs (verified live 2026-08-15), so create the coach rows
-- explicitly.
INSERT INTO coaches (id, auth_id, name)
VALUES ('00000000-0000-4000-8000-000000c0a401',
        '00000000-0000-4000-8000-00000000a301', 'Probe Coach A');
INSERT INTO coaches (id, auth_id, name)
VALUES ('00000000-0000-4000-8000-000000c0a402',
        '00000000-0000-4000-8000-00000000a302', 'Probe Coach B');

-- Resolve the auto-created coaches.
CREATE TEMP TABLE ctx ON COMMIT DROP AS
SELECT
  (SELECT id FROM coaches
     WHERE auth_id = '00000000-0000-4000-8000-00000000a301') AS coach_a,
  (SELECT id FROM coaches
     WHERE auth_id = '00000000-0000-4000-8000-00000000a302') AS coach_b;

-- Coach A gets a swimmer + a 3MT profile row. Seeded as superuser so the
-- rows exist independently of any policy behaviour.
INSERT INTO swimmers (id, coach_id, name)
VALUES ('00000000-0000-4000-8000-000000005301',
        (SELECT coach_a FROM ctx),
        'Probe Swimmer A');

INSERT INTO swimmer_test_profiles (swimmer_id, peak_speed_mps, critical_speed_mps, battery_m)
VALUES ('00000000-0000-4000-8000-000000005301', 2.10, 1.65, 28.5);

-- Capture ground truth BEFORE the role switch, or the "want" side would
-- be RLS-filtered too and every assertion would be tautologically true.
CREATE TEMP TABLE expected ON COMMIT DROP AS
SELECT
  (SELECT count(*) FROM swimmer_test_profiles)                                  AS all_profiles,
  (SELECT count(*) FROM swimmers
     WHERE coach_id = (SELECT coach_a FROM ctx))                                AS a_swimmers,
  (SELECT count(*) FROM swimmers
     WHERE coach_id = (SELECT coach_b FROM ctx))                                AS b_swimmers,
  (SELECT count(*) FROM workouts)                                               AS all_workouts;
GRANT SELECT ON expected TO authenticated;
GRANT SELECT ON ctx     TO authenticated;

-- ── Probe as Coach A (the owner) ────────────────────────────────────────────
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-4000-8000-00000000a301","role":"authenticated"}';

-- iOS save path: coach inserts a 3MT profile + a workout under RLS.
-- If the policy is wrong the INSERT raises; if the default is wrong the
-- select below returns a non-training session_type.
INSERT INTO swimmer_test_profiles (swimmer_id, peak_speed_mps, critical_speed_mps, battery_m)
VALUES ('00000000-0000-4000-8000-000000005301', 2.05, 1.60, 26.0);

INSERT INTO workouts (coach_id, title)
VALUES ((SELECT coach_a FROM ctx), '3MT Probe Workout');

WITH probe(n, label, got, want) AS (
  SELECT 1, 'coach A sees own swimmer''s 3MT profile rows (seeded 1 + iOS insert 1 = 2)',
         (SELECT count(*)::text FROM swimmer_test_profiles), '2'
  UNION ALL SELECT 2, 'coach A sees exactly 1 swimmer (own; none of coach B''s)',
         (SELECT count(*)::text FROM swimmers), '1'
  UNION ALL SELECT 3, 'workout insert defaulted session_type to ''training''',
         (SELECT session_type FROM workouts WHERE title = '3MT Probe Workout' LIMIT 1),
         'training'
)
SELECT n, label, got, want,
       CASE WHEN got = want THEN 'PASS' ELSE 'FAIL' END AS result
FROM probe ORDER BY n;

-- ── Probe as Coach B (unrelated, no roster) ─────────────────────────────────
-- Same transaction, only the JWT claims change. auth.uid() now resolves
-- to coach B; the coach-owns-swimmer policy should admit zero rows.
SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-4000-8000-00000000a302","role":"authenticated"}';

WITH probe(n, label, got, want) AS (
  SELECT 4, 'coach B sees zero 3MT profiles (foreign swimmer)',
         (SELECT count(*)::text FROM swimmer_test_profiles), '0'
  UNION ALL SELECT 5, 'coach B sees zero swimmers (no roster)',
         (SELECT count(*)::text FROM swimmers), '0'
  UNION ALL SELECT 6, 'coach B sees zero workouts',
         (SELECT count(*)::text FROM workouts), '0'
)
SELECT n, label, got, want,
       CASE WHEN got = want THEN 'PASS' ELSE 'FAIL' END AS result
FROM probe ORDER BY n;

ROLLBACK;
