-- Migration: Remove all RLS from workouts table for pre-auth development
-- Re-enable with proper auth-aware policies once Supabase Auth is wired.
-- This migration is safe to run multiple times (idempotent).

BEGIN;

-- Remove all existing policies on workouts
DO $$
DECLARE
  pol_name text;
BEGIN
  FOR pol_name IN
    SELECT policyname FROM pg_policies WHERE tablename = 'workouts'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON workouts', pol_name);
  END LOOP;
END $$;

-- Disable RLS on workouts for now
ALTER TABLE workouts DISABLE ROW LEVEL SECURITY;

COMMIT;