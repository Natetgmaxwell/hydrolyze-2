-- Migration: extend recorded_times with fragment metadata.
--
-- Task: t_be09a643 (2026-08-05).
-- Goal: stopwatch stop on the per-fragment CTA writes a row that
-- carries the fragment context (which leaf fragment was timed, the
-- distance, intensity, start, pace target) so the pairing engine can
-- evaluate the row against the right (swimmer, distance, intensity,
-- start) prediction rather than the parent workout_set's generic PB.
--
-- Why the new columns rather than reusing workout_sets columns:
-- the fragment is the unit the stopwatch times AND the unit the
-- pairing engine evaluates. A 4 x (75 fast / 25 easy) set has 8
-- leaves; the parent workout_set only knows about the 100m total.
-- The fragment context must live on the row so the pairing engine
-- can read it without re-parsing the workout.
--
-- Columns:
--   fragment_id      text — the WorkoutSetFragment.id (matches the
--                      workout_sets.fragments JSONB id). Nullable
--                      so existing rows (which lack fragment
--                      context) stay valid.
--   distance_meters  integer — the fragment's distance. Nullable
--                      for legacy rows.
--   start_type       text — fragment-level start ('dive' |
--                      'wall' | 'push'). Nullable; falls through
--                      to workout_sets.start_type when null.
--   pace_target_sec  integer — fragment-level pace target in
--                      seconds (send-off for the enclosing
--                      interval, the same shape WorkoutSetFragment
--                      carries). Nullable when no pace target.
--   raw_text         text — the verbatim source line the coach
--                      entered ("4 x (75 fast / 25 easy)"). Lets
--                      the pairing-engine handoff + audit log
--                      reconstruct the source without re-joining
--                      workout_sets. Nullable.
--
-- Mapping to spec fields:
--   set_id           -> existing workout_set_id (already present)
--   recorded_ms      -> existing time_ms (already present)
--   swimmer_id       -> existing swimmer_id (already present, nullable)
--   intensity        -> existing intensity (already present)
--   created_at       -> existing created_at (already present)
--
-- Backward compatibility:
--   - All new columns are NULLABLE so existing rows continue to
--     decode.
--   - The welford_trigger_recorded_times() trigger reads
--     workout_sets.start_type as a fallback; the new column on
--     recorded_times does not affect that path until
--     TimingService.saveFragment() starts writing it.
--   - No CHECK constraints are tightened — the new columns are
--     free-form text/integer until the iOS model lands.
--
-- Indexes:
--   - idx_recorded_times_fragment_id for the pairing-engine handoff
--     lookup (find rows awaiting pairing by fragment).
--   - Composite idx on (workout_set_id, fragment_id, rep_index)
--     for the per-fragment timing save flow.
--
-- No data backfill is shipped here — historical rows remain null
-- in the new columns. Backfill is a separate slice once the
-- workout_sets.fragments JSONB column ships and we can resolve
-- fragment_id from the parsed tree.

ALTER TABLE public.recorded_times
    ADD COLUMN IF NOT EXISTS fragment_id      text,
    ADD COLUMN IF NOT EXISTS distance_meters  integer,
    ADD COLUMN IF NOT EXISTS start_type       text,
    ADD COLUMN IF NOT EXISTS pace_target_sec  integer,
    ADD COLUMN IF NOT EXISTS raw_text         text;

COMMENT ON COLUMN public.recorded_times.fragment_id IS
    'WorkoutSetFragment.id the stopwatch timed (matches workout_sets.fragments JSONB id). NULL for legacy rows that pre-date per-fragment timing.';
COMMENT ON COLUMN public.recorded_times.distance_meters IS
    'Fragment-level distance in meters (not the parent workout_set.distance). NULL for legacy rows.';
COMMENT ON COLUMN public.recorded_times.start_type IS
    'Fragment-level start type: dive | wall | push. Denormalised from workout_sets.start_type when not set; per-fragment override lands with the parse-workout Edge Function.';
COMMENT ON COLUMN public.recorded_times.pace_target_sec IS
    'Fragment-level pace target in seconds (the enclosing interval send-off). NULL when no canonical pace target (open / multi-descending / range).';
COMMENT ON COLUMN public.recorded_times.raw_text IS
    'Verbatim source line the coach entered (e.g. "4 x (75 fast / 25 easy)"). Lets the pairing-engine handoff + audit log reconstruct the source without re-joining workout_sets. NULL for legacy rows.';

CREATE INDEX IF NOT EXISTS idx_recorded_times_fragment_id
    ON public.recorded_times (fragment_id)
    WHERE fragment_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_recorded_times_set_fragment_rep
    ON public.recorded_times (workout_set_id, fragment_id, rep_index)
    WHERE workout_set_id IS NOT NULL;