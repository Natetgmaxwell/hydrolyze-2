# Hydrolyze Invite-Code Onboarding — Design Spec

**Status:** Draft — pending sign-off
**Date:** 2026-06-23
**Branch:** `v2.0-swimmer-login`

## Problem

Today (post-Phase 2.7) the swimmer login flow has a gap: a swimmer
who wants to see their own data on Hydrolyze must wait for the coach
to manually create an account via the coach-side
`create_swimmer_account(email, password, swimmerId, coachId)` RPC
(Phase 2.3). The user has reframed this: the swimmer should be
able to sign themselves up using an invite code the coach gives
them. Self-signup is the natural onboarding flow.

The data porting question is also live: the user explicitly asked
"what happens to the data already captured for that swimmer?"
The answer is the schema does it — `recorded_times.swimmer_id`
is permanent, and the new RLS policy keys off `auth_id`. No data
movement is needed; visibility turns on when `auth_id` is set.

## Current State

| Component | Status |
|---|---|
| `swimmers.auth_id` + `swimmers.email` columns | ✅ shipped (Phase 2.1) |
| Swimmer-scoped RLS policies (8 tables) | ✅ shipped (Phase 2.1) |
| `AuthManager.role` enum (coach/swimmer) | ✅ shipped (Phase 2.2) |
| `AuthService.signInSwimmer` + `resetSwimmerPassword` | ✅ shipped (Phase 2.3) |
| `AuthService.createSwimmer_account` (coach-side RPC) | ✅ shipped (Phase 2.3) — coach-side flow, **not what the user wants** |
| `SwimmerHomeView` (My Swims / My PBs / My Coach / Profile) | ✅ shipped (Phase 2.5) |
| `ContentView` three-way routing | ✅ shipped (Phase 2.6) |
| **`swimmers.invite_code` column** | ❌ NOT shipped |
| **`generate_invite_code` Postgres function** | ❌ NOT shipped |
| **`redeem_invite_code` Postgres function** | ❌ NOT shipped |
| **Coach-side "Invite to App" sheet** | ❌ NOT shipped |
| **Swimmer-side "Create Account" form in SwimmerLoginFlow** | ❌ NOT shipped |

## Objective

Replace the coach-side account-creation flow with a swimmer-driven
invite-code flow:

1. Coach generates a 6-character invite code for a swimmer (or new swimmer)
2. Coach tells the swimmer the code (text, email, in person)
3. Swimmer opens Hydrolyze, picks the Swimmer tab, taps Create Account
4. Swimmer enters email + password + invite code
5. Code validates → swimmer's `auth.users` row created → `swimmers.auth_id` set
6. Swimmer's existing data becomes visible to them via the existing RLS policies
7. Code is cleared (one-time use)

The existing `create_swimmer_account` (Phase 2.3) becomes a backup
admin path. The default onboarding is now the invite-code flow.

### Success criteria

- Coach can generate an invite code for an existing swimmer in
  less than 3 taps
- Swimmer can sign up + sign in using the code in less than 60 seconds
- Existing data (recorded_times, PBs) becomes visible to the
  swimmer on their first session — no migration script, no
  manual transfer
- A code can only be used once
- Codes expire in 7 days
- The data permanence principle still holds: swimmer changing
  coaches keeps their times

## Visual Design / Data Model

### Schema changes (1 new migration)

```sql
ALTER TABLE swimmers
  ADD COLUMN IF NOT EXISTS invite_code text,
  ADD COLUMN IF NOT EXISTS invite_code_expires_at timestamptz;

-- Partial unique index (so only swimmers with active codes count
-- toward the index; the NULL values don't)
CREATE UNIQUE INDEX IF NOT EXISTS swimmers_invite_code_active
  ON swimmers(invite_code)
  WHERE invite_code IS NOT NULL;

-- Lookup index for the redeem flow (find swimmer by code, check expiry)
CREATE INDEX IF NOT EXISTS swimmers_invite_code_lookup
  ON swimmers(invite_code)
  WHERE invite_code IS NOT NULL;
```

### Postgres functions (2 new)

