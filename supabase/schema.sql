-- Hydrolyze 2 — Coach App Schema
-- Run this in Supabase SQL Editor

BEGIN;

-- ──────────────────────────────────────────
-- coaches
-- One record per auth user (created on first login)
-- ──────────────────────────────────────────
CREATE TABLE coaches (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_id     uuid UNIQUE NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  name        text,
  created_at  timestamptz DEFAULT now()
);

-- ──────────────────────────────────────────
-- groups
-- Named groups of swimmers (Gold, Juniors, Sprinters, etc.)
-- ──────────────────────────────────────────
CREATE TABLE groups (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  coach_id    uuid NOT NULL REFERENCES coaches(id) ON DELETE CASCADE,
  name        text NOT NULL,
  created_at  timestamptz DEFAULT now(),
  UNIQUE (coach_id, name)
);

-- ──────────────────────────────────────────
-- swimmers
-- ──────────────────────────────────────────
CREATE TABLE swimmers (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  coach_id    uuid NOT NULL REFERENCES coaches(id) ON DELETE CASCADE,
  name        text NOT NULL,
  form_stroke text DEFAULT 'Free',
  created_at  timestamptz DEFAULT now()
);

-- ──────────────────────────────────────────
-- swimmer_groups
-- Many-to-many: a swimmer can belong to multiple groups
-- ──────────────────────────────────────────
CREATE TABLE swimmer_groups (
  swimmer_id  uuid NOT NULL REFERENCES swimmers(id) ON DELETE CASCADE,
  group_id   uuid NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  PRIMARY KEY (swimmer_id, group_id)
);

-- ──────────────────────────────────────────
-- workouts
-- ──────────────────────────────────────────
CREATE TABLE workouts (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  coach_id      uuid NOT NULL REFERENCES coaches(id) ON DELETE CASCADE,
  title         text,
  status        text NOT NULL DEFAULT 'draft'
                  CHECK (status IN ('draft', 'scheduled', 'in_progress', 'complete')),
  scheduled_at  date,
  am_pm         text CHECK (am_pm IN ('AM', 'PM')),
  session_type  text NOT NULL DEFAULT 'training'
                  CHECK (session_type IN ('training', '3mt')),
  created_at    timestamptz DEFAULT now(),
  updated_at    timestamptz DEFAULT now()
);

-- ──────────────────────────────────────────
-- workout_sets
-- Individual set components within a workout
-- ──────────────────────────────────────────
CREATE TABLE workout_sets (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workout_id            uuid NOT NULL REFERENCES workouts(id) ON DELETE CASCADE,
  order_index           integer NOT NULL,
  reps                  integer NOT NULL,
  distance              integer NOT NULL,
  stroke                text NOT NULL DEFAULT 'Free',
  intensity_type        text,
  intensity_label       text,
  pace_target_distance  integer,
  interval_text         text,
  gear                  text,
  created_at            timestamptz DEFAULT now()
);

-- ──────────────────────────────────────────
-- sessions
-- One session = one timing run (starts when coach begins timing, ends after all sets)
-- ──────────────────────────────────────────
CREATE TABLE sessions (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workout_id    uuid REFERENCES workouts(id) ON DELETE SET NULL,
  coach_id      uuid NOT NULL REFERENCES coaches(id) ON DELETE CASCADE,
  started_at    timestamptz DEFAULT now(),
  completed_at  timestamptz
);

-- ──────────────────────────────────────────
-- recorded_times
-- Individual lap times recorded during a session
-- ──────────────────────────────────────────
CREATE TABLE recorded_times (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id            uuid REFERENCES sessions(id) ON DELETE CASCADE,
  workout_id            uuid REFERENCES workouts(id) ON DELETE CASCADE,
  workout_set_id        uuid REFERENCES workout_sets(id) ON DELETE CASCADE,
  swimmer_id            uuid REFERENCES swimmers(id) ON DELETE SET NULL,
  rep_index             integer NOT NULL,
  time_ms               integer NOT NULL,
  intensity             text,
  source                text DEFAULT 'auto' CHECK (source IN ('auto', 'manual', 'unassigned')),
  assignment_confidence float,
  stroke                text,    -- snapshot: stroke at time of recording (not a FK)
  pace_distance         integer, -- snapshot: pace target distance in meters at time of recording (not a FK)

-- Indexes for stroke and pace_distance snapshot columns
CREATE INDEX idx_recorded_times_stroke ON recorded_times(stroke);
CREATE INDEX idx_recorded_times_stroke_pace ON recorded_times(stroke, pace_distance);
  created_at            timestamptz DEFAULT now()
);

