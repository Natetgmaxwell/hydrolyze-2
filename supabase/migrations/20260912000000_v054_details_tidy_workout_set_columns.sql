-- V0.54 details-tidy (2026-09-12): adds the display-fidelity + Mode 3
-- ladder columns to workout_sets that the iOS model layer (WorkoutSet,
-- WorkoutSetFragment) was already sending in payloads but the DB
-- schema was missing. Without these, saveWorkout hits PostgREST
-- PGRST204 "Could not find the 'descend' column of 'workout_sets' in
-- the schema cache" — blocking every draft save with rich structure.
--
-- Columns added:
--   note              — per-set prose note (the "Each:" / "Descend:"
--                       caption the builder + details pages render)
--   descend           — set-level descend descriptor ("1-4" / "1-3")
--   per_rep_targets   — JSON array of per-rep target strings for the
--                       Mode 3 ProgressionRepGroupRow ladder
--   distance_label    — V0.53.3 verbatim source-text distance
--   intensity_label   — V0.53.3 verbatim coach word (e.g. "race
--                       rhythm") preserved over the parser type token

ALTER TABLE public.workout_sets
    ADD COLUMN IF NOT EXISTS note TEXT,
    ADD COLUMN IF NOT EXISTS descend TEXT,
    ADD COLUMN IF NOT EXISTS per_rep_targets JSONB,
    ADD COLUMN IF NOT EXISTS distance_label TEXT,
    ADD COLUMN IF NOT EXISTS intensity_label TEXT;

COMMENT ON COLUMN public.workout_sets.note IS
    'V0.54 details-tidy: per-set prose note (the "Each:" / "Descend:" caption). Optional.';
COMMENT ON COLUMN public.workout_sets.descend IS
    'V0.54 details-tidy: set-level descend descriptor ("1-4" / "1-3"). Drives Mode 3 ladder render.';
COMMENT ON COLUMN public.workout_sets.per_rep_targets IS
    'V0.54 details-tidy: JSON array of per-rep target strings for Mode 3 ProgressionRepGroupRow.';
COMMENT ON COLUMN public.workout_sets.distance_label IS
    'V0.54 details-tidy: V0.53.3 verbatim source-text distance ("12.5", "37.5"). Display-only.';
COMMENT ON COLUMN public.workout_sets.intensity_label IS
    'V0.54 details-tidy: V0.53.3 verbatim coach word ("race rhythm", "strong"). Display-only.';
