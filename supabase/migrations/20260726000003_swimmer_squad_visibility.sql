-- v1.17 Slice 8c -- squad visibility, the version that ships.
--
-- Spec: "When squad visibility is 'squad', a swimmer sees the
-- attending roster." The DB needs to admit SELECT on intent rows of
-- teammates, but ONLY when:
--   1. the calling swimmer is a member of the same group as the target
--   2. that group is owned by the same coach as both swimmers
--   3. the group's settings has attendance_visibility = 'squad'
--
-- A SECURITY DEFINER helper resolves (1) and (3) so the policy's
-- USING doesn't recursively trigger RLS on the helper's own tables.
-- (1) was the bug: the first cut used bare subqueries, the subquery
-- inherited the caller's role, and the caller's RLS on swimmers and
-- swimmer_groups blocked the read. Same class of bug Slice 1's
-- current_swimmer_* helpers exist to fix.
--
-- Idempotent: drops the first-cut policy and the helper before
-- recreating both. Safe to re-run.
BEGIN;

DROP POLICY IF EXISTS swimmer_squad_attendance_read ON public.swimmer_attendance_intent;
DROP FUNCTION IF EXISTS public.swimmer_squad_visibility_active(uuid);

CREATE OR REPLACE FUNCTION public.swimmer_squad_visibility_active(
  p_swimmer_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.swimmer_groups sg_me
    JOIN public.swimmer_groups sg_them ON sg_them.group_id = sg_me.group_id
    JOIN public.swimmers them ON them.id = sg_them.swimmer_id
    JOIN public.swimmers me ON me.id = sg_me.swimmer_id
    JOIN public.groups g ON g.id = sg_me.group_id
    WHERE me.auth_id = auth.uid()
      AND them.id = p_swimmer_id
      AND me.id <> them.id
      AND (g.settings->>'attendance_visibility') = 'squad'
      AND them.archived_at IS NULL
  );
$$;

GRANT EXECUTE ON FUNCTION public.swimmer_squad_visibility_active(uuid) TO authenticated;

CREATE POLICY swimmer_squad_attendance_read
  ON public.swimmer_attendance_intent
  FOR SELECT
  TO authenticated
  USING (public.swimmer_squad_visibility_active(swimmer_id));

COMMENT ON POLICY swimmer_squad_attendance_read ON public.swimmer_attendance_intent IS
  'v1.17 Slice 8c: a signed-in swimmer can SELECT intent rows of '
  'teammates in their squad, but only if that squad is in attendance_visibility = ''squad'' '
  'mode. The check goes through a SECURITY DEFINER function to bypass RLS '
  'on the helper''s own tables. In ''private'' mode the helper returns FALSE, '
  'so cross-swimmer reads return 0.';

COMMIT;
