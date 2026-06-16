-- Migration: Add RLS policy for coaches table
-- Required for signup flow (getOrCreateCoach inserts on first login)
-- Date: 2026-05-03

BEGIN;

ALTER TABLE coaches ENABLE ROW LEVEL SECURITY;

-- Coaches can manage their own record
CREATE POLICY "coach_own_record" ON coaches
  FOR ALL USING (auth_id = auth.uid());

-- Allow users to insert their own coach record on signup
CREATE POLICY "coach_signup_insert" ON coaches
  FOR INSERT WITH CHECK (auth_id = auth.uid());

-- Public read for dashboard lookups
CREATE POLICY "coach_read_own" ON coaches
  FOR SELECT USING (auth_id = auth.uid());

COMMIT;
