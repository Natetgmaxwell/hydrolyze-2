-- Migration: Restore groups + swimmer_groups tables
-- Date: 2026-07-02
--
-- Recovery for a 2026-07-02 production bug:
--   Migration 20260623000002_delete_bloat.sql dropped `groups` and
--   `swimmer_groups` CASCADE under the assumption they were "0 iOS
--   consumers" — that assumption was wrong. SwimmerService.swift
--   actively reads/writes both tables (fetchGroups, createGroup,
--   assignSwimmerToGroup, etc.). After the drop, every call from
--   SwimmersListViewModel.loadSwimmers returned
--   PostgrestError(code=PGRST205, message="Could not find the table
--   'public.groups' in the schema cache").
--
-- Restoration uses the canonical definitions from schema.sql (which
-- itself predates the wrong drop). RLS policies mirror the original
--   (coach_id scoped, coach can SELECT/INSERT/UPDATE/DELETE their
--   own group's rows). Idempotent: CREATE TABLE IF NOT EXISTS +
--   DROP POLICY IF EXISTS + CREATE POLICY.
--
-- ponytail: smallest possible recovery. The schema was working
-- before 20260623000002 ran; restoring it exactly is the right
-- scope. No new features, no indexes beyond the PK, no surprises.

BEGIN;

-- ═══════════════════════════════════════════════════════════════════
-- Table: groups
-- ═══════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS groups (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  coach_id    uuid NOT NULL REFERENCES coaches(id) ON DELETE CASCADE,
  name        text NOT NULL,
  created_at  timestamptz DEFAULT now(),
  UNIQUE (coach_id, name)
);

ALTER TABLE groups ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS coach_own_groups ON groups;
CREATE POLICY coach_own_groups ON groups
  FOR ALL
  USING (
    coach_id IN (
      SELECT id FROM coaches WHERE auth_id = auth.uid()
    )
  )
  WITH CHECK (
    coach_id IN (
      SELECT id FROM coaches WHERE auth_id = auth.uid()
    )
  );

COMMENT ON TABLE groups IS
  'Named groups of swimmers (Gold, Juniors, Sprinters, etc.). '
  'Restored 2026-07-02 after being wrongly dropped by '
  '20260623000002_delete_bloat.sql (SwimmerService.swift actively '
  'consumes this table; the "0 iOS consumers" claim in that '
  'migration was incorrect).';

-- ═══════════════════════════════════════════════════════════════════
-- Table: swimmer_groups (many-to-many)
-- ═══════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS swimmer_groups (
  swimmer_id  uuid NOT NULL REFERENCES swimmers(id) ON DELETE CASCADE,
  group_id    uuid NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  PRIMARY KEY (swimmer_id, group_id)
);

ALTER TABLE swimmer_groups ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS coach_own_swimmer_groups ON swimmer_groups;
CREATE POLICY coach_own_swimmer_groups ON swimmer_groups
  FOR ALL
  USING (
    group_id IN (
      SELECT g.id FROM groups g
        JOIN coaches c ON c.id = g.coach_id
       WHERE c.auth_id = auth.uid()
    )
  )
  WITH CHECK (
    group_id IN (
      SELECT g.id FROM groups g
        JOIN coaches c ON c.id = g.coach_id
       WHERE c.auth_id = auth.uid()
    )
  );

COMMENT ON TABLE swimmer_groups IS
  'Many-to-many swimmer↔group junction. Restored 2026-07-02 '
  'together with `groups`. The RLS policy keys off the parent '
  'group''s coach_id (avoids joining swimmers.coach_id twice).';

COMMIT;