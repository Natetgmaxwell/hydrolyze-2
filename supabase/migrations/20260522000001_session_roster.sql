-- Migration: Create session_roster table
-- Tracks which swimmers attended a given timing session.
-- Roster is locked once at session start (attendance_marked_at timestamp).
-- position_in_lane is assigned by WaveOptimizer and overridable by coach.
--
-- Run in Supabase SQL Editor or via: psql $DATABASE_URL -f <this-file>

BEGIN;

CREATE TABLE session_roster (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id                  UUID NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    swimmer_id                  UUID NOT NULL REFERENCES swimmers(id) ON DELETE CASCADE,
    lane                        INTEGER,
    position_in_lane            INTEGER,
    attendance_marked_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(session_id, swimmer_id)
);

CREATE INDEX idx_session_roster_session ON session_roster(session_id);
CREATE INDEX idx_session_roster_swimmer ON session_roster(swimmer_id);
CREATE INDEX idx_session_roster_coach_session ON session_roster(session_id, swimmer_id);

ALTER TABLE session_roster ENABLE ROW LEVEL SECURITY;

CREATE POLICY session_roster_coach_policy ON session_roster
    FOR ALL USING (
        auth.uid() IN (
            SELECT coach_id::uuid FROM sessions WHERE id = session_roster.session_id
        )
    );

COMMENT ON TABLE session_roster IS 'Attendance roster per timing session. Rows written once at session start when coach locks the roster.';
COMMENT ON COLUMN session_roster.attendance_marked_at IS 'Timestamp when coach locked attendance. Used to filter out laps recorded before roster finalization.';

COMMIT;