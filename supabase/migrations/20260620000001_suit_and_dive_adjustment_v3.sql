-- Migration: Suit and Dive Adjustment (v3 — matches live schema)
-- Date: 2026-06-20
-- Author: Hermes Agent (TARS)
-- Filename: 20260620000001_suit_and_dive_adjustment_v3.sql
--
-- v1 → v2 → v3 schema evolution:
--   v1: original proposal (suit_type enum, start_type enum, Welford
--       accumulators with m2 column, RLS via `coach_id = auth.uid()::text`).
--   v2: user simplified to binary suit, 3-value start, set-level only.
--       RLS still inherited the broken text-cast pattern.
--   v3: discovered live schema drift. Live DB has:
--         - `coaches` table with `auth_id uuid` (links to auth.users)
--         - `swimmers.coach_id` is uuid (FK to coaches.id, NOT text)
--         - live RLS joins through `coaches.auth_id = auth.uid()`
--         - live `swimmer_gears` is per-(swimmer, gear, distance, stroke)
--           with separate `id` PK, NOT a Welford (no m2 column)
--       The migration file 20260423000000_rls_policies.sql that I read
--       is STALE — the live DB was migrated past it. My v1/v2 RLS
--       (`coach_id = auth.uid()::text`) was the obsolete pattern and
--       failed with "operator does not exist: uuid = text" at policy
--       parse time, which is why the entire BEGIN/COMMIT transaction
--       rolled back (no v2 changes persisted).
--
-- v3 fix:
--   - RLS uses the live pattern: join through `coaches.auth_id = auth.uid()`
--   - `swimmer_suits` and `swimmer_starts` match the live `swimmer_gears`
--     shape: per-(swimmer, X, distance, stroke) stat with separate `id` PK
--   - DROP IF EXISTS guards at the top: in case the v2 migration partially
--     applied (it didn't, but defensive for future re-runs)
--   - Idempotent end-to-end: safe to re-run

BEGIN;

-- ══════════════════════════════════════════════════════════════════════════════
-- Defensive cleanup (in case a partial v2 state exists from a failed run)
-- Drop tables first (CASCADE removes any RLS policies on them); this
-- avoids the "DROP POLICY on non-existent table" error.
-- ══════════════════════════════════════════════════════════════════════════════

-- The v2 tables have the wrong shape (Welford, no distance/stroke). Drop and
-- recreate with the live schema. These are NEW tables with 0 rows (the
-- calibration loop hasn't shipped yet), so the drop is safe.
DROP TABLE IF EXISTS swimmer_suits CASCADE;
DROP TABLE IF EXISTS swimmer_starts CASCADE;

-- ══════════════════════════════════════════════════════════════════════════════
-- WORKOUT_SETS — add the calibration fields (idempotent)
-- ══════════════════════════════════════════════════════════════════════════════

ALTER TABLE workout_sets
  ADD COLUMN IF NOT EXISTS suit boolean NOT NULL DEFAULT false;

ALTER TABLE workout_sets
  ADD COLUMN IF NOT EXISTS start_type text NOT NULL DEFAULT 'in_water'
    CHECK (start_type IN ('in_water', 'dive', 'backstroke_start'));

COMMENT ON COLUMN workout_sets.suit IS
  'Whether the swimmer wore a suit for this set. Default false (no suit). '
  'Per-(swimmer, suit, distance, stroke) stat is maintained in swimmer_suits.';

COMMENT ON COLUMN workout_sets.start_type IS
  'Start type for this set. Default ''in_water'' (covers push start). '
  'Per-(swimmer, start_type, distance, stroke) stat is maintained in '
  'swimmer_starts. The in_water row is the reference; dive and '
  'backstroke_start are the deltas relative to it.';

-- ══════════════════════════════════════════════════════════════════════════════
-- SWIMMER_SUITS — per-(swimmer, suit, distance, stroke) stat
-- Shape matches the live `swimmer_gears` table (verified from
-- information_schema.columns + pg_constraint on 2026-06-20)
-- ══════════════════════════════════════════════════════════════════════════════

CREATE TABLE swimmer_suits (
  id              uuid NOT NULL DEFAULT gen_random_uuid(),
  swimmer_id      uuid NOT NULL REFERENCES swimmers(id) ON DELETE CASCADE,
  suit            boolean NOT NULL,                  -- false = no suit, true = suit
  distance        integer NOT NULL,
  stroke          text NOT NULL,
  mean_time_ms    double precision,
  stddev_time_ms  double precision,
  sample_count    integer NOT NULL DEFAULT 0,
  updated_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (swimmer_id, suit, distance, stroke)
);

COMMENT ON TABLE swimmer_suits IS
  'Per-(swimmer, suit, distance, stroke) time statistics. The engine '
  'computes the pair-wise ratio (suit=true / suit=false) for the same '
  '(swimmer, distance, stroke) as the suit calibration delta. Requires '
  '>= 2 observations (one with suit=true, one with suit=false) at the same '
  '(swimmer, distance, stroke) to be applicable. 0 rows = no calibration.';

CREATE INDEX idx_swimmer_suits_lookup
  ON swimmer_suits(swimmer_id, distance, stroke);

-- ══════════════════════════════════════════════════════════════════════════════
-- SWIMMER_STARTS — per-(swimmer, start_type, distance, stroke) stat
-- Shape matches swimmer_gears
-- ══════════════════════════════════════════════════════════════════════════════

CREATE TABLE swimmer_starts (
  id              uuid NOT NULL DEFAULT gen_random_uuid(),
  swimmer_id      uuid NOT NULL REFERENCES swimmers(id) ON DELETE CASCADE,
  start_type      text NOT NULL,                     -- in_water | dive | backstroke_start
  distance        integer NOT NULL,
  stroke          text NOT NULL,
  mean_time_ms    double precision,
  stddev_time_ms  double precision,
  sample_count    integer NOT NULL DEFAULT 0,
  updated_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (swimmer_id, start_type, distance, stroke)
);

COMMENT ON TABLE swimmer_starts IS
  'Per-(swimmer, start_type, distance, stroke) time statistics. The engine '
  'computes pair-wise ratios against the in_water reference: '
  '(dive / in_water) = the dive delta; (backstroke_start / in_water) = the '
  'backstroke_start delta. Requires >= 2 observations (one per start_type) at '
  'the same (swimmer, distance, stroke) to be applicable. 0 rows = no '
  'calibration; the prediction uses the raw PB.';

CREATE INDEX idx_swimmer_starts_lookup
  ON swimmer_starts(swimmer_id, distance, stroke);

-- ══════════════════════════════════════════════════════════════════════════════
-- RLS — match the live pattern (verified from pg_policies on 2026-06-20)
-- Pattern: join through `coaches.auth_id = auth.uid()`
-- ══════════════════════════════════════════════════════════════════════════════

ALTER TABLE swimmer_suits  ENABLE ROW LEVEL SECURITY;
ALTER TABLE swimmer_starts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "coach_own_swimmer_suits" ON swimmer_suits
  FOR ALL USING (
    swimmer_id IN (
      SELECT id FROM swimmers
      WHERE coach_id IN (
        SELECT id FROM coaches
        WHERE auth_id = auth.uid()
      )
    )
  );

CREATE POLICY "coach_own_swimmer_starts" ON swimmer_starts
  FOR ALL USING (
    swimmer_id IN (
      SELECT id FROM swimmers
      WHERE coach_id IN (
        SELECT id FROM coaches
        WHERE auth_id = auth.uid()
      )
    )
  );

COMMIT;
