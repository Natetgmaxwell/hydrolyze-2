-- Migration 20260425: Full workout system schema
-- Phases: 0 (core tables), 3 (gear calibration stub), 5 (wave groups stub)
-- Defer: wave support (Phase 5), per-swimmer gear calibration (Phase 3 — universal factors work for v1)

BEGIN;

-- ══════════════════════════════════════════════════════════════════════════════
-- WORKOUTS — a coach's planned pool session
-- ══════════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS workouts (
  id              uuid    NOT NULL DEFAULT gen_random_uuid(),
  coach_id        text    NOT NULL,   -- references coaches.id (no FK, avoids circular refs)
  title           text,
  description     text,
  scheduled_at    timestamptz,        -- null = unscheduled draft
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
  distance              integer,          -- metres, e.g. 100
  stroke                text,             -- Free | Back | Breast | Fly | IM | Form
  interval_text         text,             -- "1:30" stored as string for display
  intensity_type        text,             -- easy | aerobic | threshold | race_pace | pace_target | sprint | descend | build | negative_split
  pace_target_distance  integer,          -- e.g. 200 for "at 200 pace"; null for non-pace-target intensities
  intensity_label       text,             -- display label: "descend 1–3", "easy", "200 pace", etc.
  gear                  text,             -- null | paddles | pull_buoy | fins | kickboard | dragSuit
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
  -- sets_json shape: Array<{
  --   reps: number, distance: number, stroke: string,
  --   interval: string|null, intensity: {...}|null, gear: string|null
  -- }>
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id)
);

-- ══════════════════════════════════════════════════════════════════════════════
-- SWIMMER_GEARS — per-swimmer per-gear historical stats (Phase 3: calibrate)
-- Stubbed for Phase 0: coach_id + swimmer_id columns added so the table exists;
-- mean_time_ms/stddev are filled by the Welford trigger as data accumulates.
-- Phase 3: replace universal GEAR_PENALTIES with per-swimmer learned factors.
-- ══════════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS swimmer_gears (
  swimmer_id          uuid    NOT NULL REFERENCES swimmers(id) ON DELETE CASCADE,
  gear                text    NOT NULL,   -- paddles | pull_buoy | fins | kickboard | dragSuit
  mean_time_ms        float   NOT NULL DEFAULT 0,
  stddev_time_ms      float   NOT NULL DEFAULT 0,
  sample_count        integer NOT NULL DEFAULT 0,
  -- Welford accumulators (M2 = sum of squared deviations from the mean)
  m2                  float   NOT NULL DEFAULT 0,
  updated_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (swimmer_id, gear)
);

-- ══════════════════════════════════════════════════════════════════════════════
-- WAVE_GROUPS — per-lap wave corrections (Phase 5: full wave support)
-- Stubbed: stored for every lap; used only when wave_number > 1.
-- raw_tap_time_ms = what was tapped
-- corrected_time_ms = raw_tap_time_ms + (wave_number * 10s) — accounts for
--   simultaneous-start stagger. Phase 5 uses corrected_time_ms for pairing.
-- ══════════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS wave_groups (
  id                  uuid    NOT NULL DEFAULT gen_random_uuid(),
  recorded_time_id    uuid    NOT NULL REFERENCES recorded_times(id) ON DELETE CASCADE,
  wave_number         integer NOT NULL DEFAULT 1,   -- 1 = first wave, 2 = second wave, etc.
  raw_tap_time_ms     bigint  NOT NULL,
  corrected_time_ms   bigint  NOT NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id)
);

