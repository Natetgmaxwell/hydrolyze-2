-- Migration: make set_rest_events.session_id nullable — V0.39 Slice 4 follow-up
--
-- Timestamp: 2026-08-18 13:40
-- Author: build profile (V0.39, drop rule)
--
-- WHY THIS MIGRATION EXISTS
-- The single-swimmer timing flow (the primary drop-rule path) writes
-- recorded_times with session_id = nil — a single swimmer has no
-- group session (recorded_times.session_id is nullable for exactly
-- this reason). Slice 4's save hook mirrors that: a single-swimmer
-- drop-rule event is persisted with session_id = nil and only
-- workout_set_id populated. But set_rest_events declared session_id
-- NOT NULL, so the very path that produces the most rest events
-- would fail its insert. This migration makes session_id nullable,
-- matching the recorded_times precedent.
--
-- One additive (relaxation) change, idempotent, no destructive ops.

ALTER TABLE set_rest_events
  ALTER COLUMN session_id DROP NOT NULL;