```sql
-- generate_invite_code: coach calls this. Sets a 6-char code on the
-- swimmer row + the expiry timestamp. Idempotent: calling it
-- multiple times for the same swimmer overwrites the previous code.
CREATE FUNCTION generate_invite_code(
  p_swimmer_id uuid,
  p_expires_in_days int DEFAULT 7
) RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_code text;
  v_swimmer_coach_id uuid;
  v_caller_coach_id uuid;
BEGIN
  -- Verify the caller is the coach who owns the swimmer
  SELECT coach_id INTO v_swimmer_coach_id FROM swimmers WHERE id = p_swimmer_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'swimmer not found'; END IF;
  SELECT id INTO v_caller_coach_id FROM coaches WHERE auth_id = auth.uid();
  IF v_caller_coach_id IS DISTINCT FROM v_swimmer_coach_id THEN
    RAISE EXCEPTION 'caller is not the coach for this swimmer';
  END IF;

  -- Generate a 6-char alphanumeric code (uppercase + digits)
  -- excluding ambiguous chars (0/O/1/I/L)
  v_code := upper(substring(md5(random()::text) from 1 for 6));
  v_code := translate(v_code, '0OIL', 'QDZX');  -- avoid ambiguous

  UPDATE swimmers
  SET invite_code = v_code,
      invite_code_expires_at = now() + (p_expires_in_days || ' days')::interval
  WHERE id = p_swimmer_id;

  RETURN v_code;
END;
$$;

-- redeem_invite_code: swimmer calls this at signup. Validates
-- the code, creates the auth.users row, links it to the swimmer.
CREATE FUNCTION redeem_invite_code(
  p_code text,
  p_email text,
  p_password text,
  p_first_name text,
  p_last_name text DEFAULT NULL
) RETURNS swimmers
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_swimmer swimmers%ROWTYPE;
  v_auth_id uuid;
BEGIN
  -- Find swimmer by code, check expiry
  SELECT * INTO v_swimmer
  FROM swimmers
  WHERE invite_code = upper(p_code)
    AND invite_code_expires_at > now();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'invalid or expired invite code';
  END IF;

  -- Validate inputs
  IF p_email !~ '^[^@]+@[^@]+\.[^@]+$' THEN
    RAISE EXCEPTION 'invalid email format';
  END IF;
  IF length(p_password) < 8 THEN
    RAISE EXCEPTION 'password too short (min 8 chars)';
  END IF;

  -- Create auth.users row (same pattern as create_swimmer_account)
  INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, recovery_sent_at, last_sign_in_at,
    raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, email_change_token_current
  ) VALUES (
    '00000000-0000-0000-0000-000000000000'::uuid,
    gen_random_uuid(),
    'authenticated', 'authenticated',
    p_email,
    crypt(p_password, gen_salt('bf')),
    now(), now(), now(),
    jsonb_build_object('provider', 'email', 'providers', array['email']::text[]),
    jsonb_build_object('name', p_first_name || ' ' || coalesce(p_last_name, '')),
    now(), now(),
    '', '', '', ''
  )
  RETURNING id INTO v_auth_id;

  -- Update swimmer: link auth_id, set email, clear invite_code
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
```

### Coach-side UI: "Invite to App" sheet

A modal sheet pushed from the SwimmerDetailView (or the new
SwimmersListView row context menu). Two-step:

1. **Confirm the action** ("Invite Mock Alice to download Hydrolyze?")
2. **Display the code** ("Her code is **H7K2X9** — expires in 7 days.
   Share it with her however you like.")

The sheet also has a "Copy code" button for one-tap clipboard copy
and a "Resend / regenerate" option that calls
`generate_invite_code` again with the same swimmer.

### Swimmer-side UI: "Create Account" form

Add to `SwimmerLoginFlow` a "Don't have an account? Create one"
link below the password field. Tapping it swaps the form to:

1. **Email** field
2. **Password** field (with min-length hint)
3. **First name** field
4. **Last name** field (optional)
5. **Invite code** field (the hero element — large, monospaced, hints "your coach gave you this code")
6. **Create Account** button

On submit, call `redeemInviteCode(code, email, password, firstName, lastName)`.
On success, the AuthManager's signed-in event fires (via the
existing `handleAuthEvent` flow), the role resolves to `.swimmer`,
and SwimmerHomeView appears.

## Components Affected

