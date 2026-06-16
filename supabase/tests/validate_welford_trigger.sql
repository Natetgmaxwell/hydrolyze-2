-- Welford Trigger Validation Tests
-- Run these in Supabase SQL editor or via psql after fixtures are inserted.
-- All 5 tests must pass before Phase 3 begins.
--
-- STEP 1: Insert test fixtures (replace 'your-coach-id' with a real auth.users id)

INSERT INTO swimmers (id, name, coach_id, form_stroke)
  VALUES
    ('test-swimmer-1', 'Test Alice', 'your-coach-id', 'Free'),
    ('test-swimmer-2', 'Test Bob',   'your-coach-id', 'Back')
  ON CONFLICT (id) DO NOTHING;

INSERT INTO sessions (id, coach_id, name)
  VALUES ('test-session', 'your-coach-id', 'Trigger Test Session')
  ON CONFLICT (id) DO NOTHING;

INSERT INTO swim_sets (id, session_id, description, reps, distance, stroke)
  VALUES
    ('test-set-free', 'test-session', '4x50 Free', 4, 50, 'Free'),
    ('test-set-im',   'test-session', '1x100 IM',  1, 100, 'IM'),
    ('test-set-form', 'test-session', '4x50 Form', 4, 50, 'Form')
  ON CONFLICT (id) DO NOTHING;

-- STEP 2: Run tests

-- Test A: First insert — stats row created
INSERT INTO recorded_times (swimmer_id, swim_set_id, session_id, lap_time_ms, rep_number, created_at)
  VALUES ('test-swimmer-1', 'test-set-free', 'test-session', 60000, 1, now());

SELECT
  mean_time_ms,
  stddev_time_ms,
  sample_count,
  CASE
    WHEN mean_time_ms = 60000 AND stddev_time_ms = 0 AND sample_count = 1
    THEN 'PASS'
    ELSE 'FAIL'
  END AS test_a_result
FROM swimmer_stats
WHERE swimmer_id = 'test-swimmer-1' AND stroke = 'Free';
-- Expected: mean=60000, stddev=0, sample_count=1

-- Test B: Second insert — Welford incremental update
INSERT INTO recorded_times (swimmer_id, swim_set_id, session_id, lap_time_ms, rep_number, created_at)
  VALUES ('test-swimmer-1', 'test-set-free', 'test-session', 62000, 2, now());

SELECT
  mean_time_ms,
  round(stddev_time_ms) AS stddev_rounded,
  sample_count,
  CASE
    WHEN mean_time_ms = 61000 AND sample_count = 2 AND stddev_time_ms > 900 AND stddev_time_ms < 1100
    THEN 'PASS'
    ELSE 'FAIL'
  END AS test_b_result
FROM swimmer_stats
WHERE swimmer_id = 'test-swimmer-1' AND stroke = 'Free';
-- Expected: mean=61000, stddev≈1000, sample_count=2

-- Test C: IM insert — Free stats unchanged
INSERT INTO recorded_times (swimmer_id, swim_set_id, session_id, lap_time_ms, rep_number, created_at)
  VALUES ('test-swimmer-1', 'test-set-im', 'test-session', 95000, 1, now());

SELECT
  sample_count,
  CASE WHEN sample_count = 2 THEN 'PASS' ELSE 'FAIL' END AS test_c_result
FROM swimmer_stats
WHERE swimmer_id = 'test-swimmer-1' AND stroke = 'Free';
-- Expected: still 2 (IM insert should not affect Free stats)

-- Test D: IM insert with null form_stroke — no bad row created
UPDATE swimmers SET form_stroke = NULL WHERE id = 'test-swimmer-2';

INSERT INTO recorded_times (swimmer_id, swim_set_id, session_id, lap_time_ms, rep_number, created_at)
  VALUES ('test-swimmer-2', 'test-set-im', 'test-session', 95000, 1, now());

SELECT
  count(*) AS row_count,
  CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS test_d_result
FROM swimmer_stats
WHERE swimmer_id = 'test-swimmer-2';
-- Expected: 0 rows (null form_stroke + IM = no stats row)

-- Test E: Form set — resolves to form_stroke (Back), not literal 'Form'
UPDATE swimmers SET form_stroke = 'Back' WHERE id = 'test-swimmer-2';

INSERT INTO recorded_times (swimmer_id, swim_set_id, session_id, lap_time_ms, rep_number, created_at)
  VALUES ('test-swimmer-2', 'test-set-form', 'test-session', 65000, 1, now());

SELECT
  stroke,
  mean_time_ms,
  sample_count,
  CASE
    WHEN stroke = 'Back' AND mean_time_ms = 65000 AND sample_count = 1
    THEN 'PASS'
    ELSE 'FAIL'
  END AS test_e_result
FROM swimmer_stats
WHERE swimmer_id = 'test-swimmer-2';
-- Expected: stroke='Back', mean=65000, sample_count=1

-- STEP 3: Clean up test fixtures (run after all tests pass)
-- DELETE FROM recorded_times WHERE session_id = 'test-session';
-- DELETE FROM swim_sets WHERE session_id = 'test-session';
-- DELETE FROM sessions WHERE id = 'test-session';
-- DELETE FROM swimmer_stats WHERE swimmer_id IN ('test-swimmer-1', 'test-swimmer-2');
-- DELETE FROM swimmers WHERE id IN ('test-swimmer-1', 'test-swimmer-2');
