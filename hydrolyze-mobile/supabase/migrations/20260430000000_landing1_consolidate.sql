-- Landing 1 — Consolidate the workout/session data layer.
--
-- Two sources of truth had drifted:
--   - supabase/schema.sql declares workouts.status with CHECK + backfill needs
--   - hydrolyze-mobile/supabase/migrations/* never added the status column
--
-- And the runtime code expects three things the actual DB doesn't yet guarantee:
--   1. workouts.status text NOT NULL DEFAULT 'draft' (CHECK draft|scheduled|in_progress|complete)
--   2. recorded_times.workout_id uuid (so results.tsx can stop overloading session_id)
--   3. recorded_times.session_id allowed to be NULL (new code path bypasses the legacy sessions table)
--
-- Every statement is idempotent. Safe on a DB that already has any subset of the above.

BEGIN;

-- ── workouts.status ───────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'workouts' AND column_name = 'status'
  ) THEN
    ALTER TABLE workouts ADD COLUMN status text NOT NULL DEFAULT 'draft';

    UPDATE workouts SET status =
      CASE
        WHEN completed_at IS NOT NULL THEN 'complete'
        WHEN scheduled_at IS NOT NULL THEN 'scheduled'
        ELSE 'draft'
      END;
  END IF;
END $$;

-- Make sure the CHECK constraint is in place (named so we can re-add idempotently)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.constraint_column_usage
    WHERE table_name = 'workouts' AND constraint_name = 'workouts_status_check'
  ) THEN
    ALTER TABLE workouts
      ADD CONSTRAINT workouts_status_check
      CHECK (status IN ('draft', 'scheduled', 'in_progress', 'complete'));
  END IF;
EXCEPTION WHEN OTHERS THEN
  -- If a differently-named check already exists, leave it alone.
  RAISE NOTICE 'workouts_status_check skipped: %', SQLERRM;
END $$;

-- ── recorded_times.workout_id ─────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'recorded_times' AND column_name = 'workout_id'
  ) THEN
    ALTER TABLE recorded_times
      ADD COLUMN workout_id uuid REFERENCES workouts(id) ON DELETE CASCADE;
  END IF;
END $$;

-- Backfill workout_id from workout_sets when possible.
UPDATE recorded_times rt
SET workout_id = ws.workout_id
FROM workout_sets ws
WHERE rt.workout_id IS NULL
  AND rt.workout_set_id IS NOT NULL
  AND rt.workout_set_id = ws.id;

CREATE INDEX IF NOT EXISTS idx_recorded_times_workout_id
  ON recorded_times(workout_id);

-- ── recorded_times.session_id nullable ────────────────────────────────────────
-- The legacy sessions table is being phased out; new code paths set workout_id
-- instead. Make session_id optional so inserts from the new flow don't fail.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'recorded_times' AND column_name = 'session_id'
      AND is_nullable = 'NO'
  ) THEN
    ALTER TABLE recorded_times ALTER COLUMN session_id DROP NOT NULL;
  END IF;
END $$;

COMMIT;
