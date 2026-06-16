-- Migration: Catch up from partial failure of 20260425000001
-- The previous migration failed partway through. This migration is idempotent:
-- checks IF EXISTS before every CREATE/ALTER so it's safe to run on any state.
--
-- Re-creates all 5 new tables that were supposed to be in 20260425000001:
--   workouts, workout_sets, workout_templates, swimmer_gears, wave_groups
-- Plus the extend-ALTERs and RLS policies.
-- Remote: 20260423000000 ✓, 20260425000000 ✓ (applied separately), migration history shows 0001 as applied but tables are missing

BEGIN;

-- ══════════════════════════════════════════════════════════════════════════════
-- WORKOUTS — a coach's planned pool session
-- ══════════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS workouts (
  id              uuid    NOT NULL DEFAULT gen_random_uuid(),
  coach_id        text    NOT NULL,
  title           text,
  description     text,
  scheduled_at    timestamptz,
  am_pm           text    CHECK (am_pm IN ('AM', 'PM')),
  completed_at    timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id)
);

-- ══════════════════════════════════════════════════════════════════════════════
-- WORKOUT_SETS — ordered set components within a workout
-- ══════════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS workout_sets (
  id                    uuid    NOT NULL DEFAULT gen_random_uuid(),
  workout_id            uuid    NOT NULL REFERENCES workouts(id) ON DELETE CASCADE,
  order_index           integer NOT NULL DEFAULT 0,
  reps                  integer,
  distance              integer,
  stroke                text,
  interval_text         text,
  intensity_type        text,
  pace_target_distance  integer,
  intensity_label       text,
  gear                  text,
  sort_order            integer NOT NULL DEFAULT 0,
  is_completed          boolean NOT NULL DEFAULT false,
  created_at            timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id)
);

-- ══════════════════════════════════════════════════════════════════════════════
-- WORKOUT_TEMPLATES — personal library of reusable workouts
-- ══════════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS workout_templates (
  id              uuid    NOT NULL DEFAULT gen_random_uuid(),
  coach_id        text    NOT NULL,
  name            text    NOT NULL,
  sets_json       jsonb   NOT NULL DEFAULT '[]',
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id)
);

-- ══════════════════════════════════════════════════════════════════════════════
-- SWIMMER_GEARS — per-swimmer per-gear historical stats (Phase 3: calibrate)
-- Stubbed for Phase 0: filled by the Welford trigger as data accumulates.
-- ══════════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS swimmer_gears (
  swimmer_id          uuid    NOT NULL REFERENCES swimmers(id) ON DELETE CASCADE,
  gear                text    NOT NULL,
  mean_time_ms        float   NOT NULL DEFAULT 0,
  stddev_time_ms      float   NOT NULL DEFAULT 0,
  sample_count        integer NOT NULL DEFAULT 0,
  m2                  float   NOT NULL DEFAULT 0,
  updated_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (swimmer_id, gear)
);

-- ══════════════════════════════════════════════════════════════════════════════
-- WAVE_GROUPS — per-lap wave corrections (Phase 5)
-- Stubbed: stored for every lap; used only when wave_number > 1.
-- raw_tap_time_ms = what was tapped
-- corrected_time_ms = raw_tap_time_ms + (wave_number * 10s)
-- ══════════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS wave_groups (
  id                  uuid    NOT NULL DEFAULT gen_random_uuid(),
  recorded_time_id    uuid    NOT NULL REFERENCES recorded_times(id) ON DELETE CASCADE,
  wave_number         integer NOT NULL DEFAULT 1,
  raw_tap_time_ms     bigint  NOT NULL,
  corrected_time_ms   bigint  NOT NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id)
);

-- ══════════════════════════════════════════════════════════════════════════════
-- WORKOUT_SET_COMPLETIONS — tracks which sets have been completed
-- ══════════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS workout_set_completions (
  workout_set_id    uuid NOT NULL REFERENCES workout_sets(id) ON DELETE CASCADE,
  recorded_time_ids  jsonb NOT NULL DEFAULT '[]',
  completed_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (workout_set_id)
);

-- ══════════════════════════════════════════════════════════════════════════════
-- ATTENDANCE — marks swimmers present for a specific workout
-- ══════════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS attendance (
  workout_id  uuid NOT NULL REFERENCES workouts(id) ON DELETE CASCADE,
  swimmer_id   uuid NOT NULL REFERENCES swimmers(id) ON DELETE CASCADE,
  present     boolean NOT NULL DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (workout_id, swimmer_id)
);

-- ══════════════════════════════════════════════════════════════════════════════
-- EXTEND EXISTING TABLES
-- ══════════════════════════════════════════════════════════════════════════════

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name = 'recorded_times' AND column_name = 'gear') THEN
    ALTER TABLE recorded_times ADD COLUMN gear text;
  END IF;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'recorded_times.gear skipped: %', SQLERRM;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name = 'recorded_times' AND column_name = 'wave_number') THEN
    ALTER TABLE recorded_times ADD COLUMN wave_number integer NOT NULL DEFAULT 1;
  END IF;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'recorded_times.wave_number skipped: %', SQLERRM;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name = 'recorded_times' AND column_name = 'workout_set_id') THEN
    ALTER TABLE recorded_times ADD COLUMN workout_set_id uuid REFERENCES workout_sets(id) ON DELETE SET NULL;
  END IF;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'recorded_times.workout_set_id skipped: %', SQLERRM;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name = 'recorded_times' AND column_name = 'pace_distance') THEN
    ALTER TABLE recorded_times ADD COLUMN pace_distance integer;
  END IF;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'recorded_times.pace_distance skipped: %', SQLERRM;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name = 'swimmers' AND column_name = 'preferred_gear') THEN
    ALTER TABLE swimmers ADD COLUMN preferred_gear text;
  END IF;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'swimmers.preferred_gear skipped: %', SQLERRM;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name = 'swim_sets' AND column_name = 'gear') THEN
    ALTER TABLE swim_sets ADD COLUMN gear text;
  END IF;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'swim_sets.gear skipped: %', SQLERRM;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name = 'swim_sets' AND column_name = 'workout_id') THEN
    ALTER TABLE swim_sets ADD COLUMN workout_id uuid REFERENCES workouts(id) ON DELETE SET NULL;
  END IF;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'swim_sets.workout_id skipped: %', SQLERRM;
