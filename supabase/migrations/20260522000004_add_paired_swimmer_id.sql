-- Migration: Add paired_swimmer_id to recorded_times
-- The swimmer assigned by the pairing algorithm (may differ from swimmer_id
-- until coach confirms on the review screen). swimmer_id = recorder/owner;
-- paired_swimmer_id = pairer-assigned tentative assignment.
--
-- Run in Supabase SQL Editor or via: psql $DATABASE_URL -f <this-file>

BEGIN;

ALTER TABLE recorded_times ADD COLUMN paired_swimmer_id UUID REFERENCES swimmers(id) ON DELETE SET NULL;

CREATE INDEX idx_recorded_times_paired_swimmer ON recorded_times(paired_swimmer_id);

COMMENT ON COLUMN recorded_times.paired_swimmer_id IS 'Pairer-assigned swimmer. May differ from swimmer_id (the recording coach) until confirmed on review screen. NULL = not yet paired.';

COMMIT;