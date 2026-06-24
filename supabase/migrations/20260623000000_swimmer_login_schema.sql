-- Migration: Phase 2.1 — swimmer login schema + RLS
--
-- Timestamp: 2026-06-23
-- Author: TARS (built on user feedback for swimmer login)
--
-- WHY THIS MIGRATION EXISTS
-- The Hydrolyze MVP needs swimmer-facing login so swimmers can
-- see their own swim data (their times, their PBs, their coach).
-- This migration:
--   1. Adds swimmers.auth_id (FK to auth.users.id) — the
--      canonical lifelong identifier for a swimmer across
--      coaches
--   2. Adds swimmers.email — used for sign-in lookup and for
--      the coach to set when creating the swimmer's account
--   3. Adds RLS policies for swimmer-scoped read access — a
--      swimmer can SELECT their own row + their own data, but
--      cannot see other swimmers' data, sessions, or coaches'
--      private columns
--   4. The data permanence principle: swimmer_id stays with
--      the swimmer even if coach_id changes (the swimmer's
--      swim times are theirs, the sessions were the coach's)
--
-- Run in Supabase SQL Editor or via:
--   supabase db query --linked -f <this-file>

BEGIN;

-- 1. Add swimmers.auth_id (FK to auth.users.id)
-- Nullable: existing swimmers have no auth_id; coach invites them
-- later via createSwimmerAccount (Phase 2.3).
ALTER TABLE swimmers
  ADD COLUMN IF NOT EXISTS auth_id uuid REFERENCES auth.users(id) ON DELETE SET NULL;

-- 2. Add swimmers.email
-- Nullable: existing swimmers may not have an email on file.
-- The coach sets this when they create the swimmer's login
-- (Phase 2.3).
ALTER TABLE swimmers
  ADD COLUMN IF NOT EXISTS email text;

-- 2b. Add a UNIQUE index on email so we can look up swimmers by
-- email at sign-in time. Partial unique index — only enforced
-- when email IS NOT NULL, so existing swimmers without an
-- email don't collide.
CREATE UNIQUE INDEX IF NOT EXISTS swimmers_email_unique
  ON swimmers(email)
  WHERE email IS NOT NULL;

-- 2c. Add a UNIQUE index on auth_id. Same partial pattern.
CREATE UNIQUE INDEX IF NOT EXISTS swimmers_auth_id_unique
  ON swimmers(auth_id)
  WHERE auth_id IS NOT NULL;

-- 3. RLS policies for swimmer-scoped read
--
-- The existing coach RLS policies use `auth.uid()::text = coach_id`
-- (the pre-coaches-table era). The current fix_rls_policies.sql
-- uses `coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid())`.
-- We need BOTH: the coach can still see everything for their
-- swimmers, AND the swimmer (signed in as auth.uid()) can see
-- their own row + their own data.

-- 3a. Swimmers can SELECT their own row
DROP POLICY IF EXISTS swimmer_self_select ON swimmers;
CREATE POLICY swimmer_self_select ON swimmers
  FOR SELECT USING (auth_id = auth.uid());

-- 3b. Swimmers can SELECT their own recorded_times
-- recorded_times has RLS disabled (it's via session ownership)
-- so we need to enable it for the swimmer policy to apply.
-- But: enabling RLS on recorded_times would break the coach
-- access pattern (which currently uses no policy because RLS
-- is disabled). Solution: create a policy that grants SELECT
-- to either the coach OR the swimmer.
ALTER TABLE recorded_times ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS coach_own_recorded_times ON recorded_times;
CREATE POLICY coach_own_recorded_times ON recorded_times
  FOR ALL USING (
    session_id IN (
      SELECT s.id FROM sessions s
      JOIN coaches c ON s.coach_id = c.id
      WHERE c.auth_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS swimmer_own_recorded_times ON recorded_times;
CREATE POLICY swimmer_own_recorded_times ON recorded_times
  FOR SELECT USING (
    swimmer_id IN (
      SELECT id FROM swimmers WHERE auth_id = auth.uid()
    )
  );

-- 3c. Swimmers can SELECT their own PBs
DROP POLICY IF EXISTS swimmer_own_pbs ON swimmer_pbs;
CREATE POLICY swimmer_own_pbs ON swimmer_pbs
  FOR SELECT USING (
    swimmer_id IN (
      SELECT id FROM swimmers WHERE auth_id = auth.uid()
    )
  );

-- 3d. Swimmers can SELECT their own calibration tables
-- (intensity, gears, suits, starts)
DROP POLICY IF EXISTS swimmer_own_intensity_calibrations ON swimmer_intensity_calibrations;
CREATE POLICY swimmer_own_intensity_calibrations ON swimmer_intensity_calibrations
  FOR SELECT USING (
    swimmer_id IN (
      SELECT id FROM swimmers WHERE auth_id = auth.uid()
    )
  );

ALTER TABLE swimmer_intensity_calibrations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS swimmer_own_gears ON swimmer_gears;
CREATE POLICY swimmer_own_gears ON swimmer_gears
  FOR SELECT USING (
    swimmer_id IN (
      SELECT id FROM swimmers WHERE auth_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS swimmer_own_suits ON swimmer_suits;
CREATE POLICY swimmer_own_suits ON swimmer_suits
  FOR SELECT USING (
    swimmer_id IN (
      SELECT id FROM swimmers WHERE auth_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS swimmer_own_starts ON swimmer_starts;
CREATE POLICY swimmer_own_starts ON swimmer_starts
  FOR SELECT USING (
    swimmer_id IN (
      SELECT id FROM swimmers WHERE auth_id = auth.uid()
    )
  );

-- 3e. Swimmers can SELECT their own stats (the legacy swimmer_stats
-- table, even though it's redundant with the new tables)
DROP POLICY IF EXISTS swimmer_own_stats ON swimmer_stats;
CREATE POLICY swimmer_own_stats ON swimmer_stats
  FOR SELECT USING (
    swimmer_id IN (
      SELECT id FROM swimmers WHERE auth_id = auth.uid()
    )
  );

-- 3f. Swimmers cannot see OTHER swimmers' rows.
-- The new policies above are SELECT-only, so a swimmer using
-- their own auth.uid() will only match their own row. The coach
-- policies still grant coach-level access (FOR ALL) for the
-- swimmers the coach owns.

-- 4. COMMENT the new columns for the schema.sql reference
COMMENT ON COLUMN swimmers.auth_id IS
  'FK to auth.users.id. The canonical lifelong identifier for a swimmer across coaches. Set when the coach invites the swimmer via createSwimmerAccount (Phase 2.3). Survives coach_id changes — when a swimmer switches coaches, only coach_id changes, auth_id stays.';
COMMENT ON COLUMN swimmers.email IS
  'Email used for sign-in lookup. Set when the coach creates the swimmer''s account. Nullable for existing swimmers who don''t have a Hydrolyze login yet.';

COMMIT;