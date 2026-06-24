-- Migration: Add workout_set_id FK to recorded_times
-- Nullable FK linking a lap to the workout_set it was timed from.
-- ON DELETE SET NULL — laps survive set edits, just lose context link.
-- Indexed for future pairing algorithm join performance.
--
-- Run in Supabase SQL Editor or via: psql $DATABASE_URL -f <this-file>

BEGIN;

ALTER TABLE recorded_times ADD COLUMN workout_set_id uuid;
ALTER TABLE recorded_times ADD CONSTRAINT recorded_times_workout_set_id_fkey
    FOREIGN KEY (workout_set_id) REFERENCES workout_sets(id) ON DELETE SET NULL;

CREATE INDEX idx_recorded_times_workout_set_id ON recorded_times(workout_set_id);

COMMENT ON COLUMN recorded_times.workout_set_id IS 'FK to workout_sets(id). Null for bare timing sessions (TodayView). Enables future pairing algorithm to join set context (stroke, distance, pace, intensity, PBs).';

COMMIT;