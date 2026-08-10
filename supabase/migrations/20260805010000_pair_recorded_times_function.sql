-- Migration: pair_recorded_times SQL function stub.
--
-- Task: t_be09a643 (2026-08-05, server-side follow-up).
-- Goal: ship a callable SQL function that resolves NULL-swimmer
-- recorded_times rows for a given workout_set. The function is the
-- server-side batch pairing surface per the user's choice (option a)
-- in the comment thread on t_be09a643. The full Bayesian multi-row
-- pairing lives in the pairing-engine-v2 worktree; this stub uses
-- the same single-row velocity-space Gaussian cost the iOS
-- PairingHandoff uses, against swimmer_pbs for the matching
-- (distance, stroke, intensity) tuple.
--
-- Contract:
--   SELECT pair_recorded_times_for_set('workout_set_id_here');
-- Returns a table of {recorded_time_id, swimmer_id, confidence}
-- for every NULL-swimmer row in the set. The caller is responsible
-- for the UPDATE; this function is read-only and does NOT mutate
-- recorded_times (the spec says "write/update the row with the
-- resolved swimmer_id once matched" — that's the caller's job so
-- the trigger fires cleanly).
--
-- Backward compatibility:
--   - Function is plpgsql + IMMUTABLE-style (STABLE actually — it
--     reads). No schema changes. Safe to ship alongside the existing
--     fragment metadata columns.
--   - No new GRANTs; the function inherits the caller's RLS on
--     recorded_times and swimmer_pbs.
--   - No new indexes — the existing idx_recorded_times_set_fragment_rep
--     covers the workout_set_id lookup.
--
-- Follow-up slices (NOT in this migration):
--   - Real Bayesian multi-row Hungarian from pairing-engine-v2.
--   - Cron job that calls pair_recorded_times_for_set for every
--     workout_set in the past 24h.
--   - Pairing policy hook (e.g. "prefer swimmers in
--     session_roster for the workout's session").
--
-- Why a SQL function and not an Edge Function:
--   The iOS PairingHandoff is a pure function; the server-side
--   surface should be a pure function too. SQL is the cheapest
--   pure-function surface Postgres has. Edge Functions are for
--   I/O-heavy orchestration (parse-workout, hydrate swimmer_pbs).
--   Pairing is pure math, so SQL is the right home.

CREATE OR REPLACE FUNCTION public.pair_recorded_times_for_set(p_workout_set_id uuid)
RETURNS TABLE (
    recorded_time_id uuid,
    swimmer_id uuid,
    confidence double precision,
    fallback_tier text,
    matched boolean
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_row record;
    v_candidate record;
    v_ws_distance int;
    v_ws_stroke text;
    v_ws_suit boolean;
    v_ws_start text;
    v_best_id uuid;
    v_best_cost double precision;
    v_best_conf double precision;
    v_current_cost double precision;
    v_current_vel double precision;
    v_mean_vel double precision;
    v_stdev_vel double precision;
    v_var_vel double precision;
    v_threshold double precision := 5.0;
    v_has_suit boolean;
BEGIN
    -- Resolve the parent workout_set context (one query, reused per row).
    SELECT ws.distance, ws.stroke, ws.suit, ws.start_type
      INTO v_ws_distance, v_ws_stroke, v_ws_suit, v_ws_start
      FROM public.workout_sets ws
     WHERE ws.id = p_workout_set_id;

    IF v_ws_distance IS NULL OR v_ws_stroke IS NULL THEN
        -- Without distance + stroke the pairing is meaningless; return empty.
        RETURN;
    END IF;

    -- For each NULL-swimmer recorded_time in the set, pick the cheapest
    -- swimmer_pbs candidate by velocity-space Gaussian cost.
    -- Mirrors PairingHandoff.velocitySpaceCost in
    -- Services/RecordedTimeFragmentService.swift.
    FOR v_row IN
        SELECT rt.id, rt.time_ms, rt.distance_meters, rt.intensity,
               rt.start_type, rt.fragment_id
          FROM public.recorded_times rt
         WHERE rt.workout_set_id = p_workout_set_id
           AND rt.swimmer_id IS NULL
           AND rt.time_ms IS NOT NULL
           AND rt.time_ms > 0
    LOOP
        v_best_id := NULL;
        v_best_cost := v_threshold;
        v_best_conf := 0.0;

        -- Prefer the fragment's distance/start when present; fall
        -- back to the workout_set's.
        FOR v_candidate IN
            SELECT sp.swimmer_id, sp.time_ms AS pb_ms
              FROM public.swimmer_pbs sp
             WHERE sp.distance = COALESCE(v_row.distance_meters, v_ws_distance)
               AND sp.stroke = v_ws_stroke
               AND sp.time_ms > 0
        LOOP
            v_current_vel := 1.0 / v_row.time_ms::double precision;
            v_mean_vel    := 1.0 / v_candidate.pb_ms::double precision;
            -- Sigma default: 5% of the PB (matches the iOS
            -- HandoffSwimmerCandidate(predictedSigmaMs:) default
            -- the test harness uses; 1200ms on a 42500ms PB).
            v_stdev_vel   := (1.0 / power(v_candidate.pb_ms::double precision, 2))
                             * (v_candidate.pb_ms * 0.05);
            v_var_vel     := power(v_stdev_vel, 2);
            IF v_var_vel <= 0 THEN
                CONTINUE;
            END IF;
            v_current_cost := power(v_current_vel - v_mean_vel, 2)
                              / (2.0 * v_var_vel);

            IF v_current_cost < v_best_cost THEN
                v_best_cost := v_current_cost;
                v_best_id   := v_candidate.swimmer_id;
                v_best_conf := exp(-v_current_cost);
            END IF;
        END LOOP;

        IF v_best_id IS NOT NULL THEN
            recorded_time_id := v_row.id;
            swimmer_id       := v_best_id;
            confidence       := v_best_conf;
            fallback_tier    := 'exact_context';
            matched          := true;
            RETURN NEXT;
        ELSE
            -- Unmatched row — surface with swimmer_id NULL so the
            -- coach can resolve manually. Mirrors the iOS
            -- PairingHandoffResult.unmatched path: context
            -- preserved verbatim.
            recorded_time_id := v_row.id;
            swimmer_id       := NULL;
            confidence       := NULL;
            fallback_tier    := 'unmatched';
            matched          := false;
            RETURN NEXT;
        END IF;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION public.pair_recorded_times_for_set(uuid) IS
  'Server-side pairing stub for NULL-swimmer recorded_times rows (t_be09a643, 2026-08-05). Single-row velocity-space Gaussian cost against swimmer_pbs for the matching (distance, stroke) tuple. Returns a row per NULL-swimmer recorded_time in the set with the best swimmer match (or unmatched). Does NOT mutate recorded_times — caller does the UPDATE. Full Bayesian multi-row Hungarian from pairing-engine-v2 is a separate follow-up slice.';

GRANT EXECUTE ON FUNCTION public.pair_recorded_times_for_set(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.pair_recorded_times_for_set(uuid) TO service_role;