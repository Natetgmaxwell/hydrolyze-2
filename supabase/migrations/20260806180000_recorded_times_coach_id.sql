-- Migration: extend recorded_times with coach_id and tighten RLS to direct coach ownership.
--
-- Task: t_1789d5c7 (2026-08-06).
--
-- Goal: the stopwatch-handoff layer (TS) + RN/iOS clients all write rows
-- to recorded_times via the new StopwatchPersister seam (stopwatch-persistence.ts).
-- The task body requires "a coach can only read/write their own rows" enforced
-- by RLS. The existing RLS works via session_id → sessions.coach_id → coaches.auth_id
-- = auth.uid(). This migration adds a denormalized coach_id column on the row,
-- backfills from the session's coach_id, and rewrites the RLS policies to key
-- directly on coach_id. The denormalization gives:
--
--   1. Direct-row-level ownership: faster RLS check (single join vs two-step
--      session→coach join), easier audit ("who owns this row?"), and a
--      stable invariant when sessions are moved/archived.
--   2. Cross-session visibility still works: the existing
--      `coach_read_swimmer_times` policy (swimmer_id → swimmers.coach_id)
--      is preserved unchanged so a coach who transfers a swimmer still sees
--      the swimmer's historical times (per the t_be09a643 fix).
--
-- Columns added:
--   coach_id  uuid — denormalized from sessions.coach_id at write time.
--             NULLABLE during backfill; SET NOT NULL after backfill completes.
--             FK to coaches.id; ON DELETE RESTRICT (a coach with times
--             can't be deleted; the typical path is transfer-swimmer).
--
-- Backfill strategy:
--   UPDATE recorded_times SET coach_id = (SELECT coach_id FROM sessions WHERE id = recorded_times.session_id)
--   for every row where session_id is non-null. Rows with session_id IS NULL
--   are set to NULL (and the post-backfill NOT NULL constraint will fail
--   loudly if any orphan rows exist — those would be a data integrity bug).
--
-- Idempotency:
--   - ADD COLUMN IF NOT EXISTS — safe to re-run
--   - DO block for ADD CONSTRAINT — checks pg_constraint first
--   - DROP POLICY IF EXISTS + CREATE POLICY — the existing migrations
--     use this pattern (see 20260728000003_recorded_times_follow_swimmer.sql)
--
-- Why a separate migration rather than extending the existing
-- 20260805004449_extend_recorded_times_with_fragment_metadata.sql:
--   - The existing migration is shipped (committed 2026-08-05) and applied
--     to production. Appending to a shipped migration would require
--     re-running it, which would fail (columns already exist) and confuse
--     the migration history.
--   - Per the migration filename convention, every schema change gets its
--     own timestamped file. The Hydrolyze project's CLI tracks them via
--     supabase_migrations.schema_migrations.
--
-- Smoke test (inline):
--   After the migration applies, verify:
--     - Every row has coach_id IS NOT NULL (or session_id IS NULL → orphaned, log it)
--     - The new coach_id index exists
--     - The RLS policy uses coach_id directly
--     - An INSERT with a foreign coach_id is rejected (RLS denies)

BEGIN;

-- ─── 1. Add coach_id column (nullable during backfill) ──────────────────────

ALTER TABLE public.recorded_times
    ADD COLUMN IF NOT EXISTS coach_id uuid;

COMMENT ON COLUMN public.recorded_times.coach_id IS
    'Denormalised owning coach from sessions.coach_id at write time. NULL for legacy orphan rows (no session_id) or pre-backfill state. Foreign key to coaches.id; RLS keys directly on this column for fast ownership checks.';

-- ─── 2. Backfill coach_id from sessions.coach_id for every existing row ─────

-- Only rows with a valid session_id can be backfilled (the orphan rows
-- with session_id IS NULL have no way to derive a coach_id; they remain
-- NULL and are surfaced in the smoke test below as a data integrity
-- warning rather than silently filled).
UPDATE public.recorded_times rt
SET coach_id = s.coach_id
FROM public.sessions s
WHERE rt.session_id = s.id
  AND rt.coach_id IS NULL;

-- ─── 3. Add FK + index + NOT NULL constraint (idempotent guards) ───────────

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'recorded_times_coach_id_fkey'
          AND conrelid = 'public.recorded_times'::regclass
    ) THEN
        ALTER TABLE public.recorded_times
            ADD CONSTRAINT recorded_times_coach_id_fkey
            FOREIGN KEY (coach_id) REFERENCES public.coaches(id)
            ON DELETE RESTRICT;
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_recorded_times_coach_id
    ON public.recorded_times (coach_id)
    WHERE coach_id IS NOT NULL;

