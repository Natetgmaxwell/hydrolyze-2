-- Migration: Add reviewed_at to sessions
-- Timestamp when coach confirmed all lap assignments on the review screen.
-- Used to track session completion state and prevent double-review.
--
-- Run in Supabase SQL Editor or via: psql $DATABASE_URL -f <this-file>

BEGIN;

ALTER TABLE sessions ADD COLUMN reviewed_at TIMESTAMPTZ;

COMMENT ON COLUMN sessions.reviewed_at IS 'Timestamp when coach confirmed all lap assignments on the review screen. NULL = not yet reviewed.';

COMMIT;