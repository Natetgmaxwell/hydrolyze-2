-- Migration: v2.0.5 — invite-code end-to-end smoke test (server side)
--
-- Timestamp: 2026-06-23
-- Author: TARS (Phase 2.8.5 — the final slice of the invite-code spec)
--
-- This is NOT a real migration — it's a self-contained smoke test
-- that exercises the full invite-code flow end-to-end on the live
-- DB. Run via:
--   supabase db query --linked -f <this-file>
--
-- What this script tests (steps 1-8):
-- 1. Picks a test swimmer (Mock Alice, who has no auth_id yet)
-- 2. Simulates the coach session (sets JWT claims)
-- 3. Generates an invite code via generate_invite_code RPC
-- 4. Verifies the row has the code + 7-day expiry
-- 5. Redeems the code via redeem_invite_code RPC
-- 6. Verifies the row now has auth_id + email, code is cleared
-- 7. Tries to reuse the cleared code → expects error (one-time use)
-- 8. RLS visibility — verifies the new auth user can see own data
--
-- IMPORTANT: the cleanup step (DELETE FROM auth.users WHERE id=...)
-- at the bottom of the original script requires the postgres
-- superuser role (the supabase CLI's service_role JWT does NOT
-- have DELETE permission on auth.users). The cleanup is therefore
-- NOT included in this script — the iOS UI test below will do
-- the auth.users cleanup if needed, or you can run it manually
-- from the Supabase Dashboard SQL Editor as the postgres role:
--
--   DELETE FROM auth.users WHERE email LIKE 'smoketest-%';
--   UPDATE swimmers SET auth_id=NULL, email=NULL,
--     invite_code=NULL, invite_code_expires_at=NULL
--   WHERE name IN ('Mock Alice', 'Mock Bob', 'Mock Charlie');
--
-- After this script completes with exit 0, the iOS UI smoke
-- checklist at the bottom should be run on Mac Studio.

DO $$
DECLARE
  v_coach_id uuid := '9b72e5d7-ffcd-4a77-abe3-e0d2b209df54';
  v_coach_auth_id uuid;
  v_swimmer_id uuid;
  v_code text;
  v_expires timestamptz;
  v_email text := 'smoketest-' || substr(md5(random()::text), 1, 8) || '@example.com';
  v_password text := 'smoke_' || substr(md5(random()::text), 1, 8);
  v_swimmer record;
  v_auth_id uuid;
  v_before_count int;
  v_after_count int;
