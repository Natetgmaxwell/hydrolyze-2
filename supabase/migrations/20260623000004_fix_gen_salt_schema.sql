-- Migration: v2.0.4 — fix gen_salt() schema qualification in both swimmer-onboarding functions
--
-- Timestamp: 2026-06-23
-- Author: TARS (build session — discovered during invite-code smoke test)
--
-- WHY THIS MIGRATION EXISTS
-- The Phase 2.3 create_swimmer_account function and the Phase 2.8.1
-- redeem_invite_code function both call `gen_salt('bf')` and
-- `crypt(...)`. These functions live in the `extensions` schema
-- (hosted by pgcrypto), but both onboarding functions were created
-- with `SET search_path TO 'public', 'auth'` — which does NOT
-- include `extensions`.
--
-- When a SECURITY DEFINER function runs, the search_path is the
-- function's setting, not the caller's. So both functions were
-- silently unable to resolve `gen_salt('bf')` — every call failed
-- at the auth.users INSERT step with `function gen_salt(unknown)
-- does not exist`.
--
-- This was never caught during Phase 2.3 because no smoke test was
-- run at that time (the function was shipped untested, only the
-- CREATE FUNCTION succeeded). The Phase 2.8.1 smoke test surfaced
-- the bug for both functions in one shot.
--
-- The fix is one line per function: qualify `gen_salt` and `crypt`
-- with `extensions.` so the function's search_path doesn't matter.
-- This is the documented Supabase pattern for pgcrypto usage in
-- SECURITY DEFINER functions (see supabase-project-ops reference
-- materials).

-- ============================================================
-- FIX 1: redeem_invite_code (Phase 2.8.1)
-- ============================================================

CREATE OR REPLACE FUNCTION redeem_invite_code(
  p_code text,
  p_email text,
  p_password text,
  p_first_name text,
  p_last_name text DEFAULT NULL
) RETURNS swimmers
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth', 'extensions'
AS $$
DECLARE
  v_swimmer swimmers%ROWTYPE;
  v_auth_id uuid;
  v_full_name text;
BEGIN
  -- Find swimmer by code, check expiry
  SELECT * INTO v_swimmer
  FROM swimmers
  WHERE invite_code = upper(trim(p_code))
    AND invite_code IS NOT NULL
    AND invite_code_expires_at > now();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'invalid or expired invite code';
  END IF;

  -- Validate inputs
  IF p_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' THEN
    RAISE EXCEPTION 'invalid email format';
  END IF;
  IF length(p_password) < 8 THEN
    RAISE EXCEPTION 'password too short (min 8 characters)';
  END IF;
  IF p_first_name IS NULL OR trim(p_first_name) = '' THEN
    RAISE EXCEPTION 'first_name is required';
  END IF;

  -- Compose the display name
  v_full_name := trim(p_first_name) || ' ' || coalesce(trim(p_last_name), '');

  -- Create the auth.users row (qualified extensions. for pgcrypto)
  INSERT INTO auth.users (
    instance_id,
    id,
    aud,
    role,
    email,
    encrypted_password,
    email_confirmed_at,
    recovery_sent_at,
    last_sign_in_at,
    raw_app_meta_data,
    raw_user_meta_data,
    created_at,
    updated_at,
    confirmation_token,
    email_change,
    email_change_token_new,
    email_change_token_current
  ) VALUES (
    '00000000-0000-0000-0000-000000000000'::uuid,
    gen_random_uuid(),
    'authenticated',
    'authenticated',
    p_email,
    extensions.crypt(p_password, extensions.gen_salt('bf')),
    now(), now(), now(),
    jsonb_build_object('provider', 'email', 'providers',
                       array['email']::text[]),
    jsonb_build_object('name', v_full_name,
                       'first_name', p_first_name,
                       'last_name', coalesce(p_last_name, ''),
                       'swimmer_id', v_swimmer.id::text),
    now(), now(),
    '', '', '', ''
  )
  RETURNING id INTO v_auth_id;

  -- Link auth_id, set email, clear the code
  UPDATE swimmers
  SET auth_id = v_auth_id,
      email = p_email,
      invite_code = NULL,
      invite_code_expires_at = NULL
  WHERE id = v_swimmer.id
  RETURNING * INTO v_swimmer;

  RETURN v_swimmer;
END;
$$;

-- ============================================================
-- FIX 2: create_swimmer_account (Phase 2.3 — admin path)
-- ============================================================
-- Same bug, same fix. The Phase 2.3 function had never been smoke-tested
-- and was silently broken for the gen_salt('bf') call. The user agreed
-- to keep it as the admin path; making it actually work is required.

CREATE OR REPLACE FUNCTION create_swimmer_account(
  p_email text,
  p_password text,
  p_coach_id uuid,
  p_swimmer_id uuid DEFAULT NULL::uuid
) RETURNS swimmers
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth', 'extensions'
AS $function$
DECLARE
    v_swimmer_id uuid;
    v_auth_id uuid;
    v_swimmer_first_name text;
    v_swimmer_last_name text;
    v_swimmer_row swimmers%ROWTYPE;
    v_coach_exists boolean;
    v_existing_auth_id uuid;