-- ══════════════════════════════════════════════════════════════════════════════
-- WORKOUT_SET_COMPLETIONS — tracks which sets have been completed in a session
-- Links a workout_set to the recorded_times from that set
-- ══════════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS workout_set_completions (
  workout_set_id          uuid    NOT NULL REFERENCES workout_sets(id) ON DELETE CASCADE,
  recorded_time_ids      jsonb   NOT NULL DEFAULT '[]',  -- array of recorded_time ids
  completed_at            timestamptz NOT NULL DEFAULT now(),
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

-- recorded_times: add gear + wave_number + workout_set_id + pace_distance
ALTER TABLE recorded_times
  ADD COLUMN IF NOT EXISTS gear            text,
  ADD COLUMN IF NOT EXISTS wave_number     integer NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS workout_set_id  uuid REFERENCES workout_sets(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS pace_distance   integer;

-- swimmers: add preferred_gear (quick-access for UI suggestions)
ALTER TABLE swimmers
  ADD COLUMN IF NOT EXISTS preferred_gear   text;

-- swim_sets: add gear + workout_id FK
ALTER TABLE swim_sets
  ADD COLUMN IF NOT EXISTS gear            text,
  ADD COLUMN IF NOT EXISTS workout_id       uuid REFERENCES workouts(id) ON DELETE SET NULL;

-- swimmer_intensity_calibrations: add gear column (extends intensity calibration to gear-specific)
ALTER TABLE swimmer_intensity_calibrations
  ADD COLUMN IF NOT EXISTS gear  text DEFAULT NULL;  -- null = no gear (baseline)

-- Make swimmer_intensity_calibrations primary key include gear (drop + recreate)
ALTER TABLE swimmer_intensity_calibrations DROP CONSTRAINT IF EXISTS swimmer_intensity_calibrations_pkey;
ALTER TABLE swimmer_intensity_calibrations
  ADD PRIMARY KEY (swimmer_id, stroke, intensity, gear);

-- ══════════════════════════════════════════════════════════════════════════════
-- RLS POLICIES
-- ══════════════════════════════════════════════════════════════════════════════

ALTER TABLE workouts                     ENABLE ROW LEVEL SECURITY;
ALTER TABLE workout_sets                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE workout_templates            ENABLE ROW LEVEL SECURITY;
ALTER TABLE swimmer_gears                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE wave_groups                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE workout_set_completions      ENABLE ROW LEVEL SECURITY;
ALTER TABLE attendance                   ENABLE ROW LEVEL SECURITY;

-- workouts: coach sees only their own
CREATE POLICY "coach_own_workouts" ON workouts
  FOR ALL USING (coach_id = auth.uid()::text);

-- workout_sets: inherit via workout FK
CREATE POLICY "coach_own_workout_sets" ON workout_sets
  FOR ALL USING (
    workout_id IN (SELECT id FROM workouts WHERE coach_id = auth.uid()::text)
  );

-- workout_templates: coach's own library
CREATE POLICY "coach_own_templates" ON workout_templates
  FOR ALL USING (coach_id = auth.uid()::text);

-- swimmer_gears: coach sees swimmers they own
CREATE POLICY "coach_own_swimmer_gears" ON swimmer_gears
  FOR ALL USING (
    swimmer_id IN (SELECT id FROM swimmers WHERE coach_id = auth.uid()::text)
  );

-- wave_groups: via recorded_times
CREATE POLICY "coach_own_wave_groups" ON wave_groups
  FOR ALL USING (
    recorded_time_id IN (SELECT id FROM recorded_times WHERE swimmer_id IN
      (SELECT id FROM swimmers WHERE coach_id = auth.uid()::text))
  );

-- workout_set_completions: via workout_sets
CREATE POLICY "coach_own_set_completions" ON workout_set_completions
  FOR ALL USING (
    workout_set_id IN (
      SELECT ws.id FROM workout_sets ws
      JOIN workouts w ON w.id = ws.workout_id
      WHERE w.coach_id = auth.uid()::text
    )
  );

-- attendance: via workouts
CREATE POLICY "coach_own_attendance" ON attendance
  FOR ALL USING (
    workout_id IN (SELECT id FROM workouts WHERE coach_id = auth.uid()::text)
  );

COMMIT;