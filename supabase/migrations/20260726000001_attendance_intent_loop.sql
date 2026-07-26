-- v1.17 Slice 1 — Attendance Intent Loop foundations
--
-- Spec: plans/attendance-intent-loop-design-spec.md (approved 2026-07-26)
--
-- Ships four things:
--   1. squad_session_slot        — the coach declares which sessions the squad OFFERS
--   2. swimmer_training_schedule — the swimmer's standing weekly pattern (subset of the above)
--   3. workouts.group_id         — squad scoping (Q1). NULL = visible to all the coach's swimmers
--   4. groups.settings jsonb     — per-squad settings; v1 key: attendance_visibility
--
-- Plus a blocker fix discovered during grounding: `workouts_select`,
-- `groups`, and `swimmer_groups` were ALL coach-only. A signed-in swimmer
-- could not read a single workout, so the entire attendance loop would have
-- returned [] forever. Swimmer-side SELECT policies added below.
--
-- Backfill: one default squad per coach, all existing swimmers enrolled,
-- Mon-Fri AM slots seeded so the swimmer's MyScheduleView grid is never
-- empty on first run. Existing workouts keep group_id NULL (visible to all)
-- so nothing disappears for anyone.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. squad_session_slot — the squad's weekly template
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.squad_session_slot (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id    uuid NOT NULL REFERENCES public.groups(id) ON DELETE CASCADE,
  weekday     smallint NOT NULL CHECK (weekday BETWEEN 0 AND 6),  -- 0=Sunday (matches Calendar.weekday - 1)
  am_pm       text NOT NULL CHECK (am_pm IN ('AM','PM')),
  label       text,
  active      boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (group_id, weekday, am_pm)
);

CREATE INDEX IF NOT EXISTS idx_squad_session_slot_group
  ON public.squad_session_slot (group_id);

ALTER TABLE public.squad_session_slot ENABLE ROW LEVEL SECURITY;

-- Coach: full control over slots in their own squads.
DROP POLICY IF EXISTS coach_own_squad_slots ON public.squad_session_slot;
CREATE POLICY coach_own_squad_slots ON public.squad_session_slot
  FOR ALL TO authenticated
  USING (
    group_id IN (
      SELECT g.id FROM public.groups g
      JOIN public.coaches c ON c.id = g.coach_id
      WHERE c.auth_id = auth.uid()
    )
  )
  WITH CHECK (
    group_id IN (
      SELECT g.id FROM public.groups g
      JOIN public.coaches c ON c.id = g.coach_id
      WHERE c.auth_id = auth.uid()
    )
  );

-- Swimmer: read-only on the slots of squads they belong to.
DROP POLICY IF EXISTS swimmer_read_squad_slots ON public.squad_session_slot;
CREATE POLICY swimmer_read_squad_slots ON public.squad_session_slot
  FOR SELECT TO authenticated
  USING (
    group_id IN (
      SELECT sg.group_id FROM public.swimmer_groups sg
      JOIN public.swimmers s ON s.id = sg.swimmer_id
      WHERE s.auth_id = auth.uid()
    )
  );

-- ---------------------------------------------------------------------------
-- 2. swimmer_training_schedule — the swimmer's standing weekly pattern
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.swimmer_training_schedule (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  swimmer_id  uuid NOT NULL REFERENCES public.swimmers(id) ON DELETE CASCADE,
  weekday     smallint NOT NULL CHECK (weekday BETWEEN 0 AND 6),
  am_pm       text NOT NULL CHECK (am_pm IN ('AM','PM')),
  active      boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (swimmer_id, weekday, am_pm)
);

CREATE INDEX IF NOT EXISTS idx_swimmer_training_schedule_swimmer
  ON public.swimmer_training_schedule (swimmer_id);

ALTER TABLE public.swimmer_training_schedule ENABLE ROW LEVEL SECURITY;

-- Swimmer: full control over their own standing schedule.
DROP POLICY IF EXISTS swimmer_own_schedule ON public.swimmer_training_schedule;
CREATE POLICY swimmer_own_schedule ON public.swimmer_training_schedule
  FOR ALL TO authenticated
  USING (
    swimmer_id IN (
      SELECT s.id FROM public.swimmers s WHERE s.auth_id = auth.uid()
    )
  )
  WITH CHECK (
    swimmer_id IN (
      SELECT s.id FROM public.swimmers s WHERE s.auth_id = auth.uid()
    )
  );

-- Coach: full control over their own swimmers' schedules (the coach is the
-- authority; they can set a schedule on behalf of a swimmer who hasn't
-- onboarded yet).
DROP POLICY IF EXISTS coach_manage_swimmer_schedules ON public.swimmer_training_schedule;
CREATE POLICY coach_manage_swimmer_schedules ON public.swimmer_training_schedule
  FOR ALL TO authenticated
  USING (
    swimmer_id IN (
      SELECT s.id FROM public.swimmers s
      JOIN public.coaches c ON c.id = s.coach_id
      WHERE c.auth_id = auth.uid()
    )
  )
  WITH CHECK (
    swimmer_id IN (
      SELECT s.id FROM public.swimmers s
      JOIN public.coaches c ON c.id = s.coach_id
      WHERE c.auth_id = auth.uid()
    )
  );

