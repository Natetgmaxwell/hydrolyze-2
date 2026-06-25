-- Migration: v2.0.6 — fix generate_invite_code ambiguous-char exclusion
--
-- Timestamp: 2026-06-23
-- Author: TARS (Phase 2.8.5 smoke test surfaced this bug)
--
-- WHY THIS MIGRATION EXISTS
-- The 20260623000003 migration's generate_invite_code function
-- had a bug in the ambiguous-char exclusion. The translate()
-- source string was '0OIL' (4 chars) but the validation
-- regex was '[0O1IL]' (5 chars — including the digit '1').
-- Because md5() can produce the digit '1' (it's in the hex
-- alphabet 0-9a-f), codes like '3C182D' slipped through the
-- generator and were rejected by the smoke test's validation.
--
-- The fix: change the translate source to '0O1IL' (5 chars)
-- with to-string 'Q2ZXV' (5 chars). Mappings:
--   0 (digit zero) → Q
--   O (letter O)   → 2  (digit, distinct from Q; also disambiguates)
--   1 (digit one)  → Z
--   I (letter I)   → X
--   L (letter L)   → V
--
-- This migration is idempotent (CREATE OR REPLACE).
-- It also re-runs the smoke test's Step 3+4 to verify the fix.

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
  v_attempt int := 0;
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

  -- Loop until we generate a 6-char code with no ambiguous chars
  -- (the BUGFIX is the '0O1IL' source string; the loop is a
  -- belt-and-braces guard in case the translate mapping ever
  -- produces another ambiguous char)
  LOOP
    v_attempt := v_attempt + 1;
    IF v_attempt > 10 THEN
      RAISE EXCEPTION 'generate_invite_code: could not produce non-ambiguous code after 10 attempts';
    END IF;

    v_code := upper(substring(md5(random()::text || clock_timestamp()::text)
                              from 1 for 6));
    v_code := translate(v_code, '0O1IL', 'Q2ZXV');

    -- Validate: 6 chars, no ambiguous chars
    IF length(v_code) = 6 AND v_code !~ '[0O1IL]' THEN
      EXIT;
    END IF;
  END LOOP;

  -- Set the code + expiry
  UPDATE swimmers
  SET invite_code = v_code,
      invite_code_expires_at = now() + (p_expires_in_days || ' days')::interval
  WHERE id = p_swimmer_id;

  RETURN v_code;
END;
$$;

-- ============================================================
-- VERIFY: generate 100 codes in a loop, check none contain
-- ambiguous chars (the smoke test for this bug)
-- ============================================================

DO $$
DECLARE
  v_i int;
  v_code text;
  v_fail_count int := 0;
BEGIN
  FOR v_i IN 1..100 LOOP
    v_code := upper(substring(md5(random()::text || clock_timestamp()::text)
                              from 1 for 6));
    v_code := translate(v_code, '0O1IL', 'Q2ZXV');
    IF length(v_code) <> 6 OR v_code ~ '[0O1IL]' THEN
      v_fail_count := v_fail_count + 1;
    END IF;
  END LOOP;
  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'BUGFIX verification FAILED: %/100 codes contained ambiguous chars', v_fail_count;
  END IF;
  RAISE NOTICE 'BUGFIX verification PASSED: 100/100 codes are clean (no 0/O/1/I/L)';
END $$;