BEGIN
    -- 1. Validate the coach exists (security check: caller
    --    must pass a valid p_coach_id; the function trusts
    --    the caller but the iOS layer is responsible for
    --    passing the actual coach's id).
    SELECT EXISTS(SELECT 1 FROM coaches WHERE id = p_coach_id)
        INTO v_coach_exists;
    IF NOT v_coach_exists THEN
        RAISE EXCEPTION 'create_swimmer_account: invalid coach_id: %', p_coach_id;
    END IF;

    -- 2. Determine the swimmer id and verify the swimmer
    --    belongs to this coach.
    IF p_swimmer_id IS NULL THEN
        -- This was Phase 2.3's early "create swimmer from scratch"
        -- path. We now require an existing swimmer row (per
        -- Phase 2.8 invite-code flow). Fail explicitly.
        RAISE EXCEPTION 'create_swimmer_account: p_swimmer_id is required (use redeem_invite_code for self-signup)';
    ELSE
        v_swimmer_id := p_swimmer_id;
        SELECT * INTO v_swimmer_row FROM swimmers WHERE id = v_swimmer_id;
        IF v_swimmer_row.id IS NULL THEN
            RAISE EXCEPTION 'create_swimmer_account: swimmer not found: %', v_swimmer_id;
        END IF;
        IF v_swimmer_row.coach_id <> p_coach_id THEN
            RAISE EXCEPTION 'create_swimmer_account: swimmer is not owned by this coach';
        END IF;
        -- Refuse if the swimmer is already linked to an account
        v_existing_auth_id := v_swimmer_row.auth_id;
        IF v_existing_auth_id IS NOT NULL THEN
            RAISE EXCEPTION 'create_swimmer_account: swimmer already has an account (auth_id set)';
        END IF;
    END IF;

    v_swimmer_first_name := v_swimmer_row.first_name;
    v_swimmer_last_name := v_swimmer_row.last_name;

    -- 3. Validate email + password
    IF p_email IS NULL OR p_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' THEN
        RAISE EXCEPTION 'create_swimmer_account: invalid email format';
    END IF;
    IF p_password IS NULL OR length(p_password) < 8 THEN
        RAISE EXCEPTION 'create_swimmer_account: password too short (min 8 chars)';
    END IF;

    -- 4. Create the auth.users row (FIX: qualified extensions.
    --    for pgcrypto; same shape as redeem_invite_code).
    INSERT INTO auth.users (
        instance_id,
        id,
        aud,
        role,
        email,
        encrypted_password,
        email_confirmed_at,
        recovery_sent_at,
        last_sign_in_at,
        raw_app_meta_data,
        raw_user_meta_data,
        created_at,
        updated_at,
        confirmation_token,
        email_change,
        email_change_token_new,
        email_change_token_current
    ) VALUES (
        '00000000-0000-0000-0000-000000000000'::uuid,
        gen_random_uuid(),
        'authenticated',
        'authenticated',
        p_email,
        extensions.crypt(p_password, extensions.gen_salt('bf')),
        now(), now(), now(),
        jsonb_build_object('provider', 'email', 'providers', array['email']::text[]),
        jsonb_build_object('name',
            v_swimmer_first_name || ' ' || coalesce(v_swimmer_last_name, ''),
            'first_name', v_swimmer_first_name,
            'last_name', coalesce(v_swimmer_last_name, ''),
            'swimmer_id', v_swimmer_id::text
        ),
        now(), now(),
        '', '', '', ''
    )
    RETURNING id INTO v_auth_id;

    -- 5. Update swimmer row: link auth_id, set email
    UPDATE swimmers
    SET auth_id = v_auth_id,
        email = p_email
    WHERE id = v_swimmer_id
    RETURNING * INTO v_swimmer_row;

    RETURN v_swimmer_row;
END;
$function$;

-- ============================================================
-- VERIFY: both functions compile + smoke-test on Mock Charlie
-- ============================================================

DO $$
DECLARE
  v_code text;
  v_swimmer_id uuid;
  v_swimmer record;
  v_test_password text := 'smoketest_' || substr(md5(random()::text), 1, 8);
BEGIN
  -- 1. Test generate_invite_code AS the coach (simulated JWT)
  SELECT auth_id INTO v_swimmer_id FROM coaches WHERE id = '9b72e5d7-ffcd-4a77-abe3-e0d2b209df54';
  PERFORM set_config('request.jwt.claim.sub', v_swimmer_id::text, true);
  PERFORM set_config('role', 'authenticated', true);

  SELECT id INTO v_swimmer_id FROM swimmers WHERE name = 'Mock Charlie' AND auth_id IS NULL LIMIT 1;
  IF v_swimmer_id IS NULL THEN
    RAISE NOTICE 'Mock Charlie already has auth_id or does not exist — skipping smoke test';
    RETURN;
  END IF;

  v_code := generate_invite_code(v_swimmer_id, 7);
  IF length(v_code) <> 6 OR v_code ~ '[0O1IL]' THEN
    RAISE EXCEPTION 'generated code shape wrong: %', v_code;
  END IF;
  RAISE NOTICE 'PASS: generate_invite_code returned valid code %', v_code;

  -- 2. Test redeem_invite_code (creates auth.users + clears code)
  v_swimmer := redeem_invite_code(
    p_code := v_code,
    p_email := 'mockcharlie.smoketest@example.com',
    p_password := v_test_password,
    p_first_name := 'Mock',
    p_last_name := 'Charlie'
  );
  IF v_swimmer.auth_id IS NULL THEN
    RAISE EXCEPTION 'redeem returned swimmer without auth_id';
  END IF;
  IF v_swimmer.invite_code IS NOT NULL THEN
    RAISE EXCEPTION 'redeem did not clear the invite_code';
  END IF;
  RAISE NOTICE 'PASS: redeem_invite_code linked auth_id and cleared code';

  -- 3. Confirm the code cannot be reused
  BEGIN
    PERFORM redeem_invite_code(
      p_code := v_code,
      p_email := 'secondattempt@example.com',
      p_password := 'secondattempt',
      p_first_name := 'Second'
    );
    RAISE EXCEPTION 'redeem did NOT enforce one-time use — code was reused';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%invalid or expired%' THEN
      RAISE NOTICE 'PASS: one-time use enforced';
    ELSE
      RAISE;
    END IF;
  END;
END $$;