- **New:** `supabase/migrations/20260623000002_invite_code_*.sql`
  (the schema + 2 functions)
- **New:** `ios-native/Hydrolyze/Sources/Views/Coach/InviteSwimmerSheet.swift`
  (the coach-side sheet)
- **Edit:** `ios-native/Hydrolyze/Sources/Views/Auth/LoginView.swift`
  (add "Create Account" mode to SwimmerLoginFlow)
- **Edit:** `ios-native/Hydrolyze/Sources/Services/AuthService.swift`
  (add `generateInviteCode` + `redeemInviteCode` methods)
- **Edit:** `ios-native/Hydrolyze/Sources/Views/Swimmers/SwimmerDetailView.swift`
  or new file (wire the "Invite to App" trigger)
- **Test:** `scripts/test-invite-code.sql` (manual verification of
  generate + redeem + RLS + expiry)

## Code Style

- Match existing migration style (BEGIN/COMMIT, comments, idempotent)
- Match existing Swift UI style (color tokens, Animations, Haptics,
  AuthTextField for inputs, HStack/VStack pattern)
- Match existing service style (JSON via Codable, RLS-aware queries)
- Use the existing `supabase.rpc("function_name", params:)` pattern
  for Postgres function calls (already used for `create_swimmer_account`)

## Testing Strategy

1. **Schema verification:** run the pre-migration checklist from
   `supabase-project-ops` skill — verify the existing `swimmers`
   columns + existing RLS policies
2. **Function smoke tests (manual SQL):**
   - `SELECT generate_invite_code('<existing-swimmer-id>');` returns a 6-char code
   - `SELECT * FROM swimmers WHERE id = '<id>';` shows the code + expiry
   - `SELECT redeem_invite_code('<code>', 'test@example.com', 'password123', 'Test', 'User');`
     returns the swimmer row with `auth_id` + `email` set + `invite_code` cleared
   - `SELECT redeem_invite_code('<same-code-again>', ...);` errors
     with "invalid or expired invite code" (one-time use verified)
   - `SELECT redeem_invite_code('FAKECODE', ...);` errors with the same
   - `SELECT redeem_invite_code('<expired-code>', ...);` errors
     (7-day expiry verified)
3. **RLS smoke test:** after a successful redeem, sign in as the
   swimmer and verify they can see their own data (recorded_times,
   PBs) but NOT other swimmers' data (same RLS check as Phase 2.7)
4. **iOS UI smoke test:** the sheet appears, code generates, sheet
   displays the code, copy works; the swimmer form accepts a
   valid code and lands on SwimmerHomeView

## Boundaries

