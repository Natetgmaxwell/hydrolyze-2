-- V0.41 (2026-08-18): set-level zone term on workout_sets.
-- Zone words ("easy" / "steady" / "hard" / "sprint") parse to a new
-- zone_term field. Free-form text, mirroring intensity_type (no CHECK).
-- Pace is resolved per-swimmer at timing time (TrainingZoneService),
-- never stored here.
ALTER TABLE public.workout_sets
    ADD COLUMN IF NOT EXISTS zone_term text;
