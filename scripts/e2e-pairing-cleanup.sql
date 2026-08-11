-- e2e-pairing-cleanup.sql — removes all E2E fixture rows (idempotent).
-- Run after e2e-pairing-75-fast.sql to leave zero residue.

DO $$
DECLARE
  v_ids uuid[];
BEGIN
  -- recorded_times for E2E sets
  DELETE FROM recorded_times
   WHERE workout_set_id IN (
     SELECT ws.id FROM workout_sets ws
      JOIN workouts w ON w.id = ws.workout_id
     WHERE w.title = 'E2E Parser Pairing'
   );

  -- swimmer_pbs for E2E swimmers
  DELETE FROM swimmer_pbs
   WHERE swimmer_id IN (SELECT id FROM swimmers WHERE name LIKE 'E2E %');

  -- workout_sets + workouts
  DELETE FROM workout_sets
   WHERE workout_id IN (SELECT id FROM workouts WHERE title = 'E2E Parser Pairing');
  DELETE FROM workouts WHERE title = 'E2E Parser Pairing';

  -- swimmers
  DELETE FROM swimmers WHERE name LIKE 'E2E %';

  RAISE NOTICE 'E2E fixtures cleaned (idempotent)';
END $$;
