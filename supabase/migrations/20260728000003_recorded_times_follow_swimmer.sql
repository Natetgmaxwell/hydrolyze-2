-- Migration: recorded_times follow the swimmer on coach transfer
--
-- Problem: recorded_times SELECT RLS keys on session_id → sessions.coach_id.
-- When a swimmer transfers to a new coach, the new coach can't see the
-- swimmer's historical times because those rows belong to the old coach's
-- sessions.
--
-- Fix: add a second coach SELECT policy that keys on
-- swimmer_id → swimmers.coach_id. This means the current coach can see
-- ALL recorded_times for any swimmer they own, regardless of which
-- coach's session originally produced them. The existing session-based
-- policy stays (it covers the normal case where the coach reads their
-- own session's times); the new policy is additive.
--
-- The swimmer's own visibility (swimmer_own_recorded_times) is unchanged —
-- it already keys on swimmers.auth_id and follows the swimmer.

BEGIN;

-- Add coach_read_swimmer_times: coach can SELECT recorded_times for
-- any swimmer whose coach_id matches the current coach.
DROP POLICY IF EXISTS coach_read_swimmer_times ON public.recorded_times;

CREATE POLICY coach_read_swimmer_times ON public.recorded_times
  FOR SELECT TO authenticated
  USING (
    swimmer_id IN (
      SELECT swimmers.id
      FROM swimmers
      WHERE swimmers.coach_id IN (
        SELECT coaches.id
        FROM coaches
        WHERE coaches.auth_id = auth.uid()
      )
    )
  );

COMMIT;