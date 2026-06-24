-- Migration: Add onboarding fields to coaches table and teams table
-- Date: 2026-05-05

BEGIN;

ALTER TABLE coaches ADD COLUMN IF NOT EXISTS pool_units text;
ALTER TABLE coaches ADD COLUMN IF NOT EXISTS onboarding_completed_at timestamptz;

CREATE TABLE IF NOT EXISTS teams (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  coach_id uuid NOT NULL REFERENCES coaches(id) ON DELETE CASCADE,
  name text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS teams_coach_id_idx ON teams(coach_id);

COMMIT;