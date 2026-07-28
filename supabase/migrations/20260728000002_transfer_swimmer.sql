-- Migration: transfer_swimmer RPC — coach-to-coach swimmer transfer
--
-- A swimmer changes coaches/programs. The current coach calls this RPC
-- to release the swimmer to a new coach. The swimmer's PBs, profile,
-- and training schedule follow automatically via RLS (which keys on
-- swimmers.coach_id). Historical recorded_times stay with the old
-- coach's sessions (they're the old coach's work product); the swimmer
-- retains visibility via swimmer_own_* policies.
--
-- The swimmer is removed from their current squad (swimmer_groups)
-- because the old squad belongs to the old coach. The new coach
-- assigns the swimmer to one of their squads afterward.
--
-- Arguments:
--   p_swimmer_id   — the swimmer to transfer
--   p_new_coach_id — the receiving coach
--
-- Returns: the updated swimmers row

BEGIN;

DROP FUNCTION IF EXISTS public.transfer_swimmer(uuid, uuid);

CREATE OR REPLACE FUNCTION public.transfer_swimmer(
    p_swimmer_id uuid,
    p_new_coach_id uuid
)
RETURNS swimmers
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_swimmer swimmers%ROWTYPE;
    v_caller_coach_id uuid;
    v_new_coach_exists boolean;
BEGIN
    -- 1. Get the swimmer row
    SELECT * INTO v_swimmer
    FROM swimmers
    WHERE id = p_swimmer_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'transfer_swimmer: swimmer % not found', p_swimmer_id
            USING ERRCODE = 'P0002';
    END IF;

    -- 2. Verify the caller is the current coach
    SELECT id INTO v_caller_coach_id
    FROM coaches
    WHERE auth_id = auth.uid();
    IF v_caller_coach_id IS NULL THEN
        RAISE EXCEPTION 'transfer_swimmer: caller is not a coach'
            USING ERRCODE = '42501';
    END IF;
    IF v_caller_coach_id <> v_swimmer.coach_id THEN
        RAISE EXCEPTION 'transfer_swimmer: caller is not the current coach for swimmer %',
            p_swimmer_id
            USING ERRCODE = '42501';
    END IF;

    -- 3. Verify the new coach exists and is different
    SELECT EXISTS(
        SELECT 1 FROM coaches WHERE id = p_new_coach_id
    ) INTO v_new_coach_exists;
    IF NOT v_new_coach_exists THEN
        RAISE EXCEPTION 'transfer_swimmer: new coach % not found', p_new_coach_id
            USING ERRCODE = 'P0002';
    END IF;
    IF p_new_coach_id = v_swimmer.coach_id THEN
        RAISE EXCEPTION 'transfer_swimmer: swimmer is already assigned to this coach'
            USING ERRCODE = '22023';
    END IF;

    -- 4. Remove the swimmer from their current squad
    DELETE FROM swimmer_groups WHERE swimmer_id = p_swimmer_id;

    -- 5. Update coach_id to the new coach
    UPDATE swimmers
    SET coach_id = p_new_coach_id,
        updated_at = now()
    WHERE id = p_swimmer_id
    RETURNING * INTO v_swimmer;

    RETURN v_swimmer;
END;
$$;

GRANT EXECUTE ON FUNCTION public.transfer_swimmer(uuid, uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.transfer_swimmer(uuid, uuid) FROM anon, PUBLIC;

COMMENT ON FUNCTION public.transfer_swimmer IS
  'Coach-to-coach swimmer transfer. The current coach releases the swimmer to a new coach. Removes squad membership (old squad belongs to old coach). PBs and profile follow automatically via RLS. Historical recorded_times stay with the old coach sessions.';

COMMIT;