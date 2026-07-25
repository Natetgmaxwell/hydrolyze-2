-- 20260725000000_add_dive_to_workout_sets.sql
-- Phase 1 metadata wiring: add dive boolean + upgrade gear to array.
-- The parser extracts dive as a boolean and gear as an array (a set can have
-- multiple gear items: paddles + pull_buoy, kickboard + fins, etc).
-- The old `gear text` column only held one value — we upgrade to `text[]`.
-- start_type already exists from the v3 suit/dive migration.

ALTER TABLE workout_sets
  ADD COLUMN IF NOT EXISTS dive boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN workout_sets.dive IS
  'Whether this set is dive-started. Denormalized from start_type=''dive'' '
  'and/or parser detection of "from a dive", "off the blocks", etc. '
  'Default false (in-water push start).';

-- Upgrade gear column from text to text[] to support multi-gear sets.
-- Strategy: add new column, migrate data, drop old, rename.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'workout_sets' AND column_name = 'gear'
      AND data_type = 'text'
  ) THEN
    ALTER TABLE workout_sets ADD COLUMN IF NOT EXISTS gear_array text[];
    UPDATE workout_sets
      SET gear_array = CASE
        WHEN gear IS NULL OR gear = '' THEN NULL
        ELSE ARRAY[gear]
      END;
    ALTER TABLE workout_sets DROP COLUMN gear;
    ALTER TABLE workout_sets RENAME COLUMN gear_array TO gear;
  END IF;
END $$;

COMMENT ON COLUMN workout_sets.gear IS
  'Array of gear items used in this set: {paddles}, {paddles,pull_buoy}, {fins}, etc. '
  'null = no gear. Upgraded from single text in Phase 1 (2026-07-25).';