END $$;

-- swimmer_intensity_calibrations: create or extend with gear column
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'swimmer_intensity_calibrations') THEN
    CREATE TABLE swimmer_intensity_calibrations (
      swimmer_id       uuid    NOT NULL REFERENCES swimmers(id) ON DELETE CASCADE,
      stroke           text    NOT NULL,
      intensity        text    NOT NULL,
      gear             text    DEFAULT NULL,
      multiplier_mean  float   NOT NULL DEFAULT 1.0,
      multiplier_m2    float   NOT NULL DEFAULT 0.0,
      sample_count     integer NOT NULL DEFAULT 0,
      updated_at       timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (swimmer_id, stroke, intensity, gear)
    );
  ELSE
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_name = 'swimmer_intensity_calibrations' AND column_name = 'gear') THEN
      ALTER TABLE swimmer_intensity_calibrations ADD COLUMN gear text DEFAULT NULL;
    END IF;
    -- Drop FK (not supported in PK for this table) and update PK to include gear
    ALTER TABLE swimmer_intensity_calibrations
      DROP CONSTRAINT IF EXISTS swimmer_intensity_calibrations_pkey;
    ALTER TABLE swimmer_intensity_calibrations
      ADD PRIMARY KEY (swimmer_id, stroke, intensity, gear);
  END IF;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'swimmer_intensity_calibrations skipped: %', SQLERRM;
END $$;

-- ══════════════════════════════════════════════════════════════════════════════
-- RLS POLICIES
-- ══════════════════════════════════════════════════════════════════════════════

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'workouts' AND policyname = 'coach_own_workouts') THEN
    ALTER TABLE workouts ENABLE ROW LEVEL SECURITY;
    CREATE POLICY "coach_own_workouts" ON workouts FOR ALL USING (coach_id = auth.uid()::text);
  END IF;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'workouts RLS skipped: %', SQLERRM;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'workout_sets' AND policyname = 'coach_own_workout_sets') THEN
    ALTER TABLE workout_sets ENABLE ROW LEVEL SECURITY;
    CREATE POLICY "coach_own_workout_sets" ON workout_sets FOR ALL USING (
      workout_id IN (SELECT id FROM workouts WHERE coach_id = auth.uid()::text)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'workout_sets RLS skipped: %', SQLERRM;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'workout_templates' AND policyname = 'coach_own_templates') THEN
    ALTER TABLE workout_templates ENABLE ROW LEVEL SECURITY;
    CREATE POLICY "coach_own_templates" ON workout_templates FOR ALL USING (coach_id = auth.uid()::text);
  END IF;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'workout_templates RLS skipped: %', SQLERRM;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'swimmer_gears' AND policyname = 'coach_own_swimmer_gears') THEN
    ALTER TABLE swimmer_gears ENABLE ROW LEVEL SECURITY;
    CREATE POLICY "coach_own_swimmer_gears" ON swimmer_gears FOR ALL USING (
      swimmer_id IN (SELECT id FROM swimmers WHERE coach_id = auth.uid()::text)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'swimmer_gears RLS skipped: %', SQLERRM;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'wave_groups' AND policyname = 'coach_own_wave_groups') THEN
    ALTER TABLE wave_groups ENABLE ROW LEVEL SECURITY;
    CREATE POLICY "coach_own_wave_groups" ON wave_groups FOR ALL USING (
      recorded_time_id IN (
        SELECT id FROM recorded_times WHERE swimmer_id IN
        (SELECT id FROM swimmers WHERE coach_id = auth.uid()::text)
      )
    );
  END IF;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'wave_groups RLS skipped: %', SQLERRM;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'workout_set_completions' AND policyname = 'coach_own_set_completions') THEN
    ALTER TABLE workout_set_completions ENABLE ROW LEVEL SECURITY;
    CREATE POLICY "coach_own_set_completions" ON workout_set_completions FOR ALL USING (
      workout_set_id IN (
        SELECT ws.id FROM workout_sets ws
        JOIN workouts w ON w.id = ws.workout_id WHERE w.coach_id = auth.uid()::text
      )
    );
  END IF;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'workout_set_completions RLS skipped: %', SQLERRM;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'attendance' AND policyname = 'coach_own_attendance') THEN
    ALTER TABLE attendance ENABLE ROW LEVEL SECURITY;
    CREATE POLICY "coach_own_attendance" ON attendance FOR ALL USING (
      workout_id IN (SELECT id FROM workouts WHERE coach_id = auth.uid()::text)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'attendance RLS skipped: %', SQLERRM;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'swimmer_intensity_calibrations' AND policyname = 'coach_own_intensity_calibrations') THEN
    ALTER TABLE swimmer_intensity_calibrations ENABLE ROW LEVEL SECURITY;
    CREATE POLICY "coach_own_intensity_calibrations" ON swimmer_intensity_calibrations FOR ALL USING (
      swimmer_id IN (SELECT id FROM swimmers WHERE coach_id = auth.uid()::text)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'swimmer_intensity_calibrations RLS skipped: %', SQLERRM;
END $$;

COMMIT;