-- ──────────────────────────────────────────
-- swimmer_stats
-- Rolling Welford stats per swimmer per stroke/distance/intensity/gear combo
-- ──────────────────────────────────────────
CREATE TABLE swimmer_stats (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  swimmer_id      uuid NOT NULL REFERENCES swimmers(id) ON DELETE CASCADE,
  distance        integer NOT NULL,
  set_id          integer,  -- alias for distance, used by some code paths
  stroke          text NOT NULL,
  intensity       text DEFAULT 'moderate',
  gear            text,
  mean_time_ms    float,
  stddev_time_ms  float,
  sample_count    integer DEFAULT 0,
  updated_at      timestamptz DEFAULT now(),
  UNIQUE (swimmer_id, distance, stroke, intensity, gear)
);

-- ──────────────────────────────────────────
-- swimmer_pbs
-- Personal bests per swimmer per stroke/distance/gear
-- ──────────────────────────────────────────
CREATE TABLE swimmer_pbs (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  swimmer_id  uuid NOT NULL REFERENCES swimmers(id) ON DELETE CASCADE,
  distance    integer NOT NULL,
  stroke      text NOT NULL,
  time_ms     integer NOT NULL,
  gear        text,
  recorded_at timestamptz DEFAULT now(),
  UNIQUE (swimmer_id, distance, stroke, gear)
);

-- ──────────────────────────────────────────
-- swimmer_test_profiles
-- Per-swimmer 3-minute all-out test (3MT) result rows
-- V0.38 Slice 1
-- ──────────────────────────────────────────
CREATE TABLE swimmer_test_profiles (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  swimmer_id          uuid NOT NULL REFERENCES swimmers(id) ON DELETE CASCADE,
  session_id          uuid REFERENCES sessions(id) ON DELETE SET NULL,
  workout_set_id      uuid REFERENCES workout_sets(id) ON DELETE SET NULL,
  stroke              text NOT NULL DEFAULT 'Free',
  pool_length         integer NOT NULL DEFAULT 25,
  test_date           timestamptz NOT NULL DEFAULT now(),
  trial_number        integer NOT NULL DEFAULT 1,
  peak_speed_mps      double precision NOT NULL,
  critical_speed_mps  double precision NOT NULL,
  battery_m           double precision NOT NULL,
  quality_flags       jsonb NOT NULL DEFAULT '[]',
  created_at          timestamptz DEFAULT now()
);

-- ──────────────────────────────────────────
-- swimmer_gears
-- Historical average times for gear-specific stats
-- ──────────────────────────────────────────
CREATE TABLE swimmer_gears (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  swimmer_id      uuid NOT NULL REFERENCES swimmers(id) ON DELETE CASCADE,
  gear            text NOT NULL,
  distance        integer NOT NULL,
  stroke          text NOT NULL,
  mean_time_ms    float,
  stddev_time_ms  float,
  sample_count    integer DEFAULT 0,
  updated_at      timestamptz DEFAULT now(),
  UNIQUE (swimmer_id, gear, distance, stroke)
);

-- ──────────────────────────────────────────
-- Indexes
-- ──────────────────────────────────────────
CREATE INDEX idx_swimmers_coach_id ON swimmers(coach_id);
CREATE INDEX idx_groups_coach_id ON groups(coach_id);
CREATE INDEX idx_swimmer_groups_swimmer_id ON swimmer_groups(swimmer_id);
CREATE INDEX idx_swimmer_groups_group_id ON swimmer_groups(group_id);
CREATE INDEX idx_workouts_coach_id ON workouts(coach_id);
CREATE INDEX idx_workouts_scheduled_at ON workouts(scheduled_at);
CREATE INDEX idx_workout_sets_workout_id ON workout_sets(workout_id);
CREATE INDEX idx_sessions_coach_id ON sessions(coach_id);
CREATE INDEX idx_recorded_times_session_id ON recorded_times(session_id);
CREATE INDEX idx_recorded_times_workout_set_id ON recorded_times(workout_set_id);
CREATE INDEX idx_recorded_times_swimmer_id ON recorded_times(swimmer_id);
CREATE INDEX idx_swimmer_stats_swimmer_id ON swimmer_stats(swimmer_id);
CREATE INDEX idx_swimmer_pbs_swimmer_id ON swimmer_pbs(swimmer_id);
CREATE INDEX idx_swimmer_gears_swimmer_id ON swimmer_gears(swimmer_id);
CREATE INDEX idx_test_profiles_swimmer ON swimmer_test_profiles(swimmer_id, stroke, test_date);

