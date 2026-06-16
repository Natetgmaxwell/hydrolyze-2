import { TouchableOpacity, Text, StyleSheet, type ViewStyle } from 'react-native'
import { Colors, FontFamily, FontSize, Radius, TouchTarget } from '../lib/theme'

interface LapButtonProps {
  onPress: () => void
  disabled?: boolean
  style?: ViewStyle
}

export function LapButton({ onPress, disabled, style }: LapButtonProps) {
  return (
    <TouchableOpacity
      style={[styles.button, disabled && styles.buttonDisabled, style]}
      onPress={onPress}
      disabled={disabled}
      activeOpacity={0.75}
    >
      <Text style={styles.label}>LAP</Text>
    </TouchableOpacity>
  )
}

const styles = StyleSheet.create({
  button: {
    backgroundColor: Colors.cyan,
    borderRadius: Radius.lg,
    height: TouchTarget.lap,
    justifyContent: 'center',
    alignItems: 'center',
    marginHorizontal: 16,
    boxShadow: `0 0 16px ${Colors.cyanGlow}`,
    elevation: 4,
    elevation: 8,
  },
  buttonDisabled: { opacity: 0.25 },
  label: {
    color: '#000',
    fontFamily: FontFamily.mono,
    fontSize: FontSize.lg,
    letterSpacing: 3,
  },
})
