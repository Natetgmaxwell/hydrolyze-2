// Polyfill for React Native Web - must be first import
import "../lib/polyfills";

import { useEffect } from "react";
import { View, StyleSheet } from "react-native";
import { Stack } from "expo-router";
import { GestureHandlerRootView } from "react-native-gesture-handler";
import { useFonts } from "expo-font";
import {
  JetBrainsMono_500Medium,
  JetBrainsMono_700Bold,
} from "@expo-google-fonts/jetbrains-mono";
import {
  Inter_400Regular,
  Inter_500Medium,
  Inter_600SemiBold,
} from "@expo-google-fonts/inter";
import * as SplashScreen from "expo-splash-screen";
import { Colors } from "../lib/theme";
import { WorkoutProvider } from "../context/WorkoutContext";
import { AuthProvider } from "../context/AuthContext";
import { SettingsProvider } from "../context/SettingsContext";

SplashScreen.preventAutoHideAsync();

export default function RootLayout() {
  const [fontsLoaded] = useFonts({
    JetBrainsMono_700Bold,
    JetBrainsMono_500Medium,
    Inter_400Regular,
    Inter_500Medium,
    Inter_600SemiBold,
  });

  useEffect(() => {
    if (fontsLoaded) SplashScreen.hideAsync();
  }, [fontsLoaded]);

  if (!fontsLoaded)
    return <View style={{ flex: 1, backgroundColor: Colors.base }} />;

  return (
    <GestureHandlerRootView style={{ flex: 1, backgroundColor: Colors.base }}>
      <AuthProvider>
        <SettingsProvider>
          <WorkoutProvider>
            <Stack
              screenOptions={{
                headerStyle: { backgroundColor: Colors.surface },
                headerTintColor: Colors.text,
                headerTitleStyle: {
                  fontFamily: "Inter_600SemiBold",
                  fontSize: 17,
                },
                contentStyle: { backgroundColor: Colors.base },
              }}
            >
              <Stack.Screen
                name="index"
                options={{ title: "Hydrolyze", headerShown: false }}
              />
              <Stack.Screen
                name="login"
                options={{ title: "Sign In", headerShown: false }}
              />
              <Stack.Screen
                name="login-callback"
                options={{ title: "", headerShown: false }}
              />
              <Stack.Screen
                name="auth-debug"
                options={{ title: "", headerShown: false }}
              />
              <Stack.Screen
                name="onboarding"
                options={{ title: "Setup", headerShown: false }}
              />
              <Stack.Screen
                name="settings"
                options={{
                  title: "Settings",
                  headerBackTitle: "Today",
                  headerLargeTitle: true,
                  headerStyle: { backgroundColor: Colors.base },
                  headerTintColor: Colors.text,
                }}
              />
              <Stack.Screen name="(tabs)" options={{ headerShown: false }} />
              <Stack.Screen name="session" options={{ headerShown: false }} />
              <Stack.Screen name="workout" options={{ headerShown: false }} />
            </Stack>
          </WorkoutProvider>
        </SettingsProvider>
      </AuthProvider>
    </GestureHandlerRootView>
  );
}
