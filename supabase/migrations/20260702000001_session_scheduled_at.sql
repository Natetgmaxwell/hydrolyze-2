-- Migration: Extend sessions with future-schedule support
-- Date: 2026-07-02
--
-- Adds the columns needed for the swimmer-self-mark-attendance flow
-- (originals/hydrolyze-coach-self-mark-attendance-v1). Before this
-- migration, a `sessions` row only existed after the coach started
-- timing — there was no concept of "scheduled for next Tuesday AM".
--
-- The fix is two nullable columns:
--   scheduled_at  — when the practice is planned to happen
--                   (NULL for historical / unscheduled sessions)
--   athlete_count — squad size the coach is planning for
--                   (NULL when unknown; not required)
--
-- After this migration, the workflow becomes:
--   1. Coach schedules a session (creates a sessions row with
--      scheduled_at populated, started_at NULL).
--   2. Swimmers mark intent against the scheduled session.
--   3. Coach taps Start → started_at gets set, intent → roster.
--
-- Existing sessions (rows where started_at is already set) keep
-- working unchanged. The new columns are nullable for them.
--
-- Idempotent. ADD COLUMN IF NOT EXISTS. Safe to re-run.

BEGIN;

ALTER TABLE sessions
  ADD COLUMN IF NOT EXISTS scheduled_at timestamptz;

ALTER TABLE sessions
  ADD COLUMN IF NOT EXISTS athlete_count integer;

COMMENT ON COLUMN sessions.scheduled_at IS
  'When the practice is planned. NULL for historical/started sessions. '
  'Used by the swimmer-self-mark-attendance flow to surface upcoming '
  'sessions in the swimmer Upcoming tab.';

COMMENT ON COLUMN sessions.athlete_count IS
  'Planned squad size for the session. NULL when unknown. Display only '
  '— does NOT constrain the roster; the roster is set when the session '
  'is locked at session start.';

-- Index for the swimmer Upcoming tab query:
--   WHERE scheduled_at BETWEEN now() AND now()+7d
CREATE INDEX IF NOT EXISTS idx_sessions_scheduled_at
  ON sessions(scheduled_at)
  WHERE scheduled_at IS NOT NULL;

COMMIT;