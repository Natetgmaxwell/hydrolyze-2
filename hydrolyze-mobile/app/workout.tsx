/**
 * Workout route — redirects to /workout/new.
 * The workout builder is at /workout/new; this file exists to satisfy
 * the Stack.Screen name="workout" declared in _layout.tsx.
 */
import { Redirect } from 'expo-router'

export default function WorkoutScreen() {
  return <Redirect href="/workout/new" />
}
