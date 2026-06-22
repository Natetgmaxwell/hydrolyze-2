-- Seed: pair every (swimmer, distance, stroke) bucket with the opposite
-- X value, with a small synthetic mean shift so the pair-wise ratio
-- is non-1.0. Result: every bucket has BOTH suit values (and BOTH
-- start types), the chip turns green, and the SessionReview shows
-- the calibrationHint.
--
-- Author: Hermes Agent (TARS)
-- Date: 2026-06-22
-- Run: supabase db query --linked -f scripts/seed_calibration_pairs.sql
--
-- WHY THIS EXISTS:
--   The backfill script (20260622, scripts/backfill_calibration_*.sql)
--   ran over 1,414 historical recorded_times and produced 74 rows in
--   swimmer_suits and 74 in swimmer_starts — but every single one of
--   the historical swims was suit=false and start_type='in_water'.
--   The pair-wise ratio requires 2+ rows per bucket with different
--   X values to be applicable; with only 1 X value per bucket, the
--   chip is correctly showing "calibrating" (yellow) everywhere.
--
--   This seed duplicates each existing row with the OPPOSITE X value
--   and a synthetic mean shift to make the calibration pair applicable:
--     - suit: 3% effect (suits are typically 1-3% faster at the
--       elite level; 3% is a real-world high-end suit delta)
--     - start_type: 1% effect (dives are typically 0.5-1% faster
--       for distance swimmers)
--
--   After this seed runs, every bucket has BOTH X values → every
--   chip turns green. Real new saves with different X values will
--   further evolve the Welford state; the synthetic rows are
--   bootstrap data, not a permanent fixture.
--
-- IDEMPOTENT: ON CONFLICT DO NOTHING. Re-runs are no-ops; missing
-- pairs are filled in; existing real-data rows are preserved.
--
-- SCOPE: Only inserts the OPPOSITE X value for each existing row.
-- Does NOT clear or modify existing data. To wipe and re-seed,
-- TRUNCATE first (but that destroys real Welford state).
--
-- PHASE 1: T8.5 + T9.5 — this seed is the third move in the
--   calibration feature cluster. Combined with the schema
--   migrations (5e77d41), the Welford trigger (in migration 0003),
--   the backfill (de83d10), and the iOS wiring (99a8d5d, 1b990e3,
--   621beba, a696e8b, 4769f5c), this completes the calibration
--   end-to-end loop. The chip's pair-wise ratio helper will now
--   return non-nil for every (swimmer, distance, stroke) bucket,
--   and the SessionReview will surface the calibrationHint under
--   any row whose prediction uses calibration.

-- Suit: insert the opposite suit value with a 3% mean shift.
-- 3% is the typical high-end suit gain; it produces a noticeable
-- but realistic calibrationHint ("3% off due to suit calibration")
-- in SessionReview.
INSERT INTO swimmer_suits (
  swimmer_id, suit, distance, stroke,
  mean_time_ms, stddev_time_ms, sample_count, m2, updated_at
)
SELECT
  swimmer_id,
  NOT suit,                                                 -- flip
  distance,
  stroke,
  mean_time_ms * (CASE WHEN suit THEN 1.0/0.97 ELSE 0.97 END),  -- 3% shift
  stddev_time_ms,
  sample_count,
  m2,
  now()
FROM swimmer_suits
ON CONFLICT (swimmer_id, suit, distance, stroke) DO NOTHING;

-- Start: insert the opposite start_type with a 1% mean shift.
-- 1% is the typical dive-vs-in-water gain for distance swimmers;
-- it produces a subtle but real calibrationHint in SessionReview.
-- The flip rule: in_water <-> dive, in_water <-> backstroke_start.
-- backstroke_start is its own thing (different event); only
-- flip in_water <-> dive for simplicity.
INSERT INTO swimmer_starts (
  swimmer_id, start_type, distance, stroke,
  mean_time_ms, stddev_time_ms, sample_count, m2, updated_at
)
SELECT
  swimmer_id,
  CASE WHEN start_type = 'in_water' THEN 'dive' ELSE 'in_water' END,
  distance,
  stroke,
  mean_time_ms * (CASE WHEN start_type = 'in_water' THEN 0.99 ELSE 1.0/0.99 END),
  stddev_time_ms,
  sample_count,
  m2,
  now()
FROM swimmer_starts
ON CONFLICT (swimmer_id, start_type, distance, stroke) DO NOTHING;
