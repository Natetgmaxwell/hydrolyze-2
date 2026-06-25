-- Migration: v2.0.3 — invite-code onboarding schema + functions
--
-- Timestamp: 2026-06-23
-- Author: TARS (built on user feedback for invite-code flow)
--
-- WHY THIS MIGRATION EXISTS
-- Per Phase 2.8 spec at plans/swimmer-invite-code-onboarding-design-spec.md:
-- The user reframed the Phase 2.3 onboarding flow from coach-side
-- account creation to swimmer-driven signup with coach-issued invite codes.
-- The coach generates a 6-char code (expires in 7 days), the swimmer
-- signs up using the code, and the existing data becomes visible
-- automatically via the swimmer_own_* RLS policies already shipped
-- in Phase 2.1.
--
-- Pre-migration verification (per supabase-project-ops skill):
-- - swimmers table has auth_id + email columns (Phase 2.1)
-- - create_swimmer_account RPC exists with (email, password, coach_id, swimmer_id)
--   signature — kept as admin path per user's "keep backwards-compat" answer
-- - The 8 swimmer-scoped RLS policies are active (Phase 2.1)
-- - The data-porting question is structurally answered: swimmer_id is
--   permanent; setting swimmers.auth_id turns on data visibility via
--   the existing RLS policies. No data migration script needed.
--
-- Run in Supabase SQL Editor or via:
--   supabase db query --linked -f <this-file>

BEGIN;

-- ============================================================
-- 2.8.1.a: ADD INVITE CODE COLUMNS
-- ============================================================

ALTER TABLE swimmers
  ADD COLUMN IF NOT EXISTS invite_code text,
  ADD COLUMN IF NOT EXISTS invite_code_expires_at timestamptz;

-- Partial unique index so NULL codes (unused) don't conflict and only
-- active codes count toward the unique constraint.
CREATE UNIQUE INDEX IF NOT EXISTS swimmers_invite_code_active
  ON swimmers(invite_code)
  WHERE invite_code IS NOT NULL;

-- Lookup index for the redeem flow (find swimmer by code, check expiry).
-- Same partial-index pattern as above for fast lookup.
CREATE INDEX IF NOT EXISTS swimmers_invite_code_lookup
  ON swimmers(invite_code)
  WHERE invite_code IS NOT NULL;

-- ============================================================
-- 2.8.1.b: GENERATE INVITE CODE FUNCTION
-- ============================================================
--
-- Coach calls this. Sets a 6-char code on the swimmer row + the
-- expiry timestamp. Idempotent: calling it multiple times for the
-- same swimmer overwrites the previous code.
--
-- SECURITY DEFINER so the coach's auth.uid() context is preserved.
-- Verifies the caller is the coach who owns the swimmer.

CREATE OR REPLACE FUNCTION generate_invite_code(
  p_swimmer_id uuid,
  p_expires_in_days int DEFAULT 7
) RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_code text;
  v_swimmer_coach_id uuid;
  v_caller_coach_id uuid;
BEGIN
  -- Verify the swimmer exists
  SELECT coach_id INTO v_swimmer_coach_id
  FROM swimmers
  WHERE id = p_swimmer_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'swimmer not found: %', p_swimmer_id;
  END IF;

  -- Verify the caller is the coach who owns this swimmer
  SELECT id INTO v_caller_coach_id
  FROM coaches
  WHERE auth_id = auth.uid();
  IF v_caller_coach_id IS NULL THEN
    RAISE EXCEPTION 'caller is not a coach (no coach row for auth.uid())';
  END IF;
  IF v_caller_coach_id <> v_swimmer_coach_id THEN
    RAISE EXCEPTION 'caller is not the coach for this swimmer';
  END IF;

  -- Generate a 6-char alphanumeric code (uppercase + digits),
  -- excluding ambiguous chars (0/O/1/I/L) for readability.
  -- md5() gives 32 hex chars; take 6; translate ambiguous chars.
  v_code := upper(substring(md5(random()::text || clock_timestamp()::text)
                            from 1 for 6));
  v_code := translate(v_code, '0OIL', 'QDZX');

  -- Set the code + expiry (overwrites any previous code on the row)
  UPDATE swimmers
  SET invite_code = v_code,
      invite_code_expires_at = now() + (p_expires_in_days || ' days')::interval
  WHERE id = p_swimmer_id;

  RETURN v_code;
END;
$$;

-- ============================================================
-- 2.8.1.c: REDEEM INVITE CODE FUNCTION
-- ============================================================
--
-- Swimmer calls this at signup. Validates the code, creates the
-- auth.users row, sets swimmers.auth_id + swimmers.email, clears
-- the invite_code (one-time use).
--
-- SECURITY DEFINER so the function can write to auth.users
-- (the caller doesn't have INSERT on auth.users by default).

CREATE OR REPLACE FUNCTION redeem_invite_code(
  p_code text,
  p_email text,
  p_password text,
  p_first_name text,
  p_last_name text DEFAULT NULL
) RETURNS swimmers
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_swimmer swimmers%ROWTYPE;
  v_auth_id uuid;
  v_full_name text;
BEGIN
  -- Find swimmer by code, check expiry (not past + not cleared)
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

  -- Compose the display name for auth.users.raw_user_meta_data
  v_full_name := trim(p_first_name) || ' ' || coalesce(trim(p_last_name), '');

  -- Create the auth.users row. Mirrors the create_swimmer_account
  -- pattern from Phase 2.3 — same Supabase auth.users shape.
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
    crypt(p_password, gen_salt('bf')),
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

  -- Update swimmer: link auth_id, set email, clear the code
  -- (one-time use). If the same email is already on the row from
  -- a prior failed attempt, overwrite.
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
-- VERIFY THE WINS
-- ============================================================

-- Confirm the new columns are there
DO $$
DECLARE
  has_invite_code boolean;
  has_expires_at boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'swimmers'
      AND column_name = 'invite_code'
  ) INTO has_invite_code;
  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'swimmers'
      AND column_name = 'invite_code_expires_at'
  ) INTO has_expires_at;
  IF NOT has_invite_code OR NOT has_expires_at THEN
    RAISE EXCEPTION 'column verification failed: invite_code=% expires_at=%',
      has_invite_code, has_expires_at;
  END IF;
  RAISE NOTICE 'column verification passed: invite_code + invite_code_expires_at present';
END $$;

-- Confirm both functions exist
DO $$
DECLARE
  has_generate boolean;
  has_redeem boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM pg_proc WHERE proname = 'generate_invite_code'
  ) INTO has_generate;
  SELECT EXISTS (
    SELECT 1 FROM pg_proc WHERE proname = 'redeem_invite_code'
  ) INTO has_redeem;
  IF NOT has_generate OR NOT has_redeem THEN
    RAISE EXCEPTION 'function verification failed: generate=% redeem=%',
      has_generate, has_redeem;
  END IF;
  RAISE NOTICE 'function verification passed: generate_invite_code + redeem_invite_code present';
END $$;

COMMIT;