-- ──────────────────────────────────────────
-- RLS (Row Level Security)
-- Coaches can only see their own data
-- ──────────────────────────────────────────
ALTER TABLE coaches ENABLE ROW LEVEL SECURITY;
ALTER TABLE swimmers ENABLE ROW LEVEL SECURITY;
ALTER TABLE groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE swimmer_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE workouts ENABLE ROW LEVEL SECURITY;
ALTER TABLE workout_sets ENABLE ROW LEVEL SECURITY;
ALTER TABLE sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE recorded_times ENABLE ROW LEVEL SECURITY;
ALTER TABLE swimmer_stats ENABLE ROW LEVEL SECURITY;
ALTER TABLE swimmer_pbs ENABLE ROW LEVEL SECURITY;
ALTER TABLE swimmer_gears ENABLE ROW LEVEL SECURITY;
ALTER TABLE swimmer_test_profiles ENABLE ROW LEVEL SECURITY;

-- coaches: coach sees their own record
CREATE POLICY "coaches_select" ON coaches
  FOR SELECT USING (auth.uid() = auth_id);

-- coaches: coach can insert/update their own record
-- (trigger creates on signup; this is the fallback for manual inserts)
CREATE POLICY "coaches_insert" ON coaches
  FOR INSERT WITH CHECK (auth.uid() = auth_id);

CREATE POLICY "coaches_update" ON coaches
  FOR UPDATE USING (auth.uid() = auth_id);

-- swimmers: coach sees their own swimmers
CREATE POLICY "swimmers_select" ON swimmers
  FOR SELECT USING (coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()));
CREATE POLICY "swimmers_insert" ON swimmers
  FOR INSERT WITH CHECK (coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()));
CREATE POLICY "swimmers_update" ON swimmers
  FOR UPDATE USING (coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()));
CREATE POLICY "swimmers_delete" ON swimmers
  FOR DELETE USING (coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()));

-- groups: coach sees their own groups
CREATE POLICY "groups_select" ON groups
  FOR SELECT USING (coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()));
CREATE POLICY "groups_insert" ON groups
  FOR INSERT WITH CHECK (coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()));
CREATE POLICY "groups_update" ON groups
  FOR UPDATE USING (coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()));
CREATE POLICY "groups_delete" ON groups
  FOR DELETE USING (coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()));

-- swimmer_groups: coach sees groups their swimmers belong to
CREATE POLICY "swimmer_groups_select" ON swimmer_groups
  FOR SELECT USING (
    group_id IN (SELECT id FROM groups WHERE coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()))
  );
CREATE POLICY "swimmer_groups_insert" ON swimmer_groups
  FOR INSERT WITH CHECK (
    group_id IN (SELECT id FROM groups WHERE coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()))
  );
CREATE POLICY "swimmer_groups_delete" ON swimmer_groups
  FOR DELETE USING (
    group_id IN (SELECT id FROM groups WHERE coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()))
  );

-- workouts: coach sees their own workouts
CREATE POLICY "workouts_select" ON workouts
  FOR SELECT USING (coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()));
CREATE POLICY "workouts_insert" ON workouts
  FOR INSERT WITH CHECK (coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()));
CREATE POLICY "workouts_update" ON workouts
  FOR UPDATE USING (coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()));
CREATE POLICY "workouts_delete" ON workouts
  FOR DELETE USING (coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()));

-- workout_sets: coach sees sets from their workouts
CREATE POLICY "workout_sets_select" ON workout_sets
  FOR SELECT USING (
    workout_id IN (SELECT id FROM workouts WHERE coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()))
  );
CREATE POLICY "workout_sets_insert" ON workout_sets
  FOR INSERT WITH CHECK (
    workout_id IN (SELECT id FROM workouts WHERE coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()))
  );
CREATE POLICY "workout_sets_update" ON workout_sets
  FOR UPDATE USING (
    workout_id IN (SELECT id FROM workouts WHERE coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()))
  );
CREATE POLICY "workout_sets_delete" ON workout_sets
  FOR DELETE USING (
    workout_id IN (SELECT id FROM workouts WHERE coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()))
  );

