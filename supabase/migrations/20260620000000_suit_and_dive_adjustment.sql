-- Migration: Suit and Dive Adjustment (v2) — OBSOLETE, DO NOT RUN
-- Date: 2026-06-20
--
-- THIS FILE IS KEPT AS A HISTORICAL RECORD ONLY. The RLS in this file
-- uses the obsolete pattern (`coach_id = auth.uid()::text`) that the
-- live DB no longer matches. The live `swimmers.coach_id` is uuid
-- (FK to `coaches.id`), and the live RLS joins through
-- `coaches.auth_id = auth.uid()`. Running this file would fail with
-- ERROR: operator does not exist: uuid = text (verified 2026-06-20).
--
-- The working migration is 20260620000001_suit_and_dive_adjustment_v3.sql.
-- See:
--   - .hermes/plans/2026-06-20_suit-and-dive-calibration-phase-1-v2.md
--     (the plan that produced this v2 — preserved for context)
--   - .hermes/plans/2026-06-20_suit-and-dive-calibration-phase-1-v3.md
--     (the v3 plan, reflecting the live schema)
--   - originals/hydrolyze-coach-analytics-brainstorm-v4 (the design
--     evolution with the schema-drift discovery)
--
-- This file is a NO-OP stub. Running it does nothing.

BEGIN;
-- OBSOLETE — superseded by 20260620000001_suit_and_dive_adjustment_v3.sql
COMMIT;
