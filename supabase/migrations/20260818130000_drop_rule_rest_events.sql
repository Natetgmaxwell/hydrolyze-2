-- Migration: Drop Rule rest events — V0.39 Slice 1 (additive only)
--
-- Timestamp: 2026-08-18 13:00
-- Author: build profile (V0.39, drop rule)
--
-- WHY THIS MIGRATION EXISTS
-- Eva Piatrikova's drop rule is default-to-assign applied to rest: when a
-- swimmer's rep time drops more than the threshold (0.5s for 50m, 0.25s for
-- 25m) off their standard, the engine extends their rest by +30s on the first
-- strike and +60s on a second. This table records every rest-extension
-- decision so the recovery-signature flywheel (V0.40+) can query per swimmer
-- across sets and weeks: "how many reps at what rest before times fall."
--
-- One additive piece, no destructive ops, no backfill:
--
--   set_rest_events  one row per rest-extension decision
--
-- The `reverted` flag preserves coach-is-authority: a reverted extension is
-- recorded (the engine learns the coach disagreed) but the rest was not
-- extended. A table (not a JSONB blob on workout_set_completions) because the
-- flywheel reads it as analytics — a blob is write-only, a table is queryable.
--
-- RLS mirrors swimmer_pbs (schema.sql lines 321-333): a coach sees events for
-- swimmers they own. Same pattern as swimmer_test_profiles in migration
-- 20260815120000_3mt_mode.sql.
--
-- Reference: V0.39_SPEC.md §Slice 1,
-- docs/research/2026-08-15-3mt-drop-rule-zones.md §3.3 + §4.
--
-- NOTE on the CHECK: the migration script that applies this file preserves an
-- outer BEGIN/COMMIT (or uses the file's own single pair). The inline CHECK on
-- standard_source is a table-scoped constraint so it rides along with the
-- CREATE TABLE IF NOT EXISTS; on a re-run the whole statement is a no-op.

BEGIN;

CREATE TABLE IF NOT EXISTS set_rest_events (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id        uuid NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  workout_set_id    uuid NOT NULL REFERENCES workout_sets(id) ON DELETE CASCADE,
  swimmer_id        uuid NOT NULL REFERENCES swimmers(id) ON DELETE CASCADE,
  rep_index         integer NOT NULL,
  rep_time_ms       integer NOT NULL,
  standard_ms       integer NOT NULL,
  base_rest_sec     integer NOT NULL,
  extended_rest_sec integer NOT NULL,
  delta_sec         integer NOT NULL,
  strike_count      integer NOT NULL DEFAULT 1,
  standard_source   text NOT NULL CHECK (standard_source IN ('predicted', 'rep1')),
  reverted          boolean NOT NULL DEFAULT false,
  created_at        timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_rest_events_swimmer
  ON set_rest_events(swimmer_id, workout_set_id);

COMMENT ON TABLE set_rest_events IS
  'Drop-rule rest-extension decision (Piatrikova). One row per decision incl. reverted ones — a reverted extension records coach disagreement but did not extend the rest. Read by the recovery-signature flywheel (V0.40+). V0.39 Slice 1.';

-- RLS — coach pattern is the same as swimmer_pbs / swimmer_test_profiles:
-- a coach sees rows for swimmers they own.
ALTER TABLE set_rest_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS set_rest_events_select ON set_rest_events;
CREATE POLICY set_rest_events_select ON set_rest_events
  FOR SELECT USING (
    swimmer_id IN (SELECT id FROM swimmers WHERE coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()))
  );

DROP POLICY IF EXISTS set_rest_events_insert ON set_rest_events;
CREATE POLICY set_rest_events_insert ON set_rest_events
  FOR INSERT WITH CHECK (
    swimmer_id IN (SELECT id FROM swimmers WHERE coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()))
  );

DROP POLICY IF EXISTS set_rest_events_update ON set_rest_events;
CREATE POLICY set_rest_events_update ON set_rest_events
  FOR UPDATE USING (
    swimmer_id IN (SELECT id FROM swimmers WHERE coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()))
  );

COMMIT;
