-- Migration: Repair workouts schema
-- Ensures completed_at exists and triggers a schema cache refresh

BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'workouts' AND column_name = 'completed_at'
  ) THEN
    ALTER TABLE workouts ADD COLUMN completed_at timestamptz;
  END IF;
END $$;

COMMIT;
