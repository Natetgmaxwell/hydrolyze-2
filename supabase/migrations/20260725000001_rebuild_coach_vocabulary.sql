-- 20260725000001_rebuild_coach_vocabulary.sql
-- Rebuild the coach_vocabulary table (dropped in 20260623000002_delete_bloat.sql).
-- This is the RPE flywheel: per-coach mapping of natural language intensity terms
-- to RPE ranges. When the coach writes "moderate" and we prompt for RPE, the
-- mapping is saved. Next time "moderate" silently resolves.
--
-- Design: originals/rpe-nomenclature-for-hydrolyze-intensity

CREATE TABLE IF NOT EXISTS coach_vocabulary (
  coach_id       uuid    NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  user_term      text    NOT NULL,   -- "moderate", "hard", "easy", etc.
  rpe_low        integer NOT NULL,   -- RPE low end (1-10 scale)
  rpe_high       integer NOT NULL,   -- RPE high end (1-10 scale)
  sample_count   integer NOT NULL DEFAULT 1,  -- how many times this term has been used
  updated_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (coach_id, user_term),
  CHECK (rpe_low >= 1 AND rpe_low <= 10),
  CHECK (rpe_high >= 1 AND rpe_high <= 10),
  CHECK (rpe_low <= rpe_high)
);

COMMENT ON TABLE coach_vocabulary IS
  'Per-coach mapping of natural language intensity terms to RPE ranges. '
  'The parser learns the coach''s vocabulary over time: ambiguous terms '
  'like "moderate" are mapped to RPE ranges (e.g. 6-7) via inline prompt. '
  'Once mapped, future uses resolve silently.';

ALTER TABLE coach_vocabulary ENABLE ROW LEVEL SECURITY;

CREATE POLICY "coach_own_vocabulary"
  ON coach_vocabulary FOR ALL
  USING (coach_id = auth.uid())
  WITH CHECK (coach_id = auth.uid());

-- Index for fast lookup during parsing
CREATE INDEX IF NOT EXISTS idx_coach_vocabulary_coach_term
  ON coach_vocabulary(coach_id, user_term);
