-- Migration: Disable RLS on workout_sets and workout_templates for pre-auth dev
-- Also verify recorded_times has the intensity column (migration 0000 may have been missed)
BEGIN;

-- workout_sets RLS
DO $$
DECLARE pol text;
BEGIN
  FOR pol IN SELECT policyname FROM pg_policies WHERE tablename = 'workout_sets' LOOP
    EXECUTE 'DROP POLICY IF EXISTS ' || pol || ' ON workout_sets';
  END LOOP;
END $$;
ALTER TABLE workout_sets DISABLE ROW LEVEL SECURITY;

-- workout_templates RLS
DO $$
DECLARE pol text;
BEGIN
  FOR pol IN SELECT policyname FROM pg_policies WHERE tablename = 'workout_templates' LOOP
    EXECUTE 'DROP POLICY IF EXISTS ' || pol || ' ON workout_templates';
  END LOOP;
END $$;
ALTER TABLE workout_templates DISABLE ROW LEVEL SECURITY;

-- swimmer_gears RLS
DO $$
DECLARE pol text;
BEGIN
  FOR pol IN SELECT policyname FROM pg_policies WHERE tablename = 'swimmer_gears' LOOP
    EXECUTE 'DROP POLICY IF EXISTS ' || pol || ' ON swimmer_gears';
  END LOOP;
END $$;
ALTER TABLE swimmer_gears DISABLE ROW LEVEL SECURITY;

-- recorded_times: add missing intensity column if not present
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'recorded_times' AND column_name = 'intensity'
  ) THEN
    ALTER TABLE recorded_times ADD COLUMN intensity text;
  END IF;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'intensity column skip: %', SQLERRM;
END $$;

COMMIT;