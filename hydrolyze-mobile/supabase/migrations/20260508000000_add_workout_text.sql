-- Migration: add workout_text column for re-parsing on detail page
-- This allows the detail page to render the full v2 preview by re-running the parser.
BEGIN;

ALTER TABLE workouts ADD COLUMN IF NOT EXISTS workout_text text;

COMMIT;