BEGIN
  RAISE NOTICE '=== PHASE 2.8.5 INVITE-CODE END-TO-END SMOKE TEST ===';
  RAISE NOTICE '';

  -- -------------------------------------------------------------
  -- Step 1: Pick a swimmer who has no auth_id (clean test target)
  -- -------------------------------------------------------------
  SELECT id INTO v_swimmer_id FROM swimmers
  WHERE name = 'Mock Alice' AND auth_id IS NULL
  LIMIT 1;
  IF v_swimmer_id IS NULL THEN
    RAISE EXCEPTION 'Mock Alice has no auth_id OR not found — pick a different swimmer for the test';
  END IF;
  RAISE NOTICE 'Step 1 PASS: picked swimmer Mock Alice (id=%)', v_swimmer_id;

  -- -------------------------------------------------------------
  -- Step 2: Simulate the coach session (set JWT claims)
  -- -------------------------------------------------------------
  SELECT auth_id INTO v_coach_auth_id FROM coaches WHERE id = v_coach_id;
  IF v_coach_auth_id IS NULL THEN
    RAISE EXCEPTION 'coach auth_id not found for coach_id=%', v_coach_id;
  END IF;
  PERFORM set_config('request.jwt.claim.sub', v_coach_auth_id::text, true);
  PERFORM set_config('role', 'authenticated', true);
  RAISE NOTICE 'Step 2 PASS: simulated coach session (auth_id=%)', v_coach_auth_id;

  -- -------------------------------------------------------------
  -- Step 3: Generate invite code via RPC
  -- -------------------------------------------------------------
  v_code := generate_invite_code(v_swimmer_id, 7);
  RAISE NOTICE 'Step 3 PASS: generated code "%" (length=%)', v_code, length(v_code);

  -- -------------------------------------------------------------
  -- Step 4: Verify row state (code + 7-day expiry)
  -- -------------------------------------------------------------
  SELECT invite_code, invite_code_expires_at
    INTO v_code, v_expires
    FROM swimmers WHERE id = v_swimmer_id;
  IF v_code IS NULL OR length(v_code) <> 6 THEN
    RAISE EXCEPTION 'Step 4 FAIL: code not set or wrong length';
  END IF;
  IF v_expires < now() OR v_expires > now() + interval '8 days' THEN
    RAISE EXCEPTION 'Step 4 FAIL: expiry outside expected 7-day window (got %)', v_expires;
  END IF;
  IF v_code ~ '[0O1IL]' THEN
    RAISE EXCEPTION 'Step 4 FAIL: code contains ambiguous chars: %', v_code;
  END IF;
  RAISE NOTICE 'Step 4 PASS: row has code "%" expiring %', v_code, v_expires;

  -- -------------------------------------------------------------
  -- Step 5: Redeem the code (creates auth.users + links auth_id)
  -- -------------------------------------------------------------
  v_swimmer := redeem_invite_code(
    p_code := v_code,
    p_email := v_email,
    p_password := v_password,
    p_first_name := 'Mock',
    p_last_name := 'Alice'
  );
  v_auth_id := v_swimmer.auth_id;
  IF v_auth_id IS NULL THEN
    RAISE EXCEPTION 'Step 5 FAIL: redeem returned swimmer without auth_id';
  END IF;
  RAISE NOTICE 'Step 5 PASS: redeem created auth.users + linked auth_id=%', v_auth_id;

  -- -------------------------------------------------------------
  -- Step 6: Verify post-redeem state (auth_id + email + code cleared)
  -- -------------------------------------------------------------
  SELECT * INTO v_swimmer FROM swimmers WHERE id = v_swimmer_id;
  IF v_swimmer.auth_id IS NULL THEN
    RAISE EXCEPTION 'Step 6 FAIL: auth_id not persisted';
  END IF;
  IF v_swimmer.email <> v_email THEN
    RAISE EXCEPTION 'Step 6 FAIL: email not persisted (expected %, got %)', v_email, v_swimmer.email;
  END IF;
  IF v_swimmer.invite_code IS NOT NULL THEN
    RAISE EXCEPTION 'Step 6 FAIL: invite_code was NOT cleared';
  END IF;
  RAISE NOTICE 'Step 6 PASS: post-redeem state (auth_id set, email set, code cleared)';

  -- -------------------------------------------------------------
  -- Step 7: One-time use — try to reuse the same code (now cleared)
  -- -------------------------------------------------------------
  BEGIN
    PERFORM redeem_invite_code(
      p_code := v_code,
      p_email := 'secondattempt@example.com',
      p_password := 'secondattempt',
      p_first_name := 'Second'
    );
    RAISE EXCEPTION 'Step 7 FAIL: code was reused — one-time use NOT enforced';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%invalid or expired%' THEN
      RAISE NOTICE 'Step 7 PASS: one-time use enforced (rejected with: %)', SQLERRM;
    ELSE
      RAISE;
    END IF;
  END;

  -- -------------------------------------------------------------
  -- Step 8: RLS visibility — verify the new auth user can see own data
  -- (this would normally be tested from the iOS app; here we
  --  verify the rowcount via the same auth context)
  -- -------------------------------------------------------------
  -- Switch to the new swimmer's auth context
  PERFORM set_config('request.jwt.claim.sub', v_auth_id::text, true);

  -- Count recorded_times the new swimmer can see
  SELECT count(*) INTO v_before_count FROM recorded_times WHERE swimmer_id = v_swimmer_id;
  -- Switch back to service role briefly to compare against actual rows
  PERFORM set_config('role', 'service_role', true);
  SELECT count(*) INTO v_after_count FROM recorded_times WHERE swimmer_id = v_swimmer_id;
  IF v_before_count <> v_after_count THEN
    RAISE EXCEPTION 'Step 8 FAIL: RLS mismatch — swimmer sees % but DB has %',
      v_before_count, v_after_count;
  END IF;
  RAISE NOTICE 'Step 8 PASS: RLS visibility — swimmer sees % recorded_times (matches DB)',
    v_before_count;

  RAISE NOTICE '';
  RAISE NOTICE '=== ALL 8 STEPS PASSED — invite-code flow is end-to-end functional ===';
  RAISE NOTICE '=== Test artifacts left for inspection ===';
  RAISE NOTICE '  auth_id=%, email=%', v_auth_id, v_email;
  RAISE NOTICE '  password=%', v_password;
  RAISE NOTICE '=== Cleanup: run the postgres-role cleanup block below (separately) ===';
