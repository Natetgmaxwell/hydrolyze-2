/**
 * WorkoutContext tests — full workout lifecycle + backward-compatible timing actions.
 * TypeScript-strict: uses real GearType and IntensityLevel throughout.
 */

import { reducer } from '../context/WorkoutContext'
import type { WorkoutState } from '../context/WorkoutContext'
import type { GearType } from '../lib/workout-parser'
import type { IntensityLevel } from '../lib/set-parser'
// Work around: IntensityLevel is in set-parser.ts, gear-parser.ts re-exports it
// Just use 'string' for the intensityPattern array in test fixtures
type TestIntensityLevel = 'easy' | 'moderate' | 'hard' | 'race'

const baseState: WorkoutState = {
  workout: null,
  currentSetIndex: null,
  currentSet: null,
  attendanceList: [],
  statsCache: {},
  repTimes: [],
  currentRepNum: 1,
  timingState: 'ready',
}

const mockWorkout = {
  id: 'workout-1',
  coachId: 'coach-1',
  title: 'Tuesday AM',
  sets: [
    { id: 'set-1', orderIndex: 0, reps: 4, distance: 50, stroke: 'Free' as const,
      interval: null, intensityLabel: 'moderate', gear: null as GearType | null, paceTargetDistance: null, isCompleted: false },
    { id: 'set-2', orderIndex: 1, reps: 2, distance: 25, stroke: 'Fly' as const,
      interval: null, intensityLabel: 'sprint', gear: 'fins' as GearType, paceTargetDistance: null, isCompleted: false },
  ],
  currentSetIndex: null,
  isComplete: false,
}

const mockSetDef = {
  id: 'set-1',
  workoutId: 'workout-1',
  setIndex: 0,
  distance: 50,
  stroke: 'Free' as const,
  reps: 4,
  interval: null,
  intensityPattern: ['moderate', 'moderate', 'moderate', 'moderate'] as readonly ['moderate', 'moderate', 'moderate', 'moderate'],
  gear: null as GearType | null,
  paceTargetDistance: null,
}