**Always:**
- Generate codes that exclude ambiguous chars (0/O/1/I/L)
- Validate code is unused before redemption
- Validate code is unexpired before redemption
- Clear the code after successful redemption
- Use the existing RLS policies (don't create new ones)
- Use the existing Supabase anon key (no service_role key in iOS)

**Ask first:**
- Should the email field pre-fill from device Contacts? (MVP: no)
- Should the coach be able to revoke an unused code? (MVP: yes via regenerate)
- Should the swimmer be able to redeem a code after coach removes them
  from the squad? (MVP: no — coach_id match is required)

**Never:**
- Store the password in cleartext anywhere
- Create the auth.users row with admin bypass (use SECURITY DEFINER)
- Bypass the RLS policies (the existing `swimmer_own_*` policies
  are the access boundary)
- Reuse a code (one-time use is the security model)
- Make the iOS app set `invite_code` directly (only the Postgres
  function does)

## Implementation Slices

| Slice | What | Why | Effort | Commit |
|---|---|---|---|---|
| **2.8.1** | Migration: schema + 2 functions | Foundation — everything else depends on this | ~250 lines SQL | `feat(v2.0): invite_code schema + 2 RPC functions` |
| **2.8.2** | AuthService methods + iOS bridge | iOS needs to call the functions | ~80 lines Swift | `feat(v2.0): AuthService invite-code methods` |
| **2.8.3** | Coach-side "Invite to App" sheet | Coach UX is the trigger point | ~180 lines Swift | `feat(v2.0): Invite Swimmer sheet` |
| **2.8.4** | Swimmer-side "Create Account" form | Swimmer UX is the destination | ~150 lines Swift | `feat(v2.0): Swimmer Create Account form` |
| **2.8.5** | Test script (SQL + manual checklist) | Verification — tests the slice boundaries | ~50 lines SQL | `test(v2.0): invite-code smoke tests` |

## Success Criteria

- A coach can generate an invite code for an existing swimmer in 3 taps
- A swimmer can sign up + sign in using the code in 60 seconds
- Existing recorded_times + PBs are visible to the swimmer on their
  first session (no migration script, just RLS visibility)
- A code can only be used once (one-time use enforced at the DB)
- A code expires in 7 days (enforced at the DB)
- The 5 new files + 1 migration compile clean (`swiftc -parse` exits 0)
- The migration applies cleanly (run + verify RLS didn't break)
- Manual smoke test passes

## Open Questions (need user input)

1. **Code format:** 6 chars alphanumeric (`H7K2X9`, excluding
   ambiguous 0/O/1/I/L), or 6 digits (`123456`), or a longer
   memorable code (`shark-dance-77`)?

   **LLM recommendation:** 6 chars alphanumeric (uppercase + digits,
   ambiguous chars excluded). Short enough to read out loud, hard to
   guess (24^6 ≈ 191M combinations × expiring in 7 days), no
   "swipe your keyboard" UX for the coach. The memorable-code
   alternative is great UX but harder to type, and the password
   reset flow covers the rare "I lost my code" case anyway.

2. **Code expiry:** 7 days, 30 days, or never (one-time use only,
   no time expiry)?

   **LLM recommendation:** 7 days. Long enough for the coach to
   hand it over in person / via text / via email, short enough
   that stale codes don't pile up in the DB. The coach can
   regenerate at any time (resets the expiry clock). The
   "never expire" alternative is tempting but creates a permanent
   security surface — old codes that leaked can never be revoked
   without changing the swimmer's row.

3. **First/last name collection:** at the swimmer-side signup
   form, do we collect the swimmer's first and last name (so the
   auth.users.raw_user_meta_data has a display name)?

   **LLM recommendation:** yes, collect first name only (optional
   last name). It's a one-field signup form for the MVP; we already
   have the swimmer's name on the `swimmers` row from the coach's
   creation. The swimmer-side form can pre-fill from the coach's
   data and let the swimmer confirm/override.

4. **Coach-side trigger location:** the "Invite to App" sheet can
   be triggered from:
   - SwimmersListView row context menu (right-click / long-press)
   - SwimmerDetailView header toolbar (top-right)
   - SwimmersListView bottom toolbar ("+ Invite")
   - Both SwimmersListView row action AND SwimmerDetailView header

   **LLM recommendation:** SwimmerDetailView header toolbar. The
   row context menu is hard to discover; the bottom toolbar adds
   noise; the SwimmerDetailView header is where the coach is
   already looking at the swimmer's data. Add as a "Share" icon
   button next to the existing Edit/Archive.

5. **Backwards compatibility:** should the existing
   `create_swimmer_account` (Phase 2.3) RPC stay available as
   a backup / admin path, or get removed?

   **LLM recommendation:** keep it. It's a coach-side path that
   creates the account without a code (useful for admins setting
   up swimmers on their behalf, or for migrations from other
   systems). Demoted to "admin only" — the iOS UI doesn't call
   it anymore, only the new `generate_invite_code` /
   `redeem_invite_code` flow.

## Decisions (post-sign-off)

The user's answers go here once they sign off.

## See also

- `originals/hydrolyze-squad-level-progression-design-v1` — the
  larger design context (the data permanence principle is documented
  here)
- `supabase/migrations/20260623000000_swimmer_login_schema.sql` —
  the existing Phase 2.1 schema
- `supabase/migrations/20260623000001_create_swimmer_account_function.sql` —
  the existing coach-side RPC (to be demoted)
- `ios-native/Hydrolyze/Sources/Services/AuthService.swift` —
  the existing service the new methods plug into
- `ios-native/Hydrolyze/Sources/Views/Auth/LoginView.swift` —
  the existing SwimmerLoginFlow the Create Account form extends
- `references/supabase-ios-rls-silent-fail-patterns.md` — the
  pre-migration verification checklist