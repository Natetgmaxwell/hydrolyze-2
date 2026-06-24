-- Migration: Disable RLS on workouts table for pre-auth development
-- RLS will be re-enabled with proper auth-aware policies once Supabase Auth is wired.
-- coach_own_workouts policy was already replaced by 20260425000003 but still failing anon insert.
-- This migration disables RLS entirely so the app can write workouts without auth context.

BEGIN;

-- Remove all policies on workouts
DO $$
DECLARE
  pol text;
BEGIN
  FOR pol IN SELECT policyname FROM pg_policies WHERE tablename = 'workouts'
  LOOP
    EXECUTE 'DROP POLICY IF EXISTS ' || pol || ' ON workouts';
  END LOOP;
END $$;

-- Disable RLS — allows any insert/select/update/delete on workouts without auth
ALTER TABLE workouts DISABLE ROW LEVEL SECURITY;

COMMIT;