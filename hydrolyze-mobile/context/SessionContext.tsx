/**
 * SessionContext — thin re-export for backward compatibility.
 *
 * All existing code imports from this file.
 * This re-export ensures zero breaking changes while routing
 * all state management through the new WorkoutContext.
 */

export {
  WorkoutProvider as SessionProvider,
  useWorkout as useSession,
  checkSavedWorkout as checkSavedSession,
  clearSavedWorkout as clearSavedSession,
} from './WorkoutContext'

export type {
  WorkoutState as SessionState,
  WorkoutAction as SessionAction,
  SetDefinition,
  RecordedTime,
} from './WorkoutContext'