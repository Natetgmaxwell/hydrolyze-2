-- Migration: Add confidence to recorded_times
-- Pairing algorithm confidence score (0-100) for the paired_swimmer_id assignment.
-- NULL = not yet paired or processed by the algorithm.
--
-- Run in Supabase SQL Editor or via: psql $DATABASE_URL -f <this-file>

BEGIN;

ALTER TABLE recorded_times ADD COLUMN confidence SMALLINT
    CHECK (confidence IS NULL OR (confidence BETWEEN 0 AND 100));

COMMENT ON COLUMN recorded_times.confidence IS 'Pairing algorithm confidence 0-100 for paired_swimmer_id assignment. NULL = not yet paired. Set by PairingService on assignment.';

COMMIT;