-- Add distance column to swimmer_stats so we can distinguish
-- a 50m training average from a 100m training average.
-- Safe to run multiple times — only adds column if missing.

BEGIN;

-- Add set_id (distance) column if it doesn't exist
ALTER TABLE swimmer_stats
  ADD COLUMN IF NOT EXISTS set_id INTEGER DEFAULT NULL;

-- Add a comment for clarity
COMMENT ON COLUMN swimmer_stats.set_id IS 'Distance in metres this training average applies to. NULL = all distances (legacy).';

-- Backfill set_id from existing data patterns (50m if only one record for stroke, else 50)
-- We can detect by checking sample_count patterns:
-- sample_count >= 8 and mean_time_ms < 40000 → likely 50m
-- sample_count >= 8 and mean_time_ms >= 40000 → likely 100m+

-- For now just leave existing records as NULL (they still work at 50m via speed curve fallback)
-- New inserts via the app will always include set_id.

COMMIT;