-- Migration: Align 'swimmers' table with iOS App Model
-- The Swift Swimmer model expects first_name, last_name, archived_at, etc.
-- This migration updates the database schema to match the iOS app.

-- Step 1: Add the new columns
ALTER TABLE swimmers ADD COLUMN IF NOT EXISTS first_name text;
ALTER TABLE swimmers ADD COLUMN IF NOT EXISTS last_name text;
ALTER TABLE swimmers ADD COLUMN IF NOT EXISTS birthdate date;
ALTER TABLE swimmers ADD COLUMN IF NOT EXISTS gender text;
ALTER TABLE swimmers ADD COLUMN IF NOT EXISTS notes text;
ALTER TABLE swimmers ADD COLUMN IF NOT EXISTS preferred_gear text;
ALTER TABLE swimmers ADD COLUMN IF NOT EXISTS archived_at timestamptz;

-- Step 2: Migrate existing 'name' data into first_name/last_name
-- Split on the first space: everything before = first_name, everything after = last_name
UPDATE swimmers
SET
  first_name = CASE
    WHEN position(' ' in name) > 0 THEN left(name, position(' ' in name) - 1)
    ELSE name
  END,
  last_name = CASE
    WHEN position(' ' in name) > 0 THEN substring(name from position(' ' in name) + 1)
    ELSE NULL
  END
WHERE first_name IS NULL AND name IS NOT NULL;

-- Step 3: Make first_name NOT NULL (after backfilling)
ALTER TABLE swimmers ALTER COLUMN first_name SET NOT NULL;

-- Optional: Drop the old 'name' column if you want to enforce strict usage
-- ALTER TABLE swimmers DROP COLUMN name;
