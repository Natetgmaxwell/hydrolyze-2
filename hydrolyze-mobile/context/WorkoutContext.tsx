/**
 * WorkoutContext — workout-level session state.
 *
 * Extends SessionContext with:
 *   - Multi-set support: navigate between set components
 *   - Gear awareness: gear + paceTargetDistance on SetDefinition
 *   - 5D StatsCache keys: swimmerId + stroke + distance + intensity + gear
 *   - AsyncStorage persistence: restores full workout on app restart
 *
 * Backward compatible: existing SessionContext actions (START_SET, RECORD_TIME,
 * etc.) are still supported so existing tests continue to pass without changes.
 */

import React, {
  createContext, useContext, useReducer, useEffect, useRef
} from 'react'
import AsyncStorage from '@react-native-async-storage/async-storage'
import type { Swimmer, StatsCache, Assignment } from '../lib/ml-pairing'
import type { IntensityLevel } from '../lib/set-parser'
import type { GearType } from '../lib/workout-parser'

// ─── Types ────────────────────────────────────────────────────────────────────

export type Stroke = 'Free' | 'Back' | 'Breast' | 'Fly' | 'IM' | 'Form'

/** Per-set configuration — what the coach is timing right now. */
export interface SetDefinition {
  id: string              // workout_set_id from Supabase (or local UUID for unsaved)
  workoutId: string       // parent workout id
  /** Which set component this is (0-indexed in the workout) */
  setIndex: number
  distance: number
  stroke: Stroke
  reps: number
  interval: string | null
  intensityPattern: readonly IntensityLevel[]  // per-rep effort levels; length === reps
  /** Gear being worn for this set (null = no gear) */
  gear: GearType | null
  /** If set, used as the effective distance for stats cache lookup (pace targets) */
  paceTargetDistance: number | null
}

/** A full workout (parsed from NL input or loaded from Supabase) */
export interface Workout {
  id: string              // workouts.id from Supabase (or local UUID)
  coachId: string
  title: string | null
  /** Ordered list of all set components in this workout */
  sets: WorkoutSetDefinition[]
  /** 0-based index of the currently selected set, or null if not started */
  currentSetIndex: number | null
  /** True once all sets have been completed */
  isComplete: boolean
}

/** Serializable set definition (matches workout_sets DB table) */
export interface WorkoutSetDefinition {
  id: string
  orderIndex: number
  reps: number | null
  distance: number | null
  stroke: Stroke | null
  interval: string | null
  intensityLabel: string | null
  gear: GearType | null
  paceTargetDistance: number | null
  isCompleted: boolean
}

/** A recorded lap time */
export interface RecordedTime {
  id: string              // local uuid, used for delete/reassign
  elapsedMs: number
  repNumber: number
  /** Effort level for this rep (from intensityPattern). May be null if not specified. */
  intensity?: IntensityLevel | null
  assignment: Assignment | null
  deleted: boolean
}

/** Workout-level session state */
export interface WorkoutState {
  workout: Workout | null
  /** Index of the currently selected set in workout.sets (null if not yet started) */
  currentSetIndex: number | null
  currentSet: SetDefinition | null   // active set being timed; null if none selected
  attendanceList: Swimmer[]
  statsCache: StatsCache
  repTimes: RecordedTime[]
  currentRepNum: number
  timingState: 'ready' | 'running' | 'rep_done'
}

const initialState: WorkoutState = {
  workout: null,
  currentSetIndex: null,
  currentSet: null,
  attendanceList: [],
  statsCache: {},
  repTimes: [],
  currentRepNum: 1,
  timingState: 'ready',
}

// ─── Actions ──────────────────────────────────────────────────────────────────

export type WorkoutAction =
  // ── Workout lifecycle ──────────────────────────────────────────────────────
  | { type: 'START_WORKOUT'; payload: Workout }
  | { type: 'SELECT_SET'; payload: { setIndex: number } }
  | { type: 'SET_COMPLETE'; payload: { setIndex: number } }
  | { type: 'END_WORKOUT' }

  // ── Timing actions (backward-compatible with SessionContext) ─────────────
  | { type: 'START_SET'; payload: SetDefinition }
  | { type: 'SET_ATTENDANCE'; payload: { swimmers: Swimmer[]; statsCache: StatsCache } }
  | { type: 'RECORD_TIME'; payload: { elapsed: number; assignment: Assignment | null; intensity: IntensityLevel | null } }
  | { type: 'DELETE_TIME'; payload: { id: string } }
  | { type: 'ASSIGN_TIME', payload: { id: string; swimmerId: string } }
  | { type: 'RESET_REP' }
  | { type: 'ADVANCE_REP' }

  | { type: 'END_SET' }
  | { type: 'RESTORE'; payload: WorkoutState }

// ─── Helpers ──────────────────────────────────────────────────────────────────

function generateId(): string {
  return Math.random().toString(36).slice(2) + Date.now().toString(36)
}

// ─── Reducer ──────────────────────────────────────────────────────────────────

