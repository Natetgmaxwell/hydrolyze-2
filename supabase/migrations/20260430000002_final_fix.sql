-- Migration: Final schema fixes for timing and results
-- 1. Add gear column to recorded_times
-- 2. Create swimmer_intensity_calibrations table

BEGIN;

ALTER TABLE recorded_times ADD COLUMN IF NOT EXISTS gear text;

CREATE TABLE IF NOT EXISTS swimmer_intensity_calibrations (
  swimmer_id       uuid    NOT NULL REFERENCES swimmers(id) ON DELETE CASCADE,
  stroke           text    NOT NULL,
  intensity        text    NOT NULL,
  gear             text    DEFAULT 'none',
  multiplier_mean  float   NOT NULL DEFAULT 1.0,
  multiplier_m2    float   NOT NULL DEFAULT 0.0,
  sample_count     integer NOT NULL DEFAULT 0,
  updated_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (swimmer_id, stroke, intensity, gear)
);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'swimmer_intensity_calibrations') THEN
    ALTER TABLE swimmer_intensity_calibrations ENABLE ROW LEVEL SECURITY;
    CREATE POLICY "allow_all" ON swimmer_intensity_calibrations FOR ALL USING (true);
  END IF;
END $$;

COMMIT;
