import React from 'react'
import { View } from 'react-native'

// Expose right actions inline so tests can find Delete/action buttons
export const Swipeable = ({
  children,
  renderRightActions,
}: {
  children: React.ReactNode
  renderRightActions?: () => React.ReactNode
}) => (
  <View>
    {children}
    {renderRightActions ? renderRightActions() : null}
  </View>
)

export const GestureHandlerRootView = ({ children }: { children: React.ReactNode }) => (
  <View>{children}</View>
)

export const PanGestureHandler = ({ children }: { children: React.ReactNode }) => (
  <View>{children}</View>
)
