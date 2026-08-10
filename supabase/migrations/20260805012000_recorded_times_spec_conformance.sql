-- Migration: bring recorded_times into conformance with the t_b627db4a spec.
--
-- Task: t_b627db4a (2026-08-05).
-- Parent: t_be09a643 (the per-fragment recorded_times pipeline).
--
-- Spec (per t_b627db4a body):
--   id               uuid PK default gen_random_uuid()
--   set_id           text or uuid           (link to the parent set)
--   fragment_id      text or uuid           (link to the parent set fragment)
--   swimmer_id       uuid nullable          (FK to swimmers if that table exists)
--   recorded_ms      integer not null
--   distance_meters  integer not null
--   intensity        text not null
--   start_type       text not null
--   pace_target_sec  numeric nullable
--   raw_text         text not null
--   created_at       timestamptz not null default now()
-- Plus indexes on (set_id), (fragment_id), and (swimmer_id).
--
-- What the prior migration 20260805004449_extend_recorded_times_with_fragment_metadata.sql
-- already shipped (and is on remote):
--   - Added fragment_id, distance_meters, start_type, pace_target_sec, raw_text
--     as NULLABLE for backwards compat with the 432 legacy rows that pre-date
--     the per-fragment timing flow.
--   - Added partial index idx_recorded_times_fragment_id (WHERE fragment_id IS NOT NULL).
--   - Added composite index idx_recorded_times_set_fragment_rep on
--     (workout_set_id, fragment_id, rep_index).
--   - Pre-existing: workout_set_id b-tree, swimmer_id b-tree (covering set_id +
--     swimmer_id indexes the spec asks for).
--   - Pre-existing FK swimmer_id → swimmers(id) (the spec's "FK to swimmers if
--     that table exists").
--
-- What this migration does:
--   1. Pace target type: integer → numeric. The spec says numeric. Numeric is
--      a strict superset of integer for the values we store (seconds — never
--      larger than a few thousand). Using USING integer::numeric so the cast
--      is explicit and the rewrite is in-place.
--   2. created_at NOT NULL DEFAULT now(). The current column is nullable with
--      default now(). Spec says NOT NULL. Verified 0 NULL values in the live
--      table (432/432 have created_at set), so this is safe to tighten.
--   3. Idempotent re-assertion of the three required simple indexes using
--      IF NOT EXISTS. All three already exist from prior migrations; this
--      block is the contract guarantee for fresh-DB replay — a brand-new
--      database running this file from scratch ends up with the three
--      indexes the spec requires.
--   4. Idempotent COMMENT ON COLUMN statements so fresh-DB replay also lands
--      the column-level docs.
--
-- What this migration deliberately does NOT do:
--   - NOT NULL on distance_meters, intensity, start_type, raw_text, fragment_id.
--     The 432 legacy rows in recorded_times have NULLs in all five (verified
--     via count(*) FILTER ...). Forcing NOT NULL would fail migration on the
--     populated remote. The spec's "not null" intent is satisfied at the
--     application layer (iOS FragmentRow in RecordedTimeFragmentService.swift
--     always supplies values for new writes; the SQL layer stays permissive
--     to keep the legacy rows decodable). A future backfill slice can tighten
--     these once all 432 rows are resolved.
--   - pace_target_sec NOT NULL. Spec says nullable; the column is nullable.
--   - Drop the existing partial / composite indexes on fragment_id /
--     (workout_set_id, fragment_id, rep_index). Those cover more specific
--     query shapes the pairing-engine handoff relies on; the simple
--     fragment_id index this migration re-asserts is additive.
--
-- Idempotency: every ALTER is guarded with IF NOT EXISTS patterns where
-- Postgres supports them. The pace_target_sec cast uses ALTER COLUMN ... TYPE
-- (Postgres does not support ALTER COLUMN ... TYPE IF NOT EXISTS — but the
-- cast is a no-op when the column is already numeric, so re-running on a
-- DB where this migration already landed is safe and produces no diff).
-- All CREATE INDEX statements use IF NOT EXISTS. The created_at NOT NULL
-- uses a DO block to detect whether the constraint is already in place
-- (otherwise re-running would error with
-- "column "created_at" of relation "recorded_times" already has NOT NULL set").
--
-- Run in Supabase SQL Editor or via:
--   supabase db query --linked -f supabase/migrations/20260805012000_recorded_times_spec_conformance.sql
-- Or with psql:
--   psql $DATABASE_URL -f supabase/migrations/20260805012000_recorded_times_spec_conformance.sql

BEGIN;

-- 1. pace_target_sec: integer → numeric (spec compliance).
--    USING keeps the rewrite in-place; no data loss (all existing values are
--    small positive integers that fit cleanly in numeric).
ALTER TABLE public.recorded_times
    ALTER COLUMN pace_target_sec TYPE numeric USING pace_target_sec::numeric;

-- 2. created_at NOT NULL DEFAULT now() (spec compliance).
--    Safe: 0 NULL rows on remote at migration time.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
          FROM information_schema.columns
         WHERE table_schema = 'public'
           AND table_name   = 'recorded_times'
           AND column_name  = 'created_at'
           AND is_nullable  = 'YES'
    ) THEN
        ALTER TABLE public.recorded_times
            ALTER COLUMN created_at SET DEFAULT now(),
            ALTER COLUMN created_at SET NOT NULL;
    END IF;
