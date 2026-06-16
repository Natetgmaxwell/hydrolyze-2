-- Migration: Add lap_order to recorded_times
-- lap_order is the sequence index of a lap within its session (0 = first lap).
-- Set by the application when inserting laps. Used by the pairing algorithm
-- to order laps chronologically across all swimmers in a session.
--
-- Run in Supabase SQL Editor or via: psql $DATABASE_URL -f <this-file>

BEGIN;

ALTER TABLE recorded_times ADD COLUMN lap_order INTEGER NOT NULL DEFAULT 0;

CREATE INDEX idx_recorded_times_lap_order ON recorded_times(lap_order);

COMMENT ON COLUMN recorded_times.lap_order IS 'Sequence index of this lap within the session. 0 = first lap recorded. Application sets this on insert; used by pairing algorithm for chronological ordering.';

COMMIT;