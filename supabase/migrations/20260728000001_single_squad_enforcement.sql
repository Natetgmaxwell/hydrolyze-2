-- Migration: enforce single-squad membership at the DB level
--
-- A swimmer can only be in one squad at a time. The app layer already
-- enforces this (setSwimmerGroups does delete-then-insert with a single
-- group), but without a DB constraint a bug or direct DB access could
-- create multi-group memberships that break the pairing engine and
-- attendance flow.
--
-- We use a partial unique index rather than a CHECK constraint because
-- the composite PK already handles (swimmer_id, group_id) dedup — we
-- just need to ensure no swimmer_id appears more than once in the table.

BEGIN;

-- Drop any existing version of this index (idempotent)
DROP INDEX IF EXISTS swimmer_groups_single_squad;

-- Partial unique index: each swimmer_id can appear at most once
CREATE UNIQUE INDEX swimmer_groups_single_squad
  ON swimmer_groups(swimmer_id);

COMMIT;