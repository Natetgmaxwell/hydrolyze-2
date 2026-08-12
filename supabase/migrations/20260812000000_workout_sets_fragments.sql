-- Migration 20260812: workout_sets.fragments JSONB (V0.35 slice 1)
-- Parsed leaf fragments for composite sets ("4 x (75 fast / 25 easy)").
-- No backfill: NULL for sets parsed before V0.35. New parses only.

ALTER TABLE public.workout_sets
    ADD COLUMN IF NOT EXISTS fragments JSONB;

COMMENT ON COLUMN public.workout_sets.fragments IS
    'Parsed leaf fragments for this set (WorkoutSetFragment array: id, order_index, distance_meters, reps, intensity, start_type, pace_target_sec, confidence). NULL for sets parsed before V0.35.';
