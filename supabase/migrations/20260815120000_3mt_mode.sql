-- Migration: 3MT mode — V0.38 Slice 1 (additive only)
--
-- Timestamp: 2026-08-15 12:00
-- Author: TARS (V0.38 build, 3MT mode wedge feature)
--
-- WHY THIS MIGRATION EXISTS
-- Eva Piatrikova's 3-minute all-out test (3MT) becomes a first-class session
-- type. The math runs in the client (ThreeMinuteTestAnalyzer); this slice
-- ships the storage shape and the access policies so the iOS save path,
-- the review surface, and future zone analytics can find the numbers.
--
-- Two additive pieces, no destructive ops, no backfill:
--
--   1. workouts.session_type  text NOT NULL DEFAULT 'training'
--      CHECK (session_type IN ('training', '3mt'))
--      Lets the parser flag a workout whose primary set is a 3MT, so the
--      review surface and analytics know to switch into 3MT vocabulary.
--
--   2. swimmer_test_profiles  per-swimmer 3MT result table
--      One row per (swimmer, session, trial) carrying the three numbers
--      (peak speed, critical speed, battery) + quality_flags. The math
--      service writes here; the review surface reads here.
--
-- RLS mirrors swimmer_pbs (schema.sql lines 321-333): a coach sees profiles
-- for swimmers they own. Plus a swimmer-self SELECT copied from the
-- swimmer_own_pbs pattern in migration 20260623000000_swimmer_login_schema.sql.
--
-- Reference: V0.38_SPEC.md §Slice 1,
-- docs/research/2026-08-15-3mt-drop-rule-zones.md.

BEGIN;

-- ── 1. workouts.session_type ──────────────────────────────────────────────────
-- Add the column without an inline CHECK so the column-add itself is a clean
-- no-op on re-run. The named CHECK is added in a separate guarded block —
-- a pg_constraint lookup avoids the duplicate-constraint error that a plain
-- ADD CONSTRAINT would throw on a second run.
ALTER TABLE workouts
  ADD COLUMN IF NOT EXISTS session_type text NOT NULL DEFAULT 'training';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'workouts_session_type_check'
      AND conrelid = 'public.workouts'::regclass
  ) THEN
    ALTER TABLE workouts
      ADD CONSTRAINT workouts_session_type_check
      CHECK (session_type IN ('training', '3mt'));
  END IF;
END $$;

COMMENT ON COLUMN workouts.session_type IS
  'Classifies the workout so downstream code can branch into 3MT-specific vocabulary. Default ''training''; set to ''3mt'' when the workout''s primary set is a 3-minute all-out test (Piatrikova). V0.38 Slice 1.';

-- ── 2. swimmer_test_profiles ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS swimmer_test_profiles (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  swimmer_id          uuid NOT NULL REFERENCES swimmers(id) ON DELETE CASCADE,
  session_id          uuid REFERENCES sessions(id) ON DELETE SET NULL,
  workout_set_id      uuid REFERENCES workout_sets(id) ON DELETE SET NULL,
  stroke              text NOT NULL DEFAULT 'Free',
  pool_length         integer NOT NULL DEFAULT 25,
  test_date           timestamptz NOT NULL DEFAULT now(),
  trial_number        integer NOT NULL DEFAULT 1,
  peak_speed_mps      double precision NOT NULL,
  critical_speed_mps  double precision NOT NULL,
  battery_m           double precision NOT NULL,
  quality_flags       jsonb NOT NULL DEFAULT '[]',
  created_at          timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_test_profiles_swimmer
  ON swimmer_test_profiles(swimmer_id, stroke, test_date);

COMMENT ON TABLE swimmer_test_profiles IS
  'Per-swimmer 3-minute all-out test (3MT) result row. One row per (swimmer, session, trial). Math is produced client-side by ThreeMinuteTestAnalyzer; storage lives here so the review surface and future analytics can branch on it. V0.38 Slice 1.';

-- ── 3. RLS ────────────────────────────────────────────────────────────────────
-- Coach pattern is the same as swimmer_pbs (schema.sql lines 321-333):
-- coach sees rows for swimmers they own. The swimmer-self SELECT mirrors
-- the swimmer_own_pbs pattern from migration 20260623000000_swimmer_login_schema.sql.
ALTER TABLE swimmer_test_profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS swimmer_test_profiles_select ON swimmer_test_profiles;
CREATE POLICY swimmer_test_profiles_select ON swimmer_test_profiles
  FOR SELECT USING (
    swimmer_id IN (SELECT id FROM swimmers WHERE coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()))
  );

DROP POLICY IF EXISTS swimmer_test_profiles_insert ON swimmer_test_profiles;
CREATE POLICY swimmer_test_profiles_insert ON swimmer_test_profiles
  FOR INSERT WITH CHECK (
    swimmer_id IN (SELECT id FROM swimmers WHERE coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()))
  );

DROP POLICY IF EXISTS swimmer_test_profiles_update ON swimmer_test_profiles;
CREATE POLICY swimmer_test_profiles_update ON swimmer_test_profiles
  FOR UPDATE USING (
    swimmer_id IN (SELECT id FROM swimmers WHERE coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()))
  );

DROP POLICY IF EXISTS swimmer_own_test_profiles ON swimmer_test_profiles;
CREATE POLICY swimmer_own_test_profiles ON swimmer_test_profiles
  FOR SELECT USING (
    swimmer_id IN (SELECT id FROM swimmers WHERE auth_id = auth.uid())
  );

COMMIT;
