import { Stack } from 'expo-router'
import { Colors } from '../../lib/theme'

export default function CalendarLayout() {
  return (
    <Stack
      screenOptions={{
        headerStyle: { backgroundColor: Colors.surface },
        headerTintColor: Colors.text,
        headerTitleStyle: { fontFamily: 'Inter_600SemiBold', fontSize: 17 },
        contentStyle: { backgroundColor: Colors.base },
      }}
    />
  )
}