END $$;

-- ============================================================
-- iOS UI SMOKE TEST CHECKLIST (run on Mac Studio)
-- ============================================================
-- After this SQL script passes, run the iOS build:
--
--   cd ios-native
--   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
--   xcodebuild -project Hydrolyze.xcodeproj -scheme Hydrolyze \
--              -destination 'platform=iOS Simulator,name=iPhone 16' \
--              -configuration Debug clean build 2>&1 | tail -20
--
-- Then run on the simulator:
--
-- Coach-side (verify):
-- [ ] Sign in as the coach (test@example.com / testpassword)
-- [ ] Open Swimmers tab → tap Mock Alice
-- [ ] Tap the share-style icon in the top-right (next to Edit)
-- [ ] Sheet opens with "Invite Mock Alice" header
-- [ ] Code auto-generates within ~1 second
-- [ ] Code is 6 chars, monospaced, large (the hero element)
-- [ ] Tap "Copy code" → clipboard contains the 6-char code
-- [ ] Tap "Regenerate code" → new code appears (different from first)
-- [ ] Tap "Done" → sheet dismisses
-- [ ] Sign out, switch to Swimmer tab
--
-- Swimmer-side (verify):
-- [ ] In the SwimmerLoginFlow, tap "Create Account" pill
-- [ ] Form gains 3 fields: First name, Last name, Invite code
-- [ ] Enter email: smoketest+UI@example.com (any valid format)
-- [ ] Enter password: smoketest123 (8+ chars)
-- [ ] Enter first name: Alice
-- [ ] Enter invite code: <paste from clipboard>
-- [ ] Tap "Create Account"
-- [ ] If 2s passes without error → success haptic + sheet dismisses
-- [ ] Swimmer lands on SwimmerHomeView (NOT the coach's Today tab)
-- [ ] "My Swims" tab shows the swimmer's recorded times (the
--     data-porting promise — same swimmer_id rows now visible)
-- [ ] "My PBs" tab shows the swimmer's personal bests
-- [ ] "My Coach" tab shows the coach's name
-- [ ] Tap the coach tab → denied (RLS restricts to own data)
--
-- Data-porting verification (the user's explicit question):
-- [ ] Before sign-up: coach's swimmer list shows Mock Alice with
--     432 recorded_times total
-- [ ] After the smoke-test swimmer signs up: the swimmer's
--     "My Swims" shows the SAME number of times as the coach's
--     Mock Alice detail view — no data was moved, the schema
--     made the rows visible via RLS
--
-- If any of these fail, the failing step's name is the diagnostic.
-- The SQL smoke test above is the authoritative check for the
-- server side; the iOS checklist verifies the UI presentation.