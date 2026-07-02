-- Migration: Swimmer self-marked attendance (intake stage)
-- Date: 2026-07-02
--
-- Inverts the data flow on attendance. Previously, only the coach
-- could mark who was present (via session_roster_coach_policy).
-- Now the swimmer marks their own intent (in/out) for an upcoming
-- session, and the coach confirms via the existing session_roster
-- path. See originals/hydrolyze-coach-self-mark-attendance-v1 for
-- the design rationale and the 3-layer implementation plan.
--
-- Depends on: 20260702000001_session_scheduled_at.sql (which added
-- the scheduled_at / athlete_count columns to sessions). Intent
-- rows can exist for any session with a scheduled_at (future or
-- past — the iOS Upcoming tab filters by date range client-side).
--
-- Scope notes:
--   1. swimmer_attendance_intent is a NEW sibling table, NOT a
--      status column on session_roster. session_roster keeps its
--      tight write-once semantics (locked at session start);
--      intent carries the soft, multi-state pre-confirmation state.
--   2. RLS: swimmers can write their own row (intent = 'in'|'out'),
--      coaches can write any row in their own session.
--      session_roster_coach_policy is unchanged — the coach
--      promotion path is a separate client-side flow.
--   3. Idempotent. DROP IF EXISTS guards. Safe to re-run.

BEGIN;

-- ═══════════════════════════════════════════════════════════════════
-- Table: swimmer_attendance_intent
-- ═══════════════════════════════════════════════════════════════════

CREATE TABLE swimmer_attendance_intent (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id      uuid NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  swimmer_id      uuid NOT NULL REFERENCES swimmers(id) ON DELETE CASCADE,
  intent          text NOT NULL CHECK (intent IN ('in', 'out')),
  marked_at       timestamptz NOT NULL DEFAULT now(),
  source          text NOT NULL DEFAULT 'swimmer'
                  CHECK (source IN ('swimmer', 'coach')),
  UNIQUE(session_id, swimmer_id)
);

CREATE INDEX idx_swimmer_intent_session
  ON swimmer_attendance_intent(session_id);
CREATE INDEX idx_swimmer_intent_swimmer
  ON swimmer_attendance_intent(swimmer_id);

COMMENT ON TABLE swimmer_attendance_intent IS
  'Pre-confirmation attendance state. The swimmer marks their own '
  'intent (in/out) for an upcoming session; the coach promotes '
  'confirmed intents into session_roster at session start. '
  'Separate from session_roster (which keeps its write-once '
  'lock semantics). Source: swimmer = self-marked, coach = coach override.';

-- ═══════════════════════════════════════════════════════════════════
-- RLS: enable
-- ═══════════════════════════════════════════════════════════════════

ALTER TABLE swimmer_attendance_intent ENABLE ROW LEVEL SECURITY;

-- ═══════════════════════════════════════════════════════════════════
-- Policy 1: swimmer can write their OWN intent row
-- (matched via swimmers.auth_id = auth.uid())
-- ═══════════════════════════════════════════════════════════════════

DROP POLICY IF EXISTS swimmer_own_intent_policy
  ON swimmer_attendance_intent;

CREATE POLICY swimmer_own_intent_policy
  ON swimmer_attendance_intent
  FOR ALL
  USING (
    swimmer_id IN (
      SELECT id FROM swimmers WHERE auth_id = auth.uid()
    )
  )
  WITH CHECK (
    swimmer_id IN (
      SELECT id FROM swimmers WHERE auth_id = auth.uid()
    )
  );

COMMENT ON POLICY swimmer_own_intent_policy ON swimmer_attendance_intent IS
  'Swimmer can SELECT/INSERT/UPDATE/DELETE their own intent row. '
  'Identified via swimmers.auth_id = auth.uid(). The coach can '
  'always override via coach_intent_override_policy.';

-- ═══════════════════════════════════════════════════════════════════
-- Policy 2: coach can write any intent row in their own session
-- (matched via sessions.coach_id → coaches.auth_id)
-- ═══════════════════════════════════════════════════════════════════

DROP POLICY IF EXISTS coach_intent_override_policy
  ON swimmer_attendance_intent;

CREATE POLICY coach_intent_override_policy
  ON swimmer_attendance_intent
  FOR ALL
  USING (
    session_id IN (
      SELECT s.id FROM sessions s
        JOIN coaches c ON c.id = s.coach_id
       WHERE c.auth_id = auth.uid()
    )
  )
  WITH CHECK (
    session_id IN (
      SELECT s.id FROM sessions s
        JOIN coaches c ON c.id = s.coach_id
       WHERE c.auth_id = auth.uid()
    )
  );

COMMENT ON POLICY coach_intent_override_policy ON swimmer_attendance_intent IS
  'Coach can SELECT/INSERT/UPDATE/DELETE any intent row in their '
  'own sessions. Lets the coach override swimmer marks (remove a '
  'swimmer from the list, add a swimmer the app forgot).';

-- ═══════════════════════════════════════════════════════════════════
-- Realtime broadcast support
-- (so the coach's Today view sees live updates without polling)
-- ═══════════════════════════════════════════════════════════════════

-- Supabase Realtime requires tables to be in the publication.
-- We add idempotently; if already in, no-op.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND tablename = 'swimmer_attendance_intent'
  ) THEN
    EXECUTE 'ALTER PUBLICATION supabase_realtime ADD TABLE swimmer_attendance_intent';
  END IF;
END $$;

COMMIT;