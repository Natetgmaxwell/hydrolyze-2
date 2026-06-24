-- Migration: Fix pre-existing swimmer_pbs UNIQUE constraint bug
-- Date: 2026-06-20
-- Author: Hermes Agent (TARS)
-- Filename: 20260620000004_fix_swimmer_pbs_unique_constraint.sql
--
-- Discovered during T6 verification (2026-06-20): the pre-existing
-- `update_swimmer_pbs` trigger uses
--   ON CONFLICT (swimmer_id, stroke, distance, gear) DO UPDATE
-- but the `swimmer_pbs` table has NO UNIQUE constraint on those 4
-- columns. Every `recorded_times` insert in production has been
-- failing with `ERROR: 42P10: there is no unique or exclusion
-- constraint matching the ON CONFLICT specification`. This blocked
-- the recorded_time save, the PB update, AND the T6 + T7 Welford
-- trigger (which never got to run).
--
-- This migration:
--   1. Deduplicates existing `swimmer_pbs` rows so the UNIQUE
--      constraint can be added. Keeps the FASTEST time per
--      (swimmer_id, stroke, distance, gear) — matches the
--      trigger's intent ("fastest time is the PB").
--   2. Adds the UNIQUE constraint that the trigger expects.
--
-- Both steps are idempotent (safe to re-run). The dedup is a no-op
-- after the first run; the constraint addition checks for
-- existence first.
--
-- SCOPE NOTE (2026-06-20): the dedup is destructive (deletes rows).
-- Before running in production, the user should snapshot
-- `swimmer_pbs` for rollback. The user was notified of the
-- pre-existing bug in the T6 handoff; this migration is the fix.

BEGIN;

-- ══════════════════════════════════════════════════════════════════════════════
-- Step 1: Dedupe existing rows. Keep the fastest time per key.
-- ══════════════════════════════════════════════════════════════════════════════

-- Snapshot the count before the dedup for the migration log.
DO $$
DECLARE
  v_before_count int;
  v_after_count int;
  v_deleted int;
BEGIN
  SELECT count(*) INTO v_before_count FROM swimmer_pbs;
  RAISE NOTICE 'swimmer_pbs: % rows before dedup', v_before_count;

  -- Delete rows that are not the fastest in their (swimmer, stroke,
  -- distance, gear) group. DISTINCT ON + ORDER BY keeps the row
  -- with the minimum time_ms per group.
  WITH keepers AS (
    SELECT DISTINCT ON (swimmer_id, stroke, distance, gear) id
    FROM swimmer_pbs
    ORDER BY swimmer_id, stroke, distance, gear, time_ms ASC, recorded_at DESC
  )
  DELETE FROM swimmer_pbs sp
   WHERE sp.id NOT IN (SELECT id FROM keepers);

  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  SELECT count(*) INTO v_after_count FROM swimmer_pbs;
  RAISE NOTICE 'swimmer_pbs: deleted % duplicate rows, % rows remain', v_deleted, v_after_count;
END $$;

-- ══════════════════════════════════════════════════════════════════════════════
-- Step 2: Add the UNIQUE constraint (idempotent via existence check)
-- ══════════════════════════════════════════════════════════════════════════════

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'swimmer_pbs_swimmer_stroke_distance_gear_key'
  ) THEN
    ALTER TABLE swimmer_pbs
      ADD CONSTRAINT swimmer_pbs_swimmer_stroke_distance_gear_key
      UNIQUE (swimmer_id, stroke, distance, gear);
    RAISE NOTICE 'Added UNIQUE constraint swimmer_pbs_swimmer_stroke_distance_gear_key';
  ELSE
    RAISE NOTICE 'UNIQUE constraint swimmer_pbs_swimmer_stroke_distance_gear_key already exists; no-op';
  END IF;
END $$;

-- Verify the constraint is in place
SELECT conname, contype, pg_get_constraintdef(oid) AS definition
FROM pg_constraint
WHERE conname = 'swimmer_pbs_swimmer_stroke_distance_gear_key';

COMMIT;
