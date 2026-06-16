/**
 * SessionContext tests — migrated to WorkoutContext reducer.
 *
 * These tests verify that the WorkoutContext reducer correctly handles
 * the SessionContext action types (START_SET, RECORD_TIME, DELETE_TIME,
 * ASSIGN_TIME, ADVANCE_REP, END_SET) that are used by the existing
 * timing screens.
 *
 * The state shape has changed:
 *   Old: { setDefinition, attendanceList, statsCache, repTimes, currentRepNum }
 *   New: { workout, currentSet, attendanceList, statsCache, repTimes, currentRepNum, timingState }
 *
 * The behavior is the same — only the field names have changed.
 */

import { reducer } from '../context/WorkoutContext'
import type { WorkoutState, WorkoutAction } from '../context/WorkoutContext'

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

const mockSetDef = {
  id: 'set-1',
  workoutId: 'workout-1',
  setIndex: 0,
  distance: 50,
  stroke: 'Free' as const,
  reps: 4,
  interval: null,
  intensityPattern: ['moderate', 'moderate', 'moderate', 'moderate'] as const,
  gear: null,
  paceTargetDistance: null,
}

describe('SessionContext actions (via WorkoutContext reducer)', () => {

  test('START_SET — clears state and sets currentSet', () => {
    const state = reducer(
      { ...baseState, currentRepNum: 3, timingState: 'rep_done' as const },
      { type: 'START_SET', payload: mockSetDef }
    )
    expect(state.currentSet).toEqual(mockSetDef)
    expect(state.repTimes).toEqual([])
    expect(state.currentRepNum).toBe(1)
    expect(state.timingState).toBe('ready')
  })

  test('START_SET — includes gear and paceTargetDistance from payload', () => {
    const withGear = {
      ...mockSetDef,
      gear: 'fins' as const,
      paceTargetDistance: 200,
    }
    const state = reducer(baseState, { type: 'START_SET', payload: withGear })
    expect(state.currentSet?.gear).toBe('fins')
    expect(state.currentSet?.paceTargetDistance).toBe(200)
  })

  test('RECORD_TIME — adds time to repTimes, not deleted', () => {
    const assignment = { swimmerId: 'A', source: 'recorded' as const, errorMs: 0, sampleCount: 5 }
    const state = reducer(baseState, {
      type: 'RECORD_TIME',
      payload: { elapsed: 60000, assignment, intensity: 'moderate' },
    })
    expect(state.repTimes).toHaveLength(1)
    expect(state.repTimes[0].deleted).toBe(false)
    expect(state.repTimes[0].assignment?.swimmerId).toBe('A')
    expect(state.repTimes[0].intensity).toBe('moderate')
  })

  test('DELETE_TIME — marks time deleted, not removed', () => {
    const withTime = reducer(baseState, {
      type: 'RECORD_TIME',
      payload: { elapsed: 60000, assignment: null, intensity: null },
    })
    const id = withTime.repTimes[0].id
    const state = reducer(withTime, { type: 'DELETE_TIME', payload: { id } })
    expect(state.repTimes[0].deleted).toBe(true)
    expect(state.repTimes).toHaveLength(1) // still in array
  })

  test('ASSIGN_TIME — manually assigns swimmer with 100% confidence', () => {
    const withTime = reducer(baseState, {
      type: 'RECORD_TIME',
      payload: { elapsed: 60000, assignment: null, intensity: null },
    })
    const id = withTime.repTimes[0].id
    const state = reducer(withTime, {
      type: 'ASSIGN_TIME',
      payload: { id, swimmerId: 'B' },
    })
    expect(state.repTimes[0].assignment?.swimmerId).toBe('B')
  })

  test('ADVANCE_REP — increments currentRepNum', () => {
    const state = reducer(baseState, { type: 'ADVANCE_REP' })
    expect(state.currentRepNum).toBe(2)
  })

  test('END_SET — clears currentSet and repTimes', () => {
    const withSet = reducer(baseState, { type: 'START_SET', payload: mockSetDef })
    const withTime = reducer(withSet, {
      type: 'RECORD_TIME',
      payload: { elapsed: 60000, assignment: null, intensity: null },
    })
    const state = reducer(withTime, { type: 'END_SET' })
    expect(state.currentSet).toBe(null)
    expect(state.repTimes).toEqual([])
    expect(state.currentRepNum).toBe(1)
  })

  test('syncPayload — excludes deleted times (via filter)', () => {
    let state = reducer(baseState, {
      type: 'RECORD_TIME', payload: { elapsed: 60000, assignment: null, intensity: null },
    })
    state = reducer(state, {
      type: 'RECORD_TIME', payload: { elapsed: 62000, assignment: null, intensity: null },
    })
    state = reducer(state, { type: 'DELETE_TIME', payload: { id: state.repTimes[0].id } })
    const syncPayload = state.repTimes.filter(t => !t.deleted)
    expect(syncPayload).toHaveLength(1)
    expect(syncPayload[0].elapsedMs).toBe(62000)
  })
})