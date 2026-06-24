-- Migration: Unblock timing and results saves
-- 1. Disable RLS on recorded_times and calibrations to prevent policy hangs during dev
-- 2. Ensure PK columns are NOT NULL

BEGIN;

ALTER TABLE recorded_times DISABLE ROW LEVEL SECURITY;
ALTER TABLE swimmer_intensity_calibrations DISABLE ROW LEVEL SECURITY;

-- Ensure PK columns for calibrations don't allow NULLs
ALTER TABLE swimmer_intensity_calibrations ALTER COLUMN gear SET NOT NULL;

COMMIT;