export function reducer(state: WorkoutState, action: WorkoutAction): WorkoutState {
  switch (action.type) {

    case 'START_WORKOUT': {
      const workout = action.payload
      const firstUncompleted = workout.sets.findIndex(s => !s.isCompleted)
      return {
        ...initialState,
        workout,
        currentSetIndex: workout.sets.length > 0 ? (firstUncompleted >= 0 ? firstUncompleted : 0) : null,
      }
    }

    case 'SELECT_SET': {
      if (!state.workout) return state
      const { setIndex } = action.payload
      const setDef = state.workout.sets[setIndex]
      if (!setDef || setDef.isCompleted) return state

      const intensityPattern: readonly IntensityLevel[] = Array(setDef.reps ?? 0).fill('moderate') as readonly IntensityLevel[]

      const newSet: SetDefinition = {
        id: setDef.id,
        workoutId: state.workout.id,
        setIndex,
        distance: setDef.distance ?? 50,
        stroke: setDef.stroke ?? 'Free',
        reps: setDef.reps ?? 4,
        interval: setDef.interval,
        intensityPattern,
        gear: setDef.gear,
        paceTargetDistance: setDef.paceTargetDistance,
      }

      return {
        ...state,
        currentSet: newSet,
        repTimes: [],
        currentRepNum: 1,
        timingState: 'ready',
      }
    }

    case 'SET_COMPLETE': {
      if (!state.workout) return state
      const { setIndex } = action.payload
      const sets = state.workout.sets.map((s, i) =>
        i === setIndex ? { ...s, isCompleted: true } : s
      )
      const allDone = sets.every(s => s.isCompleted)
      return {
        ...state,
        workout: { ...state.workout, sets, isComplete: allDone },
        currentSet: null,
        currentSetIndex: null,
      }
    }

    case 'END_WORKOUT':
      return initialState

    // ── BACKWARD-COMPATIBLE SessionContext actions ─────────────────────────

    case 'START_SET':
      return { ...initialState, currentSet: action.payload, currentRepNum: 1, timingState: 'ready' }

    case 'SET_ATTENDANCE':
      return {
        ...state,
        attendanceList: action.payload.swimmers,
        statsCache: action.payload.statsCache,
      }

    case 'RECORD_TIME': {
      const newTime: RecordedTime = {
        id: generateId(),
        elapsedMs: action.payload.elapsed,
        repNumber: state.currentRepNum,
        intensity: action.payload.intensity,
        assignment: action.payload.assignment,
        deleted: false,
      }
      return { ...state, repTimes: [...state.repTimes, newTime] }
    }

    case 'DELETE_TIME':
      return {
        ...state,
        repTimes: state.repTimes.map(t =>
          t.id === action.payload.id ? { ...t, deleted: true } : t
        ),
      }

    case 'ASSIGN_TIME':
      return {
        ...state,
        repTimes: state.repTimes.map(t =>
          t.id === action.payload.id
            ? {
                ...t,
                assignment: {
                  swimmerId: action.payload.swimmerId,
                  source: 'recorded' as const,
                  errorMs: 0,
                  sampleCount: 0,
                },
              }
            : t
        ),
      }

    case 'RESET_REP':
      return {
        ...state,
        repTimes: state.repTimes.filter(t => t.repNumber !== state.currentRepNum),
        timingState: 'ready',
      }

    case 'ADVANCE_REP':
      return { ...state, currentRepNum: state.currentRepNum + 1, timingState: 'ready' }

    case 'END_SET':
      return {
        ...state,
        currentSet: null,
        repTimes: [],
        currentRepNum: 1,
        timingState: 'ready',
      }

    case 'RESTORE':
      return action.payload

    default:
      return state
  }
}

// ─── Context ─────────────────────────────────────────────────────────────────

const WORKOUT_STORAGE_KEY = 'hydrolyze_active_workout'

interface WorkoutContextValue {
  state: WorkoutState
  dispatch: React.Dispatch<WorkoutAction>
  activeRepTimes: RecordedTime[]
  syncPayload: RecordedTime[]
}

const WorkoutContext = createContext<WorkoutContextValue | null>(null)

export function WorkoutProvider({ children }: { children: React.ReactNode }) {
  const [state, dispatch] = useReducer(reducer, initialState)
  const persistDebounce = useRef<ReturnType<typeof setTimeout> | null>(null)

  // Persist to AsyncStorage on every state change (debounced 300ms)
  useEffect(() => {
    if (state.repTimes.length === 0) return
    if (persistDebounce.current) clearTimeout(persistDebounce.current)
    persistDebounce.current = setTimeout(() => {
      AsyncStorage.setItem(WORKOUT_STORAGE_KEY, JSON.stringify(state)).catch(() => {
        // Silent fail — times are still in memory
      })
    }, 300)
    return () => {
      if (persistDebounce.current) clearTimeout(persistDebounce.current)
    }
  }, [state])

  const activeRepTimes = state.repTimes.filter(
    t => !t.deleted && t.repNumber === state.currentRepNum
  )
  const syncPayload = state.repTimes.filter(t => !t.deleted)

  return (
    <WorkoutContext.Provider value={{ state, dispatch, activeRepTimes, syncPayload }}>
      {children}
    </WorkoutContext.Provider>
  )
}

export function useWorkout(): WorkoutContextValue {
  const ctx = useContext(WorkoutContext)
  if (!ctx) throw new Error('useWorkout must be used within WorkoutProvider')
  return ctx
}

// Alias for backward compatibility with existing code using useSession
export { useWorkout as useSession }

/**
 * Check for a saved workout to restore after a crash or app restart.
 * Returns null if no workout is saved or the saved data is corrupt.
 */
export async function checkSavedWorkout(): Promise<WorkoutState | null> {
  try {
    const raw = await AsyncStorage.getItem(WORKOUT_STORAGE_KEY)
    if (!raw) return null
    return JSON.parse(raw) as WorkoutState
  } catch {
    return null
  }
}

/**
 * Clear saved workout from AsyncStorage after successful Supabase sync.
 */
export async function clearSavedWorkout(): Promise<void> {
  await AsyncStorage.removeItem(WORKOUT_STORAGE_KEY)
}

// ─── Backward compatibility exports ─────────────────────────────────────────
// Code that imports from SessionContext.tsx continues to work.
// WorkoutContext exports its own useWorkout hook above.