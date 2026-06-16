-- Migration: Create wave_assignments table
-- Stores WaveOptimizer output: swimmer lane/position assignments per workout set per session.
-- One row per (swimmer, workout_set) in a session. Updated if coach drags to override.
--
-- Run in Supabase SQL Editor or via: psql $DATABASE_URL -f <this-file>

BEGIN;

CREATE TABLE wave_assignments (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id              UUID NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    swimmer_id              UUID NOT NULL REFERENCES swimmers(id) ON DELETE CASCADE,
    workout_set_id          UUID NOT NULL REFERENCES workout_sets(id) ON DELETE CASCADE,
    lane                    INTEGER NOT NULL,
    position_in_lane        INTEGER NOT NULL,
    predicted_touch_ms      INTEGER NOT NULL,
    wave_number             INTEGER NOT NULL DEFAULT 1,
    coach_id                UUID NOT NULL REFERENCES coaches(id) ON DELETE CASCADE,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_wave_assignments_session ON wave_assignments(session_id);
CREATE INDEX idx_wave_assignments_set ON wave_assignments(workout_set_id);
CREATE INDEX idx_wave_assignments_swimmer ON wave_assignments(swimmer_id);

ALTER TABLE wave_assignments ENABLE ROW LEVEL SECURITY;

CREATE POLICY wave_assignments_coach_policy ON wave_assignments
    FOR ALL USING (auth.uid() = wave_assignments.coach_id);

COMMENT ON TABLE wave_assignments IS 'Wave optimizer output per session per workout set. One row per swimmer per set. coach_id enables direct RLS policy without subquery.';
COMMENT ON COLUMN wave_assignments.predicted_touch_ms IS 'Predicted touch time in milliseconds since set start.';
COMMENT ON COLUMN wave_assignments.wave_number IS 'Wave number (1 = first wave in lane, 2 = second, etc.).';

COMMIT;