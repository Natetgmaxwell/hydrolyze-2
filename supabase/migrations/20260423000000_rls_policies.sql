-- Migration: RLS Policies for Hydrolyze
-- Phase 2, Playbook 02c
-- All tables scoped to coach ownership for multi-seat isolation

-- Enable RLS on all tables
ALTER TABLE swimmers ENABLE ROW LEVEL SECURITY;
ALTER TABLE swimmer_stats ENABLE ROW LEVEL SECURITY;
ALTER TABLE swimmer_pace_bands ENABLE ROW LEVEL SECURITY;
ALTER TABLE sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE session_swimmers ENABLE ROW LEVEL SECURITY;
ALTER TABLE swim_sets ENABLE ROW LEVEL SECURITY;
ALTER TABLE recorded_times ENABLE ROW LEVEL SECURITY;

-- swimmers: coach sees their own swimmers
-- coach_id is stored as text; cast auth.uid() (uuid) to text for comparison
CREATE POLICY "coach_own_swimmers" ON swimmers
  FOR ALL USING (coach_id = auth.uid()::text);

-- swimmer_stats: readable if coach owns the swimmer
CREATE POLICY "coach_own_swimmer_stats" ON swimmer_stats
  FOR SELECT USING (
    swimmer_id IN (SELECT id FROM swimmers WHERE coach_id = auth.uid()::text)
  );

-- swimmer_pace_bands: readable if coach owns the swimmer
CREATE POLICY "coach_own_pace_bands" ON swimmer_pace_bands
  FOR ALL USING (
    swimmer_id IN (SELECT id FROM swimmers WHERE coach_id = auth.uid()::text)
  );

-- sessions: coach owns sessions
CREATE POLICY "coach_own_sessions" ON sessions
  FOR ALL USING (coach_id = auth.uid()::text);

-- session_swimmers: through session ownership
CREATE POLICY "coach_own_session_swimmers" ON session_swimmers
  FOR ALL USING (
    session_id IN (SELECT id FROM sessions WHERE coach_id = auth.uid()::text)
  );

-- swim_sets: through session ownership
CREATE POLICY "coach_own_swim_sets" ON swim_sets
  FOR ALL USING (
    session_id IN (SELECT id FROM sessions WHERE coach_id = auth.uid()::text)
  );

-- recorded_times: through session ownership
CREATE POLICY "coach_own_recorded_times" ON recorded_times
  FOR ALL USING (
    session_id IN (SELECT id FROM sessions WHERE coach_id = auth.uid()::text)
  );
