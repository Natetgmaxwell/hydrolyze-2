/**
 * Tab bar layout — four tabs: Today, Workouts, Swimmers, Me.
 */

import { Tabs } from "expo-router";
import { View, Text, StyleSheet } from "react-native";
import { Colors, FontFamily, FontSize } from "../../lib/theme";

function TabIcon({ label, focused }: { label: string; focused: boolean }) {
  return (
    <View style={styles.iconWrap}>
      <Text style={[styles.iconDot, focused && styles.iconDotFocused]} />
      <Text style={[styles.iconLabel, focused && styles.iconLabelFocused]}>
        {label}
      </Text>
    </View>
  );
}

export default function TabsLayout() {
  return (
    <Tabs
      screenOptions={{
        headerShown: false,
        tabBarStyle: {
          backgroundColor: Colors.surface,
          borderTopColor: Colors.border,
          borderTopWidth: 1,
          height: 80,
          paddingTop: 8,
        },
        tabBarShowLabel: false,
      }}
    >
      <Tabs.Screen
        name="today"
        options={{
          tabBarIcon: ({ focused }) => (
            <TabIcon label="TODAY" focused={focused} />
          ),
          headerShown: true,
          headerTitle: "",
          headerStyle: { backgroundColor: Colors.base },
          headerTintColor: Colors.text,
        }}
      />
      <Tabs.Screen
        name="workouts"
        options={{
          tabBarIcon: ({ focused }) => (
            <TabIcon label="WORKOUTS" focused={focused} />
          ),
        }}
      />
      <Tabs.Screen
        name="swimmers"
        options={{
          tabBarIcon: ({ focused }) => (
            <TabIcon label="SWIMMERS" focused={focused} />
          ),
        }}
      />
      <Tabs.Screen
        name="profile"
        options={{
          tabBarIcon: ({ focused }) => <TabIcon label="ME" focused={focused} />,
          headerShown: true,
          headerTitle: "Profile",
          headerStyle: { backgroundColor: Colors.base },
          headerTintColor: Colors.text,
        }}
      />
    </Tabs>
  );
}

const styles = StyleSheet.create({
  iconWrap: {
    alignItems: "center",
    gap: 4,
  },
  iconDot: {
    width: 6,
    height: 6,
    borderRadius: 3,
    backgroundColor: Colors.dim,
  },
  iconDotFocused: {
    backgroundColor: Colors.cyan,
  },
  iconLabel: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: 9,
    color: Colors.dim,
    letterSpacing: 1,
  },
  iconLabelFocused: {
    color: Colors.cyan,
  },
});
