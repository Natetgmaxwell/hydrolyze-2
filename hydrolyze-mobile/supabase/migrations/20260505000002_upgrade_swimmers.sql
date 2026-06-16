-- Migration: Upgrade swimmers table with name components, demographics, and timestamps
-- Date: 2026-05-05

BEGIN;

ALTER TABLE swimmers ADD COLUMN IF NOT EXISTS first_name text NOT NULL DEFAULT '';
ALTER TABLE swimmers ADD COLUMN IF NOT EXISTS last_name text;
ALTER TABLE swimmers ADD COLUMN IF NOT EXISTS birthdate date;
ALTER TABLE swimmers ADD COLUMN IF NOT EXISTS gender text CHECK (gender IN ('M','F','X'));
ALTER TABLE swimmers ADD COLUMN IF NOT EXISTS notes text;
ALTER TABLE swimmers ADD COLUMN IF NOT EXISTS archived_at timestamptz;
ALTER TABLE swimmers ADD COLUMN IF NOT EXISTS updated_at timestamptz DEFAULT now();

-- Backfill first_name/last_name from existing name column
-- "First Last" → first_name='First', last_name='Last'
UPDATE swimmers
SET
  first_name = split_part(name, ' ', 1),
  last_name = nullif(substring(name from position(' ' in name)+1), '')
WHERE name IS NOT NULL
  AND name <> ''
  AND first_name = ''
  AND name LIKE '% %';

-- Single-word names (no space) → first_name = name, last_name = null
UPDATE swimmers
SET first_name = name
WHERE name IS NOT NULL
  AND name <> ''
  AND first_name = ''
  AND name NOT LIKE '% %';

-- Make first_name non-null with a placeholder for any rows still empty
UPDATE swimmers SET first_name = 'Unknown' WHERE first_name = '' OR first_name IS NULL;

ALTER TABLE swimmers ALTER COLUMN first_name SET NOT NULL;
ALTER TABLE swimmers ALTER COLUMN first_name SET DEFAULT '';

CREATE INDEX IF NOT EXISTS swimmers_coach_id ON swimmers(coach_id);
CREATE INDEX IF NOT EXISTS swimmers_archived ON swimmers(archived_at) WHERE archived_at IS NOT NULL;

COMMIT;