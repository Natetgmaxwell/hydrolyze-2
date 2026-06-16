-- Migration: Add send_off_offset_ms to wave_assignments
-- Stores the milliseconds-from-set-start when this wave's swimmers leave the wall.
-- Computed as wave_number * sendOffIntervalMs (default 10,000ms = 10s).
-- Enables cohort-gated pairing: pairer only considers active wave's swimmers
-- until expected lap count is satisfied or 45s grace timeout fires.
--
-- Run in Supabase SQL Editor or via: psql $DATABASE_URL -f <this-file>

BEGIN;

ALTER TABLE wave_assignments ADD COLUMN send_off_offset_ms INTEGER NOT NULL DEFAULT 0;

COMMENT ON COLUMN wave_assignments.send_off_offset_ms IS 'Milliseconds from set start to this wave send-off. wave_number * sendOffIntervalMs (default 10,000ms). Enables cohort-gated pairing.';

COMMIT;