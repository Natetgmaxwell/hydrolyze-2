-- v1.17 Slice 1a — fix RLS infinite recursion introduced by 20260726000001
--
-- Found by the Slice 1 behavioural probe (a swimmer-impersonation query),
-- NOT by the existence checks. Existence checks passed; the policies were
-- structurally broken.
--
-- The cycle:
--   swimmer_groups   --coach_own_swimmer_groups-->  groups
--   groups           --swimmer_read_own_groups  -->  swimmer_groups
--                                                    ^ recursion (42P17)
--
-- Any swimmer-side read of groups, swimmer_groups, squad_session_slot or
-- workouts hit "infinite recursion detected in policy".
--
-- Fix: resolve the swimmer's identity and squad membership in SECURITY
-- DEFINER functions. They bypass RLS internally, so a policy that calls one
-- never re-enters the policy graph. This is the standard Postgres escape
-- from mutually-referential policies.

BEGIN;

-- Swimmer rows owned by the current auth user (usually exactly one).
CREATE OR REPLACE FUNCTION public.current_swimmer_ids()
RETURNS SETOF uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$ SELECT id FROM public.swimmers WHERE auth_id = auth.uid() $$;

-- Squads the current auth user's swimmer belongs to.
CREATE OR REPLACE FUNCTION public.current_swimmer_group_ids()
RETURNS SETOF uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT sg.group_id
  FROM public.swimmer_groups sg
  WHERE sg.swimmer_id IN (SELECT id FROM public.swimmers WHERE auth_id = auth.uid())
$$;

-- The coach who owns the current auth user's swimmer.
CREATE OR REPLACE FUNCTION public.current_swimmer_coach_ids()
RETURNS SETOF uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$ SELECT coach_id FROM public.swimmers WHERE auth_id = auth.uid() $$;

GRANT EXECUTE ON FUNCTION public.current_swimmer_ids()        TO authenticated;
GRANT EXECUTE ON FUNCTION public.current_swimmer_group_ids()  TO authenticated;
GRANT EXECUTE ON FUNCTION public.current_swimmer_coach_ids()  TO authenticated;

-- Rewrite every swimmer-side policy to use the helpers.

DROP POLICY IF EXISTS swimmer_read_own_memberships ON public.swimmer_groups;
CREATE POLICY swimmer_read_own_memberships ON public.swimmer_groups
  FOR SELECT TO authenticated
  USING (swimmer_id IN (SELECT public.current_swimmer_ids()));

DROP POLICY IF EXISTS swimmer_read_own_groups ON public.groups;
CREATE POLICY swimmer_read_own_groups ON public.groups
  FOR SELECT TO authenticated
  USING (id IN (SELECT public.current_swimmer_group_ids()));

DROP POLICY IF EXISTS swimmer_read_squad_slots ON public.squad_session_slot;
CREATE POLICY swimmer_read_squad_slots ON public.squad_session_slot
  FOR SELECT TO authenticated
  USING (group_id IN (SELECT public.current_swimmer_group_ids()));

DROP POLICY IF EXISTS swimmer_read_squad_workouts ON public.workouts;
CREATE POLICY swimmer_read_squad_workouts ON public.workouts
  FOR SELECT TO authenticated
  USING (
    coach_id IN (SELECT public.current_swimmer_coach_ids())
    AND (group_id IS NULL OR group_id IN (SELECT public.current_swimmer_group_ids()))
  );

DROP POLICY IF EXISTS swimmer_own_schedule ON public.swimmer_training_schedule;
CREATE POLICY swimmer_own_schedule ON public.swimmer_training_schedule
  FOR ALL TO authenticated
  USING      (swimmer_id IN (SELECT public.current_swimmer_ids()))
  WITH CHECK (swimmer_id IN (SELECT public.current_swimmer_ids()));

COMMIT;
