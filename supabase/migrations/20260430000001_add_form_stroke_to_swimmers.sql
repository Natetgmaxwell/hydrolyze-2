-- Migration: Add missing form_stroke column to swimmers table
-- This column is used to resolve 'Form' sets to a specific stroke for each swimmer.

BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'swimmers' AND column_name = 'form_stroke'
  ) THEN
    ALTER TABLE swimmers ADD COLUMN form_stroke text DEFAULT 'Free';
  END IF;
END $$;

COMMIT;
