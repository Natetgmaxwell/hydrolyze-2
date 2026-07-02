-- Drop all tables, views, functions, triggers, types, and policies
-- Run this in Supabase SQL Editor

BEGIN;

-- Drop tables in reverse dependency order (children first)
DROP TABLE IF EXISTS recorded_times CASCADE;
DROP TABLE IF EXISTS swimmer_gears CASCADE;
DROP TABLE IF EXISTS swimmer_stats CASCADE;
DROP TABLE IF EXISTS swimmer_pbs CASCADE;
DROP TABLE IF EXISTS workout_sets CASCADE;
DROP TABLE IF EXISTS workouts CASCADE;
DROP TABLE IF EXISTS swimmers CASCADE;
DROP TABLE IF EXISTS groups CASCADE;
DROP TABLE IF EXISTS swimmer_groups CASCADE;
DROP TABLE IF EXISTS sessions CASCADE;
DROP TABLE IF EXISTS coaches CASCADE;

-- Drop all views
DROP VIEW IF EXISTS swimmer_stats_view CASCADE;
DROP VIEW IF EXISTS workout_sets_view CASCADE;
DROP VIEW IF EXISTS recorded_times_view CASCADE;
DROP VIEW IF EXISTS swimmer_pbs_view CASCADE;
DROP VIEW IF EXISTS workouts_view CASCADE;
DROP VIEW IF EXISTS swimmer_gears_view CASCADE;
DROP VIEW IF EXISTS athletes_view CASCADE;

-- Drop all functions
DROP FUNCTION IF EXISTS update_swimmer_pbs() CASCADE;
DROP FUNCTION IF EXISTS update_swimmer_stats() CASCADE;
DROP FUNCTION IF EXISTS update_swimmer_gears() CASCADE;
DROP FUNCTION IF EXISTS welford_update(integer, integer, integer) CASCADE;

-- Drop all triggers
DROP TRIGGER IF EXISTS update_swimmer_pbs_on_insert ON recorded_times;
DROP TRIGGER IF EXISTS update_swimmer_stats_on_insert ON recorded_times;
DROP TRIGGER IF EXISTS update_swimmer_gears_on_insert ON recorded_times;

-- Drop all types
DROP TYPE IF EXISTS stroke_type CASCADE;
DROP TYPE IF EXISTS intensity_type CASCADE;
DROP TYPE IF EXISTS gear_type CASCADE;
DROP TYPE IF EXISTS workout_status CASCADE;

COMMIT;

-- Verify nothing remains
SELECT tablename FROM pg_tables WHERE schemaname = 'public';