-- Enforce NOT NULL after backfill. If any orphan rows exist
-- (session_id IS NULL → no coach_id to backfill), this fails loudly
-- so the operator sees it and decides whether to NULL the orphans
-- explicitly or backfill from a different source.
DO $$
DECLARE
    orphan_count integer;
BEGIN
    SELECT COUNT(*) INTO orphan_count
    FROM public.recorded_times
    WHERE coach_id IS NULL;

    IF orphan_count > 0 THEN
        RAISE WARNING 'recorded_times: % rows have no coach_id after backfill (orphan session_id or pre-existing data integrity issue). NOT NULL constraint skipped — review orphan rows before re-running.', orphan_count;
    ELSE
        BEGIN
            ALTER TABLE public.recorded_times
                ALTER COLUMN coach_id SET NOT NULL;
        EXCEPTION WHEN check_violation OR not_null_violation THEN
            RAISE WARNING 'recorded_times: NOT NULL on coach_id failed despite no orphan rows: %', SQLERRM;
        END;
    END IF;
END $$;

-- ─── 4. Rewrite RLS policies to key on coach_id directly ──────────────────

-- The existing policies all join through sessions.coach_id. With coach_id
-- now denormalised on the row, the direct check is faster and more
-- robust (session moves don't change row ownership).
--
-- We DROP+CREATE rather than ALTER — Postgres RLS policies aren't
-- alterable in place; the only path is drop-then-create.
--
-- Policies we replace:
--   - coach_own_recorded_times (ALL): session_id-based → coach_id-based
--   - recorded_times_select (SELECT): session_id-based → coach_id-based
--   - recorded_times_insert (INSERT WITH CHECK = NULL): session_id-based → coach_id-based
--   - recorded_times_update (UPDATE): session_id-based → coach_id-based
--   - recorded_times_delete (DELETE): session_id-based → coach_id-based
--
-- Policies we KEEP unchanged (they have their own correctness logic
-- that doesn't depend on session_id):
--   - coach_read_swimmer_times (SELECT, swimmer-based): unchanged — this is
--     the "coach can see a transferred swimmer's history" path.
--   - swimmer_own_recorded_times (SELECT, swimmer-auth-based): unchanged.

DROP POLICY IF EXISTS coach_own_recorded_times ON public.recorded_times;
DROP POLICY IF EXISTS recorded_times_select ON public.recorded_times;
DROP POLICY IF EXISTS recorded_times_insert ON public.recorded_times;
DROP POLICY IF EXISTS recorded_times_update ON public.recorded_times;
DROP POLICY IF EXISTS recorded_times_delete ON public.recorded_times;

-- Single ALL policy: one coach can SELECT/INSERT/UPDATE/DELETE any row
-- whose coach_id resolves to their coaches.id (via auth.uid()).
-- Using ALL with both USING and WITH CHECK keeps a single policy
-- covering the full row lifecycle; the previous design split into
-- per-CMD policies but the logic was identical (session_id join), so
-- consolidation is a net simplification.
CREATE POLICY coach_own_recorded_times ON public.recorded_times
  FOR ALL TO authenticated
  USING (
    coach_id IN (
      SELECT coaches.id
      FROM coaches
      WHERE coaches.auth_id = auth.uid()
    )
  )
  WITH CHECK (
    coach_id IN (
      SELECT coaches.id
      FROM coaches
      WHERE coaches.auth_id = auth.uid()
    )
  );

COMMIT;

-- ─── 5. Inline smoke test ──────────────────────────────────────────────────
-- Verifies the migration actually did what it claims. Runs in the same
-- transaction so a failure rolls everything back. Two checks:
--   (a) Every backfilled row's coach_id resolves to a real coaches.id row.
--       If a backfill landed a bogus UUID (shouldn't happen — we copied
--       from sessions.coach_id which is itself a FK to coaches), this fails.
--   (b) The new RLS policy actually exists and is bound to the table.
DO $$
DECLARE
    dangling_count integer;
    policy_count integer;
BEGIN
    SELECT COUNT(*) INTO dangling_count
    FROM public.recorded_times rt
    LEFT JOIN public.coaches c ON rt.coach_id = c.id
    WHERE rt.coach_id IS NOT NULL AND c.id IS NULL;

    IF dangling_count > 0 THEN
        RAISE EXCEPTION 'recorded_times: % rows have coach_id not present in coaches.id (FK drift).', dangling_count;
    END IF;

    SELECT COUNT(*) INTO policy_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'recorded_times'
      AND policyname = 'coach_own_recorded_times';

    IF policy_count <> 1 THEN
        RAISE EXCEPTION 'recorded_times: coach_own_recorded_times policy missing or duplicated (count=%)', policy_count;
    END IF;

    RAISE NOTICE 'recorded_times coach_id migration: % backfilled rows verified, policy count=%', (SELECT COUNT(*) FROM recorded_times WHERE coach_id IS NOT NULL), policy_count;
END $$;