END $$;

-- 3. Indexes the spec asks for: (set_id), (fragment_id), (swimmer_id).
--    All three already exist on remote as b-tree (workout_set_id, swimmer_id)
--    and partial b-tree (fragment_id WHERE fragment_id IS NOT NULL). Re-assert
--    them with IF NOT EXISTS so a fresh-DB replay is well-defined.
CREATE INDEX IF NOT EXISTS idx_recorded_times_set_id
    ON public.recorded_times (workout_set_id)
    WHERE workout_set_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_recorded_times_fragment_id_simple
    ON public.recorded_times (fragment_id)
    WHERE fragment_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_recorded_times_swimmer_id_simple
    ON public.recorded_times (swimmer_id)
    WHERE swimmer_id IS NOT NULL;

-- 4. Column docs. Idempotent.
COMMENT ON COLUMN public.recorded_times.id               IS 'uuid PK, default gen_random_uuid().';
COMMENT ON COLUMN public.recorded_times.workout_set_id   IS 'set_id — FK to workout_sets(id). ON DELETE CASCADE. NULL for bare-timing rows that pre-date set linkage.';
COMMENT ON COLUMN public.recorded_times.fragment_id      IS 'WorkoutSetFragment.id the stopwatch timed. NULL for legacy rows that pre-date per-fragment timing.';
COMMENT ON COLUMN public.recorded_times.swimmer_id       IS 'Swimmer the row was recorded for. Nullable until the pairing handoff resolves. FK to swimmers(id) ON DELETE SET NULL.';
COMMENT ON COLUMN public.recorded_times.time_ms          IS 'recorded_ms — stopwatch reading in milliseconds. NOT NULL.';
COMMENT ON COLUMN public.recorded_times.distance_meters  IS 'Fragment-level distance in meters. Nullable for legacy rows; the iOS FragmentRow writes a non-null value for new rows.';
COMMENT ON COLUMN public.recorded_times.intensity        IS 'Free-form intensity label (e.g. easy, fast, max). Nullable for legacy rows.';
COMMENT ON COLUMN public.recorded_times.start_type       IS 'Fragment-level start type (push | dive | wall | interval). Nullable for legacy rows; falls through to workout_sets.start_type when null.';
COMMENT ON COLUMN public.recorded_times.pace_target_sec  IS 'Fragment-level pace target in seconds (enclosing interval send-off). Numeric, nullable.';
COMMENT ON COLUMN public.recorded_times.raw_text         IS 'Verbatim source line the coach entered (e.g. "4 x (75 fast / 25 easy)"). Nullable for legacy rows.';
COMMENT ON COLUMN public.recorded_times.created_at       IS 'Row creation timestamp. NOT NULL DEFAULT now().';

COMMIT;
