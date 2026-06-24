/**
 * Profile tab — coach's name, email, settings entry, sign out.
 * Route: /(tabs)/profile
 */

import { View, Text, TouchableOpacity, StyleSheet, Alert } from "react-native";
import { useRouter } from "expo-router";
import { Ionicons } from "@expo/vector-icons";
import { supabase } from "../../lib/supabase";
import { useAuth } from "../../context/AuthContext";
import { Colors, FontFamily, FontSize, Space, Radius } from "../../lib/theme";

function getInitials(
  name: string | null | undefined,
  email: string | null | undefined,
): string {
  if (name) {
    const parts = name.trim().split(/\s+/);
    if (parts.length >= 2) {
      return (parts[0][0] + parts[1][0]).toUpperCase();
    }
    return name.slice(0, 2).toUpperCase();
  }
  if (!email) return "?";
  const local = email.split("@")[0];
  const emailParts = local.split(/[._-]/);
  if (emailParts.length >= 2) {
    return (emailParts[0][0] + emailParts[1][0]).toUpperCase();
  }
  return local.slice(0, 2).toUpperCase();
}

export default function ProfileScreen() {
  const { user, coachName } = useAuth();
  const router = useRouter();

  const displayName = coachName ?? user?.email?.split("@")[0] ?? "Coach";
  const initials = getInitials(coachName, user?.email);

  async function handleSignOut() {
    try {
      await new Promise<void>((resolve, reject) => {
        const timer = setTimeout(
          () => reject(new Error("Sign-out timed out after 10s")),
          10000,
        );
        Promise.resolve(supabase.auth.signOut())
          .then(({ error }: any) => {
            clearTimeout(timer);
            if (error) reject(error);
            else resolve();
          })
          .catch((err: any) => {
            clearTimeout(timer);
            reject(err);
          });
      });
      router.replace("/login");
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      Alert.alert("Sign-out failed", msg);
    }
  }

  return (
    <View style={styles.container}>
      <View style={styles.profileHeader}>
        <View style={styles.avatarCircle}>
          <Text style={styles.avatarText}>{initials}</Text>
        </View>
        <Text style={styles.coachName}>{displayName}</Text>
        <Text style={styles.coachEmail}>{user?.email ?? ""}</Text>
      </View>

      <View style={styles.sectionCard}>
        <TouchableOpacity
          style={styles.row}
          onPress={() => router.push("/settings")}
          activeOpacity={0.6}
        >
          <Ionicons name="settings-outline" size={22} color={Colors.text} />
          <Text style={styles.rowLabel}>Settings</Text>
          <Ionicons name="chevron-forward" size={18} color={Colors.dim} />
        </TouchableOpacity>

        <View style={styles.separator} />

        <TouchableOpacity
          style={styles.row}
          onPress={handleSignOut}
          activeOpacity={0.6}
        >
          <Ionicons name="log-out-outline" size={22} color="#ff3b30" />
          <Text style={[styles.rowLabel, { color: "#ff3b30" }]}>Sign Out</Text>
        </TouchableOpacity>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: Colors.base },
  profileHeader: {
    alignItems: "center",
    paddingTop: Space[12],
    paddingBottom: Space[8],
    borderBottomWidth: 1,
    borderBottomColor: Colors.border,
  },
  avatarCircle: {
    width: 72,
    height: 72,
    borderRadius: 36,
    backgroundColor: Colors.surface,
    borderWidth: 1,
    borderColor: Colors.border,
    alignItems: "center",
    justifyContent: "center",
    marginBottom: Space[4],
  },
  avatarText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: 28,
    color: Colors.text,
  },
  coachName: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: 22,
    color: Colors.text,
    marginBottom: Space[1],
  },
  coachEmail: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.base,
    color: Colors.muted,
  },
  sectionCard: {
    margin: Space[4],
    backgroundColor: Colors.surface,
    borderRadius: Radius.lg,
    borderWidth: 1,
    borderColor: Colors.border,
    overflow: "hidden",
  },
  row: {
    flexDirection: "row",
    alignItems: "center",
    paddingVertical: Space[4],
    paddingHorizontal: Space[4],
    gap: Space[4],
  },
  rowLabel: {
    flex: 1,
    fontFamily: FontFamily.ui,
    fontSize: 17,
    color: Colors.text,
  },
  separator: {
    height: 1,
    backgroundColor: Colors.border,
    marginLeft: Space[4] + 22 + Space[4],
  },
});