-- ---------------------------------------------------------------------------
-- 3. Squad scoping + squad settings
-- ---------------------------------------------------------------------------

ALTER TABLE public.workouts
  ADD COLUMN IF NOT EXISTS group_id uuid REFERENCES public.groups(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_workouts_group_scheduled
  ON public.workouts (group_id, scheduled_at);

ALTER TABLE public.groups
  ADD COLUMN IF NOT EXISTS settings jsonb NOT NULL DEFAULT '{}'::jsonb;

-- Index the intent lookup by workout (the coach-side badge query).
CREATE INDEX IF NOT EXISTS idx_swimmer_attendance_intent_workout
  ON public.swimmer_attendance_intent (workout_id);

-- ---------------------------------------------------------------------------
-- 4. BLOCKER FIX — swimmer-side read access
--
-- Discovered during grounding 2026-07-26: workouts_select, coach_own_groups,
-- and coach_own_swimmer_groups are all coach-only. A signed-in swimmer had
-- ZERO read access to workouts, so IntentService.fetchUpcomingWorkouts()
-- would have returned an empty array for every real swimmer. The attendance
-- feature could never have worked. These are additive SELECT policies;
-- existing coach policies are untouched.
-- ---------------------------------------------------------------------------

-- Swimmer reads workouts belonging to their coach, scoped by squad:
--   - group_id IS NULL  → visible to all of that coach's swimmers (back-compat)
--   - group_id set      → visible only to members of that squad
DROP POLICY IF EXISTS swimmer_read_squad_workouts ON public.workouts;
CREATE POLICY swimmer_read_squad_workouts ON public.workouts
  FOR SELECT TO authenticated
  USING (
    coach_id IN (
      SELECT s.coach_id FROM public.swimmers s WHERE s.auth_id = auth.uid()
    )
    AND (
      group_id IS NULL
      OR group_id IN (
        SELECT sg.group_id FROM public.swimmer_groups sg
        JOIN public.swimmers s2 ON s2.id = sg.swimmer_id
        WHERE s2.auth_id = auth.uid()
      )
    )
  );

-- Swimmer reads the squads they belong to (needed for settings + slots).
DROP POLICY IF EXISTS swimmer_read_own_groups ON public.groups;
CREATE POLICY swimmer_read_own_groups ON public.groups
  FOR SELECT TO authenticated
  USING (
    id IN (
      SELECT sg.group_id FROM public.swimmer_groups sg
      JOIN public.swimmers s ON s.id = sg.swimmer_id
      WHERE s.auth_id = auth.uid()
    )
  );

-- Swimmer reads their own squad memberships.
DROP POLICY IF EXISTS swimmer_read_own_memberships ON public.swimmer_groups;
CREATE POLICY swimmer_read_own_memberships ON public.swimmer_groups
  FOR SELECT TO authenticated
  USING (
    swimmer_id IN (
      SELECT s.id FROM public.swimmers s WHERE s.auth_id = auth.uid()
    )
  );

-- ---------------------------------------------------------------------------
-- 5. Backfill — make the empty groups scaffolding real
-- ---------------------------------------------------------------------------

-- One default squad per coach that doesn't already have one.
INSERT INTO public.groups (coach_id, name)
SELECT c.id, 'Squad'
FROM public.coaches c
WHERE NOT EXISTS (
  SELECT 1 FROM public.groups g WHERE g.coach_id = c.id
);

-- Enroll every un-enrolled swimmer into their coach's first squad.
INSERT INTO public.swimmer_groups (swimmer_id, group_id)
SELECT s.id, g.id
FROM public.swimmers s
JOIN LATERAL (
  SELECT g2.id FROM public.groups g2
  WHERE g2.coach_id = s.coach_id
  ORDER BY g2.created_at
  LIMIT 1
) g ON true
WHERE s.archived_at IS NULL
  AND NOT EXISTS (
    SELECT 1 FROM public.swimmer_groups sg WHERE sg.swimmer_id = s.id
  );

-- Seed Mon-Fri AM slots so MyScheduleView renders a real grid on first run.
-- weekday: 1=Mon .. 5=Fri (0=Sunday convention).
INSERT INTO public.squad_session_slot (group_id, weekday, am_pm)
SELECT g.id, d.weekday, 'AM'
FROM public.groups g
CROSS JOIN (VALUES (1),(2),(3),(4),(5)) AS d(weekday)
ON CONFLICT (group_id, weekday, am_pm) DO NOTHING;

COMMIT;
