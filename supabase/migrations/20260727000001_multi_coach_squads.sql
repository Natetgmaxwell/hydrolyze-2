-- v1.18 — Multi-coach squads
--
-- Spec: one coach has many squads, one squad has many coaches.
-- Adds coach_squads join table, backfills existing groups.coach_id as owner,
-- and updates RLS policies that gated on groups.coach_id to gate on
-- coach_squads instead.
--
-- groups.coach_id is intentionally kept (deprecated) so existing app inserts
-- continue to work; an AFTER INSERT trigger mirrors it into coach_squads.
--
-- Backfill: every existing group owner gets an owner row in coach_squads.

BEGIN;

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. coach_squads join table
-- ═════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.coach_squads (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  coach_id    uuid NOT NULL REFERENCES public.coaches(id) ON DELETE CASCADE,
  group_id    uuid NOT NULL REFERENCES public.groups(id) ON DELETE CASCADE,
  role        text NOT NULL DEFAULT 'coach' CHECK (role IN ('owner','coach')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (coach_id, group_id)
);

CREATE INDEX IF NOT EXISTS idx_coach_squads_coach
  ON public.coach_squads (coach_id);
CREATE INDEX IF NOT EXISTS idx_coach_squads_group
  ON public.coach_squads (group_id);

ALTER TABLE public.coach_squads ENABLE ROW LEVEL SECURITY;

-- A coach can read their own coach_squads rows.
DROP POLICY IF EXISTS coach_read_own_squads ON public.coach_squads;
CREATE POLICY coach_read_own_squads ON public.coach_squads
  FOR SELECT TO authenticated
  USING (coach_id IN (SELECT id FROM public.coaches WHERE auth_id = auth.uid()));

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. SECURITY DEFINER helpers for squad membership
-- ═════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.current_coach_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT id FROM public.coaches WHERE auth_id = auth.uid() LIMIT 1
$$;

CREATE OR REPLACE FUNCTION public.coached_squad_ids()
RETURNS SETOF uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT group_id FROM public.coach_squads
  WHERE coach_id = public.current_coach_id()
$$;

CREATE OR REPLACE FUNCTION public.is_coach_of_squad(p_group_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.coach_squads
    WHERE coach_id = public.current_coach_id()
      AND group_id = p_group_id
  )
$$;

GRANT EXECUTE ON FUNCTION public.current_coach_id()      TO authenticated;
GRANT EXECUTE ON FUNCTION public.coached_squad_ids()     TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_coach_of_squad(uuid) TO authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Backfill existing groups.coach_id into coach_squads as owner
-- ═════════════════════════════════════════════════════════════════════════════

INSERT INTO public.coach_squads (coach_id, group_id, role)
SELECT g.coach_id, g.id, 'owner'
FROM public.groups g
WHERE g.coach_id IS NOT NULL
ON CONFLICT (coach_id, group_id) DO NOTHING;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Trigger: every newly created group gets an owner row in coach_squads
-- ═════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.trg_groups_ensure_owner()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.coach_squads (coach_id, group_id, role)
  VALUES (NEW.coach_id, NEW.id, 'owner')
  ON CONFLICT (coach_id, group_id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS groups_ensure_owner ON public.groups;
CREATE TRIGGER groups_ensure_owner
  AFTER INSERT ON public.groups
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_groups_ensure_owner();

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Update group-scoped RLS policies to use coach_squads
-- ═════════════════════════════════════════════════════════════════════════════
-- groups: any coach of the squad can read/manage. Creation still gated by
-- the deprecated groups.coach_id column so direct app inserts keep working.
-- The WITH CHECK uses current_coach_id() (SECURITY DEFINER) instead of a
-- bare subquery into coaches, because coaches has its own RLS and the
-- subquery would be silently filtered under the caller's role.
DROP POLICY IF EXISTS coach_own_groups ON public.groups;
CREATE POLICY coach_own_groups ON public.groups
  FOR ALL TO authenticated
  USING (
    public.is_coach_of_squad(id)
  )
  WITH CHECK (
    public.is_coach_of_squad(id)
    OR coach_id = public.current_coach_id()
  );

-- swimmer_groups: any coach of the squad can add/remove swimmers.
DROP POLICY IF EXISTS coach_own_swimmer_groups ON public.swimmer_groups;
CREATE POLICY coach_own_swimmer_groups ON public.swimmer_groups
  FOR ALL TO authenticated
  USING (group_id IN (SELECT public.coached_squad_ids()))
  WITH CHECK (group_id IN (SELECT public.coached_squad_ids()));

-- squad_session_slot: any coach of the squad can manage slots.
DROP POLICY IF EXISTS coach_own_squad_slots ON public.squad_session_slot;
CREATE POLICY coach_own_squad_slots ON public.squad_session_slot
  FOR ALL TO authenticated
  USING (group_id IN (SELECT public.coached_squad_ids()))
  WITH CHECK (group_id IN (SELECT public.coached_squad_ids()));

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. Update workout policies to allow any coach of a squad, plus the author
-- ═════════════════════════════════════════════════════════════════════════════

-- Re-enable RLS on workouts (it was disabled by an older migration).
ALTER TABLE public.workouts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS coach_own_workouts ON public.workouts;
CREATE POLICY coach_own_workouts ON public.workouts
  FOR ALL TO authenticated
  USING (
    coach_id = (SELECT public.current_coach_id())
    OR public.is_coach_of_squad(group_id)
  )
  WITH CHECK (
    coach_id = (SELECT public.current_coach_id())
    OR public.is_coach_of_squad(group_id)
  );

DROP POLICY IF EXISTS coach_own_workout_sets ON public.workout_sets;
CREATE POLICY coach_own_workout_sets ON public.workout_sets
  FOR ALL TO authenticated
  USING (
    workout_id IN (
      SELECT w.id FROM public.workouts w
      WHERE w.coach_id = (SELECT public.current_coach_id())
         OR public.is_coach_of_squad(w.group_id)
    )
  );

-- swimmer_attendance_intent: coach override works for any coach of the squad.
DROP POLICY IF EXISTS coach_intent_override_policy ON public.swimmer_attendance_intent;
CREATE POLICY coach_intent_override_policy ON public.swimmer_attendance_intent
  FOR ALL TO authenticated
  USING (
    workout_id IN (
      SELECT w.id FROM public.workouts w
      WHERE w.coach_id = (SELECT public.current_coach_id())
         OR public.is_coach_of_squad(w.group_id)
    )
  )
  WITH CHECK (
    workout_id IN (
      SELECT w.id FROM public.workouts w
      WHERE w.coach_id = (SELECT public.current_coach_id())
         OR public.is_coach_of_squad(w.group_id)
    )
  );

-- 7. Swimmer workout read: group-based. NULL-group workouts are visible when
--    authored by any coach of the swimmer's squads.
DROP POLICY IF EXISTS swimmer_read_squad_workouts ON public.workouts;
CREATE POLICY swimmer_read_squad_workouts ON public.workouts
  FOR SELECT TO authenticated
  USING (
    group_id IN (SELECT public.current_swimmer_group_ids())
    OR (
      group_id IS NULL
      AND coach_id IN (
        SELECT cs.coach_id
        FROM public.coach_squads cs
        WHERE cs.group_id IN (SELECT public.current_swimmer_group_ids())
      )
    )
  );

COMMENT ON TABLE public.coach_squads IS
  'Many-to-many coaches↔squads. A squad can have multiple coaches; a coach can coach multiple squads. role distinguishes owner (deprecated groups.coach_id backfill) from added coaches.';

COMMENT ON COLUMN public.groups.coach_id IS
  'DEPRECATED: kept for back-compat and creation-path gating. Canonical squad ownership/coaching is public.coach_squads.';

COMMIT;