-- sessions: coach sees their own sessions
CREATE POLICY "sessions_select" ON sessions
  FOR SELECT USING (coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()));
CREATE POLICY "sessions_insert" ON sessions
  FOR INSERT WITH CHECK (coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()));
CREATE POLICY "sessions_update" ON sessions
  FOR UPDATE USING (coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()));
CREATE POLICY "sessions_delete" ON sessions
  FOR DELETE USING (coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()));

-- recorded_times: coach sees times from their sessions
CREATE POLICY "recorded_times_select" ON recorded_times
  FOR SELECT USING (
    session_id IN (SELECT id FROM sessions WHERE coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()))
  );
CREATE POLICY "recorded_times_insert" ON recorded_times
  FOR INSERT WITH CHECK (
    session_id IN (SELECT id FROM sessions WHERE coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()))
  );
CREATE POLICY "recorded_times_update" ON recorded_times
  FOR UPDATE USING (
    session_id IN (SELECT id FROM sessions WHERE coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()))
  );
CREATE POLICY "recorded_times_delete" ON recorded_times
  FOR DELETE USING (
    session_id IN (SELECT id FROM sessions WHERE coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()))
  );

-- swimmer_stats: coach sees stats for their swimmers
CREATE POLICY "swimmer_stats_select" ON swimmer_stats
  FOR SELECT USING (
    swimmer_id IN (SELECT id FROM swimmers WHERE coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()))
  );
CREATE POLICY "swimmer_stats_insert" ON swimmer_stats
  FOR INSERT WITH CHECK (
    swimmer_id IN (SELECT id FROM swimmers WHERE coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()))
  );
CREATE POLICY "swimmer_stats_update" ON swimmer_stats
  FOR UPDATE USING (
    swimmer_id IN (SELECT id FROM swimmers WHERE coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()))
  );

-- swimmer_pbs: coach sees PBs for their swimmers
CREATE POLICY "swimmer_pbs_select" ON swimmer_pbs
  FOR SELECT USING (
    swimmer_id IN (SELECT id FROM swimmers WHERE coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()))
  );
CREATE POLICY "swimmer_pbs_insert" ON swimmer_pbs
  FOR INSERT WITH CHECK (
    swimmer_id IN (SELECT id FROM swimmers WHERE coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()))
  );
CREATE POLICY "swimmer_pbs_update" ON swimmer_pbs
  FOR UPDATE USING (
    swimmer_id IN (SELECT id FROM swimmers WHERE coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()))
  );

-- swimmer_gears: coach sees gear stats for their swimmers
CREATE POLICY "swimmer_gears_select" ON swimmer_gears
  FOR SELECT USING (
    swimmer_id IN (SELECT id FROM swimmers WHERE coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()))
  );
CREATE POLICY "swimmer_gears_insert" ON swimmer_gears
  FOR INSERT WITH CHECK (
    swimmer_id IN (SELECT id FROM swimmers WHERE coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()))
  );
CREATE POLICY "swimmer_gears_update" ON swimmer_gears
  FOR UPDATE USING (
    swimmer_id IN (SELECT id FROM swimmers WHERE coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()))
  );

-- swimmer_test_profiles: coach sees 3MT profiles for their swimmers
CREATE POLICY "swimmer_test_profiles_select" ON swimmer_test_profiles
  FOR SELECT USING (
    swimmer_id IN (SELECT id FROM swimmers WHERE coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()))
  );
CREATE POLICY "swimmer_test_profiles_insert" ON swimmer_test_profiles
  FOR INSERT WITH CHECK (
    swimmer_id IN (SELECT id FROM swimmers WHERE coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()))
  );
CREATE POLICY "swimmer_test_profiles_update" ON swimmer_test_profiles
  FOR UPDATE USING (
    swimmer_id IN (SELECT id FROM swimmers WHERE coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid()))
  );

-- swimmer_test_profiles: swimmer sees their own profile
CREATE POLICY "swimmer_own_test_profiles" ON swimmer_test_profiles
  FOR SELECT USING (
    swimmer_id IN (SELECT id FROM swimmers WHERE auth_id = auth.uid())
  );

-- ──────────────────────────────────────────
-- Auth trigger: auto-create coaches record on signup
-- ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS trigger AS $$
BEGIN
  INSERT INTO coaches (auth_id, name)
  VALUES (new.id, new.raw_user_meta_data->>'name');
  RETURN new;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();

COMMIT;
