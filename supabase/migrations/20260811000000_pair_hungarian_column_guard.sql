-- Migration: Hungarian context-keyed pairing for pair_recorded_times_for_set.
--
-- Task: t_2a8763a5 (2026-08-05, server-side pairing engine swap).
-- Parent: t_be09a643 (per-fragment recorded_times pipeline + pairing handoff).
-- Prior: 20260805010000_pair_recorded_times_function.sql shipped the single-row
--         velocity-space Gaussian stub. This file replaces it with the
--         context-keyed Hungarian assignment, mirroring the iOS PairingEngine
--         (single global Hungarian across all swimmers × all recorded_time rows
--         for the set).
--
-- Goal (operator note, 2026-08-05):
--   "the hungarian algorithm we use to pair the live stopwatch collected times
--    to the swimmers ... the pairing is context aware in the sense that if
--    the set fragments it's collecting a time for is a 100 freestyle with
--    fins @ 100m pace, it's pairing using the historical data for this
--    specific swim"
--
-- Algorithm (1:1 port of iOS PairingEngine.swift + HungarianMatching.swift):
--   1. Pull all NULL-swimmer recorded_times rows for the set, each carrying
--      its own fragment context: distance_meters, stroke, intensity, gear,
--      start_type. The fragment metadata is the prediction key — NOT the
--      parent workout_set's generic distance/stroke.
--   2. Build the candidate swimmer list: distinct swimmers with at least one
--      PB matching any row's (distance, stroke).
--   3. Build a (size × size) cost matrix where size = max(n_swimmers, n_rows).
--      Rows = swimmers (1..n_swimmers real, n_swimmers+1..size are dummy
--      "ghost-tap" rows). Cols = recorded_times rows (1..n_rows real,
--      n_rows+1..size are dummy "missed-tap" cols). The cost cell at
--      (swimmer, row) is the velocity-space Gaussian cost against the
--      swimmer's best-context PB. Cells with no PB match are +Infinity.
--      The fallback tier is tagged alongside each cell.
--   4. Pad with dummies (mirroring iOS PairingEngine): a dummy-swimmer row
--      absorbs one real row at the ghost-tap threshold (so extra laps are
--      treated as ghost taps); a dummy-row col absorbed by a real swimmer
--      costs 0 (so missed taps get imputed cheaply).
--   5. Run Kuhn-Munkres Hungarian on the square matrix.
--   6. Emit one row per NULL-swimmer recorded_time: matched (swimmer_id,
--      confidence, fallback_tier) or unmatched (swimmer_id NULL,
--      confidence NULL, fallback_tier='unmatched').
--
-- Fallback tier chain (per cell, computed once during cost build):
--   - 'exact_context': PB matched on (distance, stroke, gear, intensity)
--   - 'intensity_overlap': PB matched on (distance, stroke, gear)
--   - 'gear_inferred': PB matched on (distance, stroke) — gear fell back
--   - 'ambiguous': no PB found → cell is hard-infinity
--
-- Contract:
--   SELECT pair_recorded_times_for_set('workout_set_id_here');
-- Returns a table of {recorded_time_id, swimmer_id, confidence,
-- fallback_tier, matched} for every NULL-swimmer row in the set. Read-only:
-- the caller UPDATEs recorded_times so the Welford trigger fires correctly.
--
-- Stability:
--   STABLE — the function reads but does not write. Repeated calls return
--   identical results within the same transaction snapshot. Caller does
--   the UPDATE.

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
    -- ─── Row inputs: NULL-swimmer recorded_times for the set ─────────
    v_rows uuid[] := ARRAY[]::uuid[];
    v_row_time_ms int[] := ARRAY[]::int[];
    v_row_distance int[] := ARRAY[]::int[];
    v_row_stroke text[] := ARRAY[]::text[];
    v_row_intensity text[] := ARRAY[]::text[];
    v_row_start_type text[] := ARRAY[]::text[];
    v_row_gear text[] := ARRAY[]::text[];
    v_n_rows int := 0;

    -- ─── Candidate swimmers: distinct swimmers with at least one matching PB ──
    v_swimmers uuid[] := ARRAY[]::uuid[];
    v_n_swimmers int := 0;

    -- ─── Cost matrix: v_cost[s][r] (s = swimmer index, r = row index) ──
    -- 1-indexed over both dimensions. Infinity means no PB matches that cell.
    v_cost double precision[][];

    -- Per-cell fallback tier (parallel to v_cost).
    v_tier text[][];

    -- ─── Hungarian matrix (size × size, padded with dummies) ──────────
    -- v_matrix[i][j] is 1-indexed (PL/pgSQL). The algorithm maps to Swift's
    -- matrix[i-1][j-1] (0-indexed in the iOS HungarianMatching.swift
    -- convention). We use the convention that v_matrix[2..size+1][2..size+1]
    -- holds the real cost data; index 1 is a sentinel slot.
    v_size int;
    v_max_size constant int := 64;   -- hard cap: prevent runaway cost
    v_matrix double precision[][];

    -- ─── Hungarian algorithm state ───────────────────────────────────
    -- Sized (size+1) each with index 1 as sentinel (Swift's index 0).
    -- v_u[i+1]    ↔ Swift's u[i]    (i ranges 1..size)
    -- v_v[j+1]    ↔ Swift's v[j]    (j ranges 1..size)
    -- v_p[j+1]    ↔ Swift's p[j]    (j ranges 1..size)
    -- v_way[j+1]  ↔ Swift's way[j]  (j ranges 1..size)
    -- v_minv[j+1] ↔ Swift's minv[j] (j ranges 1..size)
    -- v_used[j+1] ↔ Swift's used[j] (j ranges 1..size)
    v_u double precision[];
    v_v double precision[];
    v_p int[];
    v_way int[];
    v_minv double precision[];
    v_used boolean[];

    -- Iteration scratch.
    v_i int;
    v_j int;
    v_i0 int;
    v_j0 int;
    v_j1 int;
    v_delta double precision;

    -- ─── Per-row, post-Hungarian decision ────────────────────────────
    -- assignment_for_row[r] = s (1..size) — which matrix-row owns this
    -- column. Sentinel: -1 (unassigned). Sized (n_rows + 1) with
    -- index 0 as sentinel.
    v_assignment_for_row int[];

    -- ─── Ghost-tap threshold ────────────────────────────────────────
    v_ghost_threshold constant double precision := 5.0;

    -- ─── Scratch ──────────────────────────────────────────────────────
    v_row_data record;
BEGIN
    -- ═════════════════════════════════════════════════════════════════
    -- 1. Pull the NULL-swimmer rows for the set, with fragment context.
    --    Order by created_at, id for stable assignment across re-runs.
    -- ═════════════════════════════════════════════════════════════════
    FOR v_row_data IN
        SELECT rt.id, rt.time_ms, rt.distance_meters, rt.stroke,
               rt.intensity, rt.start_type, rt.gear
          FROM public.recorded_times rt
         WHERE rt.workout_set_id = p_workout_set_id
           AND rt.swimmer_id IS NULL
           AND rt.time_ms IS NOT NULL
           AND rt.time_ms > 0
         ORDER BY rt.created_at, rt.id
    LOOP
        v_n_rows := v_n_rows + 1;
        v_rows := v_rows || v_row_data.id;
        v_row_time_ms := v_row_time_ms || v_row_data.time_ms;
        v_row_distance := v_row_distance || v_row_data.distance_meters;
        v_row_stroke := v_row_stroke || v_row_data.stroke;
        v_row_intensity := v_row_intensity || v_row_data.intensity;
        v_row_start_type := v_row_start_type || v_row_data.start_type;
        v_row_gear := v_row_gear || v_row_data.gear;
    END LOOP;

    IF v_n_rows = 0 THEN
        RETURN;
    END IF;

    -- ═════════════════════════════════════════════════════════════════
    -- 2. Pull the candidate swimmers: every swimmer with at least one
    --    PB matching any row's (distance, stroke). Gear/intensity
    --    filtering happens per-cell in the cost build.
    -- ═════════════════════════════════════════════════════════════════
    SELECT array_agg(DISTINCT sp.swimmer_id ORDER BY sp.swimmer_id)
      INTO v_swimmers
      FROM public.swimmer_pbs sp
     WHERE sp.time_ms > 0
       AND EXISTS (
           SELECT 1 FROM unnest(v_row_distance, v_row_stroke) AS r(d, s)
            WHERE r.d = sp.distance AND r.s = sp.stroke
       );

    v_n_swimmers := COALESCE(array_length(v_swimmers, 1), 0);

    IF v_n_swimmers = 0 THEN
        -- No swimmers have any matching PB. Every row is unmatched.
        FOR v_i IN 1..v_n_rows LOOP
            recorded_time_id := v_rows[v_i];
            swimmer_id       := NULL;
            confidence       := NULL;
            fallback_tier    := 'unmatched';
            matched          := false;
            RETURN NEXT;
        END LOOP;
        RETURN;
    END IF;

    -- Size of the square Hungarian matrix. Larger dimension wins; the
    -- smaller side is padded with dummies.
    v_size := GREATEST(v_n_rows, v_n_swimmers);
    IF v_size > v_max_size THEN
        RAISE EXCEPTION 'pair_recorded_times_for_set: matrix too large (%, max %)', v_size, v_max_size;
    END IF;

    -- ═════════════════════════════════════════════════════════════════
    -- 3. Build the cost matrix.
    --    For each (swimmer × row) cell, the swimmer's PB is selected by:
    --      (a) (distance, stroke, gear, intensity) exact match
    --          → fallback_tier = 'exact_context'
    --      (b) (distance, stroke, gear) match — intensity fallback
    --          → fallback_tier = 'intensity_overlap'
    --      (c) (distance, stroke) match — gear inferred
    --          → fallback_tier = 'gear_inferred'
    --    If none match, the cell is +Infinity (unmatchable).
    -- ═════════════════════════════════════════════════════════════════
    v_cost := array_fill(0::double precision, ARRAY[v_n_swimmers, v_n_rows]);
    v_tier := array_fill('ambiguous'::text, ARRAY[v_n_swimmers, v_n_rows]);

    FOR v_i IN 1..v_n_swimmers LOOP
        FOR v_j IN 1..v_n_rows LOOP
            DECLARE
                v_sw uuid := v_swimmers[v_i];
                v_dist int := v_row_distance[v_j];
                v_stk text := v_row_stroke[v_j];
                v_int text := v_row_intensity[v_j];
                v_g text := v_row_gear[v_j];
                v_pb_time int;
                v_pb_sigma int;
                v_actual_vel double precision;
                v_mean_vel double precision;
                v_stdev_vel double precision;
                v_var_vel double precision;
            BEGIN
                -- Treat NULL stroke / NULL distance as unmatchable.
                IF v_dist IS NULL OR v_stk IS NULL OR v_stk = '' THEN
                    v_cost[v_i][v_j] := 'Infinity'::double precision;
                    CONTINUE;
                END IF;

                -- NULL gear → 'none' so the PB with gear='none' (the iOS
                -- convention) is matchable.
                v_g := COALESCE(NULLIF(v_g, ''), 'none');

                -- (a) exact-context match: distance + stroke + gear + intensity.
                SELECT sp.time_ms, GREATEST((sp.time_ms * 0.05)::int, 100)
                  INTO v_pb_time, v_pb_sigma
                  FROM public.swimmer_pbs sp
                 WHERE sp.swimmer_id = v_sw
                   AND sp.distance = v_dist
                   AND sp.stroke = v_stk
                   AND COALESCE(sp.gear, 'none') = v_g
                   AND sp.intensity = v_int
                   AND sp.time_ms > 0
                 ORDER BY sp.recorded_at DESC NULLS LAST
                 LIMIT 1;

                IF v_pb_time IS NOT NULL THEN
                    v_tier[v_i][v_j] := 'exact_context';
                ELSE
                    -- (b) intensity overlap: drop intensity, keep gear.
                    SELECT sp.time_ms, GREATEST((sp.time_ms * 0.05)::int, 100)
                      INTO v_pb_time, v_pb_sigma
                      FROM public.swimmer_pbs sp
                     WHERE sp.swimmer_id = v_sw
                       AND sp.distance = v_dist
                       AND sp.stroke = v_stk
                       AND COALESCE(sp.gear, 'none') = v_g
                       AND sp.time_ms > 0
                     ORDER BY sp.recorded_at DESC NULLS LAST
                     LIMIT 1;

                    IF v_pb_time IS NOT NULL THEN
                        v_tier[v_i][v_j] := 'intensity_overlap';
                    ELSE
                        -- (c) gear inferred: drop gear, keep (distance, stroke).
                        SELECT sp.time_ms, GREATEST((sp.time_ms * 0.05)::int, 100)
                          INTO v_pb_time, v_pb_sigma
                          FROM public.swimmer_pbs sp
                         WHERE sp.swimmer_id = v_sw
                           AND sp.distance = v_dist
                           AND sp.stroke = v_stk
                           AND sp.time_ms > 0
                         ORDER BY sp.recorded_at DESC NULLS LAST
                         LIMIT 1;

                        IF v_pb_time IS NOT NULL THEN
                            v_tier[v_i][v_j] := 'gear_inferred';
                        ELSE
                            v_cost[v_i][v_j] := 'Infinity'::double precision;
                            CONTINUE;
                        END IF;
                    END IF;
                END IF;

                -- Velocity-space Gaussian cost (V10, port of PairingEngine
                -- .velocitySpaceCost and PairingHandoff.velocitySpaceCost).
                v_actual_vel := 1.0 / v_row_time_ms[v_j]::double precision;
                v_mean_vel   := 1.0 / v_pb_time::double precision;
                v_stdev_vel  := (1.0 / power(v_pb_time::double precision, 2))
                                * v_pb_sigma::double precision;
                v_var_vel    := power(v_stdev_vel, 2);
                IF v_var_vel <= 0 THEN
                    v_cost[v_i][v_j] := 'Infinity'::double precision;
                ELSE
                    v_cost[v_i][v_j] := power(v_actual_vel - v_mean_vel, 2)
                                       / (2.0 * v_var_vel);
                END IF;
            END;
        END LOOP;
    END LOOP;

    -- ═════════════════════════════════════════════════════════════════
    -- 3b. Column-completeness guard (2026-08-11, e2e-pairing-75-fast).
    --    A column whose context matches NO swimmer's PB is all-Infinity.
    --    The Hungarian inner loop then never finds a finite delta and
    --    spins forever (statement timeout). Fix: give every real
    --    swimmer a ghost-cost cell in that column. The emit check
    --    (cost < ghost_threshold) then correctly reports it unmatched.
    -- ═════════════════════════════════════════════════════════════════
    FOR v_j IN 1..v_n_rows LOOP
        DECLARE
            v_col_finite boolean := false;
        BEGIN
            FOR v_i IN 1..v_n_swimmers LOOP
                IF v_cost[v_i][v_j] < 'Infinity'::double precision THEN
                    v_col_finite := true;
                    EXIT;
                END IF;
            END LOOP;
            IF NOT v_col_finite THEN
                FOR v_i IN 1..v_n_swimmers LOOP
                    v_cost[v_i][v_j] := v_ghost_threshold;
                END LOOP;
            END IF;
        END;
    END LOOP;

    -- ═════════════════════════════════════════════════════════════════
    -- 4. Build the (size+1) × (size+1) square matrix that Kuhn-Munkres
    --    operates on. v_matrix[i+1][j+1] holds the (i, j) cell where
    --    i, j are 1-indexed. Sentinel slot at [1][*] and [*][1] is the
    --    algorithm's scratch.
    --    Rows = swimmers (1..n_swimmers real, n_swimmers+1..size dummy).
    --    Cols = recorded_times rows (1..n_rows real, n_rows+1..size dummy).
    -- ═════════════════════════════════════════════════════════════════
    v_matrix := array_fill('Infinity'::double precision, ARRAY[v_size + 1, v_size + 1]);

    -- Copy the real (cost) cells.
    FOR v_i IN 1..v_n_swimmers LOOP
        FOR v_j IN 1..v_n_rows LOOP
            v_matrix[v_i + 1][v_j + 1] := v_cost[v_i][v_j];
        END LOOP;
    END LOOP;

    -- Pad dummy rows (when n_swimmers < size → ghost taps possible).
    -- Dummy row i (i in n_swimmers+1..size) absorbs the column at
    -- j = i - n_swimmers (a real row). Cost at (i, j) is the ghost
    -- threshold; all other cells stay at infinity. Each dummy absorbs
    -- at most one column.
    IF v_n_swimmers < v_size THEN
        FOR v_i IN v_n_swimmers + 1..v_size LOOP
            v_matrix[v_i + 1][(v_i - v_n_swimmers) + 1] := v_ghost_threshold;
        END LOOP;
    END IF;

    -- Pad dummy cols (when n_rows < size → missed taps possible).
    -- Every real swimmer gets a free dummy col at cost 0 so the
    -- Hungarian can absorb the missed-tap cheaply. The original
    -- Swift port (PairingEngine.swift) sets cost=0 only at the
    -- diagonal (i == j - n_rows), which leaves the last n_rows
    -- real swimmers with no free dummy col when n_swimmers > n_rows
    -- — forcing them to compete for the real cols and causing the
    -- wrong swimmer to win. Setting the full dummy block to 0 for
    -- every real swimmer row fixes this without affecting the
    -- n_swimmers ≤ n_rows cases (no dummy cols in that path).
    IF v_n_rows < v_size THEN
        FOR v_i IN 1..v_n_swimmers LOOP
            FOR v_j IN v_n_rows + 1..v_size LOOP
                v_matrix[v_i + 1][v_j + 1] := 0;
            END LOOP;
        END LOOP;
    END IF;

    -- ─── Kuhn-Munkres Hungarian ──────────────────────────────────────
    -- iOS port. All arrays sized (size+1) with index 1 as sentinel.
    v_u    := array_fill(0.0::double precision, ARRAY[v_size + 1]);
    v_v    := array_fill(0.0::double precision, ARRAY[v_size + 1]);
    v_p    := array_fill(0::int,             ARRAY[v_size + 1]);
    v_way  := array_fill(0::int,             ARRAY[v_size + 1]);

    FOR v_i IN 1..v_size LOOP
        -- Swift's "p[0] = i" ↔ v_p[1] = v_i.
        v_p[1] := v_i;
        v_j0 := 0;
        v_minv := array_fill('Infinity'::double precision, ARRAY[v_size + 1]);
        v_used := array_fill(false, ARRAY[v_size + 1]);

        LOOP
            v_used[v_j0 + 1] := true;
            v_i0 := v_p[v_j0 + 1];
            v_delta := 'Infinity'::double precision;
            v_j1 := 0;

            FOR v_j IN 1..v_size LOOP
                IF NOT v_used[v_j + 1] THEN
                    -- cur = matrix[i0-1][j-1] - u[i0] - v[j]
                    -- Swift's matrix[i0-1][j-1] is the row-i's view of
                    -- column-j. We pre-shifted data into v_matrix[r+1][c+1],
                    -- so Swift's matrix[i0-1][j-1] ↔ v_matrix[v_i0][v_j] ↔
                    -- v_matrix[v_i0 + 1][v_j + 1] (after the +1 PL/pgSQL
                    -- shift applied here).
                    --   Swift's u[i0] (1-indexed real) ↔ v_u[v_i0 + 1]
                    --   Swift's v[j] (1-indexed real) ↔ v_v[v_j + 1]
                    DECLARE
                        v_cur double precision := v_matrix[v_i0 + 1][v_j + 1]
                                                  - v_u[v_i0 + 1]
                                                  - v_v[v_j + 1];
                    BEGIN
                        IF v_cur < v_minv[v_j + 1] THEN
                            v_minv[v_j + 1] := v_cur;
                            v_way[v_j + 1] := v_j0;
                        END IF;
                        IF v_minv[v_j + 1] < v_delta THEN
                            v_delta := v_minv[v_j + 1];
                            v_j1 := v_j;
                        END IF;
                    END;
                END IF;
            END LOOP;

            FOR v_j IN 0..v_size LOOP
                IF v_used[v_j + 1] THEN
                    v_u[v_p[v_j + 1] + 1] := v_u[v_p[v_j + 1] + 1] + v_delta;
                    v_v[v_j + 1] := v_v[v_j + 1] - v_delta;
                ELSE
                    v_minv[v_j + 1] := v_minv[v_j + 1] - v_delta;
                END IF;
            END LOOP;

            v_j0 := v_j1;
            EXIT WHEN v_p[v_j0 + 1] = 0;
        END LOOP;

        -- Augmenting path.
        LOOP
            DECLARE v_j1_local int := v_way[v_j0 + 1]; BEGIN
                v_p[v_j0 + 1] := v_p[v_j1_local + 1];
                v_j0 := v_j1_local;
            END;
            EXIT WHEN v_j0 = 0;
        END LOOP;
    END LOOP;

    -- ─── Extract the assignment ──────────────────────────────────────
    -- v_p[j+1] tells the matrix-row assigned to column j (1..size).
    -- We want, for each real row r (1..n_rows), the matrix-row that
    -- owns that column. Initialize v_assignment_for_row to -1 (sentinel
    -- at index 0), then fill: for each j in 1..size where v_p[j+1] != 0,
    -- if j is a real row, v_assignment_for_row[j] = v_p[j+1].
    v_assignment_for_row := array_fill(-1::int, ARRAY[v_n_rows + 1]);

    FOR v_j IN 1..v_size LOOP
        IF v_p[v_j + 1] != 0 AND v_j <= v_n_rows THEN
            v_assignment_for_row[v_j] := v_p[v_j + 1];
        END IF;
    END LOOP;

    -- ═════════════════════════════════════════════════════════════════
    -- 5. Emit one output row per NULL-swimmer recorded_time.
    --    Skip ghost rows: only emit for real rows (1..n_rows). For
    --    each real row, look up the assigned swimmer. If the assigned
    --    row is a real swimmer AND the cost is below the ghost
    --    threshold, the row is matched; otherwise unmatched.
    -- ═════════════════════════════════════════════════════════════════
    FOR v_i IN 1..v_n_rows LOOP
        recorded_time_id := v_rows[v_i];
        DECLARE
            v_assigned_sw int := v_assignment_for_row[v_i];
            v_assigned_is_real boolean := v_assigned_sw >= 1
                                          AND v_assigned_sw <= v_n_swimmers;
            v_assigned_cost double precision;
            v_assigned_tier text;
        BEGIN
            IF v_assigned_is_real THEN
                v_assigned_cost := v_cost[v_assigned_sw][v_i];
                v_assigned_tier := v_tier[v_assigned_sw][v_i];
            ELSE
                v_assigned_cost := 'Infinity'::double precision;
                v_assigned_tier := 'ambiguous';
            END IF;

            IF v_assigned_is_real AND v_assigned_cost < v_ghost_threshold THEN
                swimmer_id    := v_swimmers[v_assigned_sw];
                -- Gaussian confidence: exp(-cost). In (0, 1].
                confidence    := exp(-v_assigned_cost);
                fallback_tier := v_assigned_tier;
                matched       := true;
            ELSE
                swimmer_id    := NULL;
                confidence    := NULL;
                fallback_tier := 'unmatched';
                matched       := false;
            END IF;
            RETURN NEXT;
        END;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION public.pair_recorded_times_for_set(uuid) IS
  'Server-side context-keyed Hungarian pairing for NULL-swimmer recorded_times rows in a workout_set (t_2a8763a5, 2026-08-05). Builds a (swimmer × row) cost matrix where each cell is the velocity-space Gaussian cost against the swimmer''s best-context PB (exact_context → intensity_overlap → gear_inferred fallback chain), pads with dummy rows/columns for ghost/missed taps, then solves with Kuhn-Munkres. Read-only — caller UPDATEs recorded_times so the Welford trigger fires. Replaces the single-row stub from 20260805010000_pair_recorded_times_function.sql.';

GRANT EXECUTE ON FUNCTION public.pair_recorded_times_for_set(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.pair_recorded_times_for_set(uuid) TO service_role;