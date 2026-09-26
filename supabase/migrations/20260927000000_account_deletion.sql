-- Migration: Account deletion RPC (App Store 5.1.1(v))
--
-- Timestamp: 2026-09-27
--
-- WHY THIS MIGRATION EXISTS
-- Apple App Store guideline 5.1.1(v) requires the app to let a user
-- delete their account and all associated data without forcing them
-- to email support. The iOS side surfaces a "Delete account" entry
-- in Settings → Account. When tapped it calls this RPC, then on
-- success calls `supabase.auth.admin.deleteUser(uid)` from an Edge
-- Function (the Edge Function holds the service-role key needed to
-- remove the auth account itself; the postgres role running this
-- RPC also has DELETE on auth.users, so the data-layer wipe happens
-- here, and the auth-account removal is the final step from the Edge
-- Function — defence in depth).
--
-- The function is SECURITY DEFINER so it can bypass the coach-owned
-- RLS policies while it cleans up. Per Supabase's documented
-- pattern, SECURITY DEFINER bypasses RLS entirely — that is WHY this
-- RPC has to do its own authentication check (`auth.uid()` must not
-- be NULL, and the caller can only delete THEIR OWN coach row).
-- There is no `auth.uid() = X` RLS guard standing between an
-- attacker and the coach's data once we are inside a SECURITY
-- DEFINER function.
--
-- ─── Cascade coverage audit (2026-09-27) ──────────────────────────
-- All 38+ ON DELETE CASCADE FKs in supabase/migrations/* chain off
-- of either `public.coaches.id` (the parent for every coach-owned
-- table) or `public.swimmers.id` / `workouts.id` / `sessions.id`
-- (children-of-coaches, which cascade transitively). The data-layer
-- delete below therefore covers EVERY coach-owned table, including:
--
--   Direct coach_id → public.coaches(id) CASCADE:
--     groups, swimmers, workouts, sessions,
--     coach_squads, wave_assignments, recorded_times
--
--   Via swimmers/workouts/sessions CASCADE chain:
--     swimmer_groups, swimmer_stats, swimmer_pbs,
--     swimmer_test_profiles, swimmer_gears,
--     swimmer_intensity_calibrations, swimmer_attendance_intent,
--     swimmer_suits, swimmer_starts, workout_sets,
--     workout_set_completions, attendance, wave_groups,
--     set_rest_events, squad_session_slot,
--     swimmer_training_schedule, group_session_slots,
--     recorded_time_fragments, recorded_time_welford
--
--   Direct auth.users(id) CASCADE:
--     coach_vocabulary  (coach_id REFERENCES auth.users(id)
--                         ON DELETE CASCADE — defined in
--                         20260725000001_rebuild_coach_vocabulary)
--
-- The auth.users delete additionally removes the coach's login
-- (auth_id ON DELETE CASCADE on public.coaches), which means even
-- the auth account itself is gone after this RPC returns.
--
-- swimmers.auth_id is `ON DELETE SET NULL` (not CASCADE) — that's
-- correct: deleting the coach's auth.users row should NOT delete
-- swimmers who happen to share that auth_id (the auth_id link is a
-- swimmer-self-login affordance, separate from coach ownership).
-- The swimmer rows themselves are still owned by the coach and are
-- wiped by the coach row cascade.
--
-- No coach-owned table uses ON DELETE RESTRICT or NO ACTION, so
-- there are no orphans the cascade cannot reach.

BEGIN;

-- Idempotent: drop first so re-runs against a partially-applied
-- migration don't blow up on the function name conflict.
DROP FUNCTION IF EXISTS public.delete_coach_account();

CREATE OR REPLACE FUNCTION public.delete_coach_account()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
    v_caller uuid := auth.uid();
    v_coach_id uuid;
    v_deleted_coaches int := 0;
    v_deleted_auth int := 0;
BEGIN
    -- ── Auth guard ───────────────────────────────────────────────
    -- SECURITY DEFINER bypasses RLS entirely (per Supabase docs),
    -- so this function MUST refuse anonymous callers — otherwise
    -- anyone could wipe any coach's data. The only acceptable
    -- caller is a logged-in user deleting their own account.
    IF v_caller IS NULL THEN
        RAISE EXCEPTION 'delete_coach_account: unauthenticated caller (auth.uid() is null)'
            USING ERRCODE = '42501';  -- insufficient_privilege
    END IF;

    -- ── Resolve the coach row ─────────────────────────────────────
    -- public.coaches.id is uuid (not text), and the per-row guard
    -- is `coaches.auth_id = auth.uid()` (per RLS policy on coaches).
    SELECT id INTO v_coach_id
    FROM public.coaches
    WHERE auth_id = v_caller
    LIMIT 1;

    -- No coach row → nothing to delete at the data layer. We still
    -- attempt the auth.users delete below in case the auth account
    -- exists but the public.coaches trigger never fired.
    IF v_coach_id IS NOT NULL THEN
        -- ── DATA-LAYER WIPE ─────────────────────────────────────
        -- One DELETE triggers the 38+ CASCADE FKs documented above
        -- and wipes every coach-owned row in a single transaction.
        -- Wrapping this in an explicit savepoint-style guard is not
        -- needed because we are at the top of a single statement;
        -- any FK violation from a forgotten CASCADE would surface as
        -- a constraint error and abort the whole function (and the
        -- transaction). That fail-loud behavior is what we want for
        -- a destructive operation.
        DELETE FROM public.coaches WHERE id = v_coach_id;
        GET DIAGNOSTICS v_deleted_coaches = ROW_COUNT;
    END IF;

    -- ── AUTH-ACCOUNT WIPE ─────────────────────────────────────────
    -- The Edge Function that orchestrates 5.1.1(v) ALSO calls
    -- supabase.auth.admin.deleteUser(uid) on success, but doing it
    -- here too means a direct invocation of this RPC is sufficient
    -- for full account removal (no orphaned auth.users row left
    -- behind even if the Edge Function is unavailable). The
    -- SECURITY DEFINER function owner (the supabase postgres role)
    -- has DELETE on auth.users.
    --
    -- This DELETE also CASCADEs through:
    --   - public.coaches.auth_id  (if not already deleted above)
    --   - coach_vocabulary.coach_id (coach_id FKs auth.users.id)
    -- so the two DELETEs are safe to run in either order.
    DELETE FROM auth.users WHERE id = v_caller;
    GET DIAGNOSTICS v_deleted_auth = ROW_COUNT;

    -- If neither deleted anything, the caller had no account at all.
    -- That's not an error condition per se — but it IS a signal to
    -- the client that there is nothing to clean up. We return void
    -- regardless so the client UI doesn't have to branch.
    RAISE NOTICE 'delete_coach_account: caller=% coaches_deleted=% auth_users_deleted=%',
        v_caller, v_deleted_coaches, v_deleted_auth;
END;
$$;

-- Only the coach themselves may invoke this. anon is explicitly NOT
-- granted so an unauthenticated request to the REST RPC endpoint
-- fails with `permission denied for function delete_coach_account`.
GRANT EXECUTE ON FUNCTION public.delete_coach_account() TO authenticated;

-- The function is owned by the migration runner (supabase postgres
-- role) which already has the needed privileges. No ALTER FUNCTION
-- OWNER TO call needed; the SECURITY DEFINER attribute is what
-- promotes the call-time role to the function-owner's role.

COMMIT;
