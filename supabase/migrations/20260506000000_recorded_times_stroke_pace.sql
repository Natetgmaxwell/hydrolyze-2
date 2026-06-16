-- Migration: Add stroke and pace_distance to recorded_times
-- Adds snapshot columns to capture set context at recording time.
-- These are NOT FK references — they freeze the values at the moment of recording.
--
-- Run in Supabase SQL Editor or via: psql $DATABASE_URL -f 20260506000000_recorded_times_stroke_pace.sql

BEGIN;

ALTER TABLE recorded_times ADD COLUMN stroke text;
ALTER TABLE recorded_times ADD COLUMN pace_distance integer;

CREATE INDEX idx_recorded_times_stroke ON recorded_times(stroke);
CREATE INDEX idx_recorded_times_stroke_pace ON recorded_times(stroke, pace_distance);

COMMENT ON COLUMN recorded_times.stroke IS 'Stroke type at time of recording (Freestyle, Backstroke, etc.). Snapshot — not a FK.';
COMMENT ON COLUMN recorded_times.pace_distance IS 'Pace target distance in meters at time of recording. Snapshot — not a FK.';

COMMIT;
