/**
 * Root redirect — checks auth state and sends user to the right place.
 *
 * If logged in → Today tab
 * If not logged in → /login
 */

import { useEffect } from "react";
import { View, ActivityIndicator, StyleSheet } from "react-native";
import { useRouter } from "expo-router";
import { useAuth } from "../context/AuthContext";
import { Colors } from "../lib/theme";

export default function IndexScreen() {
  const { user, needsOnboarding, loading } = useAuth();
  const router = useRouter();

  useEffect(() => {
    if (loading) return;
    if (!user) {
      router.replace("/login");
    } else if (needsOnboarding) {
      router.replace("/onboarding");
    } else {
      router.replace("/(tabs)/today");
    }
  }, [user, needsOnboarding, loading]);

  return (
    <View style={styles.container}>
      <ActivityIndicator color={Colors.cyan} size="large" />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: Colors.base,
    alignItems: "center",
    justifyContent: "center",
  },
});
