-- Migration: Add missing columns to recorded_times for pairing support
-- Adds: paired_swimmer_id, confidence, lap_order, wave_number

BEGIN;

ALTER TABLE recorded_times
    ADD COLUMN IF NOT EXISTS paired_swimmer_id UUID REFERENCES swimmers(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS confidence INTEGER DEFAULT 0,
    ADD COLUMN IF NOT EXISTS lap_order INTEGER,
    ADD COLUMN IF NOT EXISTS wave_number INTEGER;

COMMENT ON COLUMN recorded_times.paired_swimmer_id IS 'Tentative swimmer assignment from ML pairing. Becomes swimmer_id once coach confirms.';
COMMENT ON COLUMN recorded_times.confidence IS 'Pairing confidence score (0-100).';
COMMENT ON COLUMN recorded_times.lap_order IS 'Order in which the lap was recorded within the session.';
COMMENT ON COLUMN recorded_times.wave_number IS 'Wave number the swimmer belonged to during this set.';

COMMIT;