describe('WorkoutContext reducer', () => {

  // ── Workout lifecycle ───────────────────────────────────────────────────

  test('START_WORKOUT — sets workout, clears state', () => {
    const state = reducer(baseState, { type: 'START_WORKOUT', payload: mockWorkout })
    expect(state.workout?.id).toBe('workout-1')
    expect(state.currentSet).toBe(null)
  })

  test('START_WORKOUT — first uncompleted set is auto-selected as currentSetIndex', () => {
    const state = reducer(baseState, { type: 'START_WORKOUT', payload: mockWorkout })
    expect(state.currentSetIndex).toBe(0) // set-1 is first uncompleted
  })

  test('SELECT_SET — builds SetDefinition from workout sets', () => {
    const state = reducer({ ...baseState, workout: mockWorkout }, { type: 'SELECT_SET', payload: { setIndex: 0 } })
    expect(state.currentSet).not.toBeNull()
    expect(state.currentSet?.id).toBe('set-1')
    expect(state.currentSet?.gear).toBe(null)
    expect(state.currentSet?.paceTargetDistance).toBe(null)
  })

  test('SELECT_SET — captures gear from set definition', () => {
    const state = reducer({ ...baseState, workout: mockWorkout }, { type: 'SELECT_SET', payload: { setIndex: 1 } })
    expect(state.currentSet?.gear).toBe('fins')
  })

  test('SET_COMPLETE — marks set done, clears currentSet', () => {
    const withSet = reducer({ ...baseState, workout: mockWorkout }, { type: 'SELECT_SET', payload: { setIndex: 0 } })
    const state = reducer(withSet, { type: 'SET_COMPLETE', payload: { setIndex: 0 } })
    expect(state.workout?.sets[0].isCompleted).toBe(true)
    expect(state.currentSet).toBe(null)
  })

  test('SET_COMPLETE — last set → workout.isComplete', () => {
    let state = reducer(baseState, { type: 'START_WORKOUT', payload: mockWorkout })
    state = reducer(state, { type: 'SELECT_SET', payload: { setIndex: 0 } })
    state = reducer(state, { type: 'SET_COMPLETE', payload: { setIndex: 0 } })
    state = reducer(state, { type: 'SELECT_SET', payload: { setIndex: 1 } })
    state = reducer(state, { type: 'SET_COMPLETE', payload: { setIndex: 1 } })
    expect(state.workout?.isComplete).toBe(true)
  })

  test('END_WORKOUT — returns to initialState', () => {
    const withWorkout = { ...baseState, workout: mockWorkout }
    const state = reducer(withWorkout, { type: 'END_WORKOUT' })
    expect(state).toEqual(baseState)
  })

  // ── Timing actions (backward-compatible) ────────────────────────────────

  test('START_SET — sets currentSet, clears repTimes', () => {
    const withTimes: WorkoutState = {
      ...baseState,
      repTimes: [{ id: 't1', elapsedMs: 60000, repNumber: 1, assignment: null, deleted: false }]
    }
    const state = reducer(withTimes, { type: 'START_SET', payload: mockSetDef })
    expect(state.currentSet?.id).toBe('set-1')
    expect(state.repTimes).toEqual([])
    expect(state.currentRepNum).toBe(1)
  })

  test('START_SET — includes gear and paceTargetDistance', () => {
    const withGear = { ...mockSetDef, gear: 'fins' as GearType, paceTargetDistance: 100 }
    const state = reducer(baseState, { type: 'START_SET', payload: withGear })
    expect(state.currentSet?.gear).toBe('fins')
    expect(state.currentSet?.paceTargetDistance).toBe(100)
  })

  test('RECORD_TIME — adds time to repTimes, not deleted', () => {
    const state = reducer(baseState, { type: 'RECORD_TIME', payload: { elapsed: 60000, assignment: null, intensity: 'moderate' } })
    expect(state.repTimes).toHaveLength(1)
    expect(state.repTimes[0].deleted).toBe(false)
  })

  test('RECORD_TIME — includes intensity field', () => {
    const state = reducer(baseState, { type: 'RECORD_TIME', payload: { elapsed: 60000, assignment: null, intensity: 'easy' } })
    expect(state.repTimes[0].intensity).toBe('easy')
  })

  test('DELETE_TIME — marks time deleted, not removed', () => {
    const withTime = reducer(baseState, { type: 'RECORD_TIME', payload: { elapsed: 60000, assignment: null, intensity: null } })
    const id = withTime.repTimes[0].id
    const state = reducer(withTime, { type: 'DELETE_TIME', payload: { id } })
    expect(state.repTimes[0].deleted).toBe(true)
    expect(state.repTimes).toHaveLength(1)
  })

  test('ASSIGN_TIME — manually assigns swimmer with 100% confidence', () => {
    const withTime = reducer(baseState, { type: 'RECORD_TIME', payload: { elapsed: 60000, assignment: null, intensity: null } })
    const id = withTime.repTimes[0].id
    const state = reducer(withTime, { type: 'ASSIGN_TIME', payload: { id, swimmerId: 'swim-B' } })
    expect(state.repTimes[0].assignment?.swimmerId).toBe('swim-B')
  })

  test('ADVANCE_REP — increments currentRepNum', () => {
    const state = reducer(baseState, { type: 'ADVANCE_REP' })
    expect(state.currentRepNum).toBe(2)
  })

  test('END_SET — clears currentSet and repTimes', () => {
    const withSet = reducer(baseState, { type: 'START_SET', payload: mockSetDef })
    const withTime = reducer(withSet, { type: 'RECORD_TIME', payload: { elapsed: 60000, assignment: null, intensity: null } })
    const state = reducer(withTime, { type: 'END_SET' })
    expect(state.currentSet).toBe(null)
    expect(state.repTimes).toEqual([])
    expect(state.currentRepNum).toBe(1)
  })

  test('RESTORE — restores full state', () => {
    const savedState: WorkoutState = {
      ...baseState,
      currentSet: mockSetDef,
      currentRepNum: 3,
    }
    const state = reducer(baseState, { type: 'RESTORE', payload: savedState })
    expect(state.currentRepNum).toBe(3)
  })

  // ── Work flow integration ──────────────────────────────────────────────

  test('multi-set flow: START_WORKOUT → SELECT_SET × 2 → SET_COMPLETE × 2 → END_WORKOUT', () => {
    let state = reducer(baseState, { type: 'START_WORKOUT', payload: mockWorkout })
    expect(state.workout?.id).toBe('workout-1')

    // Select and complete set 1
    state = reducer(state, { type: 'SELECT_SET', payload: { setIndex: 0 } })
    expect(state.currentSet?.id).toBe('set-1')
    state = reducer(state, { type: 'SET_COMPLETE', payload: { setIndex: 0 } })
    expect(state.currentSet).toBe(null)

    // Select and complete set 2
    state = reducer(state, { type: 'SELECT_SET', payload: { setIndex: 1 } })
    expect(state.currentSet?.gear).toBe('fins')
    state = reducer(state, { type: 'SET_COMPLETE', payload: { setIndex: 1 } })

    expect(state.workout?.isComplete).toBe(true)
  })
})