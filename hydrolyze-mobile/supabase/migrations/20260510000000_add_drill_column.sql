-- Migration: add drill column for stroke modifiers (catch-up, single-arm, etc.)
BEGIN;

ALTER TABLE workout_sets ADD COLUMN IF NOT EXISTS drill text;

COMMIT;