-- Migration: Add hidden m2 column to calibration tables (T1.5)
-- Date: 2026-06-20
-- Author: Hermes Agent (TARS)
-- Filename: 20260620000002_add_m2_column_to_calibration_tables.sql
--
-- Adds the Welford M2 accumulator to swimmer_suits and swimmer_starts.
-- The m2 is the source of truth for variance; stddev_time_ms becomes
-- a cached value derived from m2 on each update.
--
-- Why this is needed (the precision argument):
-- The Welford online update formula is the canonical way to maintain
-- running mean and variance in O(1) per observation:
--   count_new = count_old + 1
--   delta    = x_new - mean_old
--   mean_new = mean_old + delta / count_new
--   M2_new   = M2_old + delta * (x_new - mean_new)
--   variance = M2 / (count - 1)
--
-- Without M2 stored, the engine cannot do incremental updates. It
-- would have to either (a) recompute mean and variance from the full
-- history of recorded_times for that (swimmer, X, distance, stroke)
-- bucket on every save — O(n) per write, with precision drift as
-- the sum gets large — or (b) use a different update formula that
-- loses precision. The standard Welford is the answer; M2 is the
-- state we need to keep.
--
-- The column is hidden (engine-only). The coach never sees m2 in the
-- UI. The engine reads/writes m2 on every recorded_times insert for
-- the matching (swimmer, X, distance, stroke) bucket. stddev_time_ms
-- stays in the table as a cached value (derived from m2 on each
-- update) for backwards compat with the live swimmer_gears shape.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS. Safe to re-run.

BEGIN;

-- ══════════════════════════════════════════════════════════════════════════════
-- swimmer_suits — add m2
-- ══════════════════════════════════════════════════════════════════════════════

ALTER TABLE swimmer_suits
  ADD COLUMN IF NOT EXISTS m2 double precision NOT NULL DEFAULT 0;

COMMENT ON COLUMN swimmer_suits.m2 IS
  'Welford accumulator: sum of squared deviations from the mean for '
  'this (swimmer, suit, distance, stroke) bucket. Engine reads/writes '
  'this on every recorded_times insert. Hidden from coach UI. '
  'stddev_time_ms is derived: sqrt(m2 / (sample_count - 1)) for n > 1. '
  'Without m2, the engine cannot do O(1) online Welford updates; '
  'recomputing from full history on each save is O(n) and loses '
  'precision versus the canonical incremental formula.';

-- ══════════════════════════════════════════════════════════════════════════════
-- swimmer_starts — add m2
-- ══════════════════════════════════════════════════════════════════════════════

ALTER TABLE swimmer_starts
  ADD COLUMN IF NOT EXISTS m2 double precision NOT NULL DEFAULT 0;

COMMENT ON COLUMN swimmer_starts.m2 IS
  'Welford accumulator: sum of squared deviations from the mean for '
  'this (swimmer, start_type, distance, stroke) bucket. Engine '
  'reads/writes this on every recorded_times insert. Hidden from coach '
  'UI. stddev_time_ms is derived: sqrt(m2 / (sample_count - 1)) for '
  'n > 1. See swimmer_suits.m2 for the rationale.';

COMMIT;
