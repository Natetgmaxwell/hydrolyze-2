/**
 * Session stack layout.
 * WorkoutProvider is already provided at the root (_layout.tsx) — do NOT wrap
 * here again or you'll create a second isolated context instance with empty state.
 *
 * RestoreGuard checks for a saved workout on mount and prompts the coach to resume.
 * It skips the check if WorkoutContext already has an active workout (e.g. navigating
 * from WorkoutBuilder after START_WORKOUT + SELECT_SET).
 */

import { useEffect, useState } from 'react'
import { Alert } from 'react-native'
import { Stack } from 'expo-router'
import { checkSavedWorkout, useWorkout } from '../../context/WorkoutContext'

function RestoreGuard({ children }: { children: React.ReactNode }) {
  const { dispatch, state } = useWorkout()
  const [checked, setChecked] = useState(false)

  // Skip the saved workout check if WorkoutContext already has an active workout.
  // This handles the case where navigating from WorkoutBuilder already populated
  // WorkoutContext before RestoreGuard runs its useEffect.
  const hasActiveWorkout = !!(state.workout && state.currentSet)

  useEffect(() => {
    if (hasActiveWorkout) {
      setChecked(true)
      return
    }

    checkSavedWorkout().then(saved => {
      if (saved && saved.repTimes.length > 0) {
        Alert.alert(
          'Resume workout?',
          'You have an unsaved workout from earlier. Resume it?',
          [
            {
              text: 'Resume',
              onPress: () => dispatch({ type: 'RESTORE', payload: saved }),
            },
            { text: 'Start fresh', style: 'destructive' },
          ]
        )
      }
      setChecked(true)
    })
  }, [dispatch, hasActiveWorkout])

  return <>{children}</>
}

export default function SessionLayout() {
  return (
    <RestoreGuard>
      <Stack screenOptions={{ headerShown: false }} />
    </RestoreGuard>
  )
}