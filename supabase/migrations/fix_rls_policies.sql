BEGIN;

-- 1. Fix session_roster policy
-- The old policy incorrectly compared auth.uid() directly to coaches.id
DROP POLICY IF EXISTS session_roster_coach_policy ON session_roster;

CREATE POLICY session_roster_coach_policy ON session_roster
    FOR ALL USING (
        session_id IN (
            SELECT id FROM sessions WHERE coach_id IN (
                SELECT id FROM coaches WHERE auth_id = auth.uid()
            )
        )
    );

-- 2. Fix wave_assignments policy
-- The old policy incorrectly compared auth.uid() directly to coaches.id
DROP POLICY IF EXISTS wave_assignments_coach_policy ON wave_assignments;

CREATE POLICY wave_assignments_coach_policy ON wave_assignments
    FOR ALL USING (
        coach_id IN (SELECT id FROM coaches WHERE auth_id = auth.uid())
    );

COMMIT;
