import React, { useState } from "react";
import {
  View,
  Text,
  StyleSheet,
  Alert,
  ActivityIndicator,
  TouchableOpacity,
  TextInput,
  KeyboardAvoidingView,
  Platform,
  ScrollView,
} from "react-native";
import { useRouter } from "expo-router";
import * as WebBrowser from "expo-web-browser";
import { supabase } from "../lib/supabase";
import { withTimeout } from "../lib/supabase-helpers";
import {
  Colors,
  FontFamily,
  FontSize,
  Space,
  Radius,
  TouchTarget,
} from "../lib/theme";

WebBrowser.maybeCompleteAuthSession();

/**
 * Clean & Standard Login Experience
 *
 * Direct Email/Password authentication for Hydrolyze accounts.
 */
export default function LoginScreen() {
  const router = useRouter();
  const [isSignUp, setIsSignUp] = useState(false);
  const [isReset, setIsReset] = useState(false);
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [loading, setLoading] = useState(false);

  async function handleEmailAuth() {
    if (!email.includes("@")) {
      Alert.alert("Input Required", "Please enter a valid email.");
      return;
    }

    if (!isReset && password.length < 6) {
      Alert.alert(
        "Input Required",
        "Please enter a password (min 6 characters).",
      );
      return;
    }

    setLoading(true);
    try {
      if (isReset) {
        const { error } = await withTimeout(
          supabase.auth.resetPasswordForEmail(email),
          10000,
        );
        if (error) throw error;
        Alert.alert(
          "Reset Sent",
          "Check your email for a link to set a password.",
        );
        setIsReset(false);
      } else if (isSignUp) {
        const { error } = await withTimeout(
          supabase.auth.signUp({ email, password }),
          10000,
        );
        if (error) {
          if (
            error.status === 422 ||
            error.message.includes("already registered")
          ) {
            throw new Error(
              "This email is already registered. Try signing in or resetting your password.",
            );
          }
          throw error;
        }
        Alert.alert(
          "Check Email",
          "We sent a verification link. Please confirm your email to sign in.",
        );
      } else {
        const { error } = await withTimeout(
          supabase.auth.signInWithPassword({ email, password }),
          10000,
        );
        if (error) throw error;
        router.replace("/(tabs)/today");
      }
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      Alert.alert("Authentication Error", msg);
    } finally {
      setLoading(false);
    }
  }

  const title = isReset
    ? "Reset Password"
    : isSignUp
      ? "Create Account"
      : "Coach Dashboard";

  return (
    <KeyboardAvoidingView
      behavior={Platform.OS === "ios" ? "padding" : "height"}
      style={styles.container}
    >
      <ScrollView
        contentContainerStyle={styles.scrollContent}
        keyboardShouldPersistTaps="handled"
      >
        <View style={styles.header}>
          <Text style={styles.title}>HYDROLYZE</Text>
          <Text style={styles.subtitle}>{title}</Text>
        </View>

        <View style={styles.form}>
          <View style={styles.inputGroup}>
            <Text style={styles.label}>EMAIL</Text>
            <TextInput
              style={styles.input}
              value={email}
              onChangeText={setEmail}
              placeholder="coach@team.com"
              placeholderTextColor={Colors.dim}
              keyboardType="email-address"
              autoCapitalize="none"
              autoCorrect={false}
            />
          </View>

          {!isReset && (
            <View style={styles.inputGroup}>
              <Text style={styles.label}>PASSWORD</Text>
              <TextInput
                style={styles.input}
                value={password}
                onChangeText={setPassword}
                placeholder="••••••••"
                placeholderTextColor={Colors.dim}
                secureTextEntry
                autoCapitalize="none"
              />
            </View>
          )}

          <TouchableOpacity
            style={styles.primaryButton}
            onPress={handleEmailAuth}
            disabled={loading}
          >
            {loading ? (
              <ActivityIndicator color="#000" />
            ) : (
              <Text style={styles.primaryButtonText}>
                {isReset ? "Send Reset Link" : isSignUp ? "Sign Up" : "Sign In"}
              </Text>
            )}
          </TouchableOpacity>

          <View style={styles.footerLinks}>
            <TouchableOpacity
              onPress={() => {
                setIsSignUp(!isSignUp);
                setIsReset(false);
              }}
            >
              <Text style={styles.toggleText}>
                {isSignUp ? "Back to Sign In" : "New coach? Sign Up"}
              </Text>
            </TouchableOpacity>

            {!isSignUp && (
              <TouchableOpacity onPress={() => setIsReset(!isReset)}>
                <Text style={styles.toggleText}>
                  {isReset ? "Back to Sign In" : "Forgot Password?"}
                </Text>
              </TouchableOpacity>
            )}
          </View>
        </View>
      </ScrollView>
    </KeyboardAvoidingView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: Colors.base },
  scrollContent: { flexGrow: 1, justifyContent: "center", padding: Space[8] },
  header: { alignItems: "center", marginBottom: Space[12] },
  title: {
    fontFamily: FontFamily.mono,
    fontSize: 44,
    color: Colors.cyan,
    letterSpacing: 4,
  },
  subtitle: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.base,
    color: Colors.muted,
    marginTop: Space[1],
  },
  form: { gap: Space[4] },
  inputGroup: { gap: Space[1] },
  label: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: 10,
    color: Colors.dim,
    letterSpacing: 1,
  },
  input: {
    backgroundColor: Colors.elevated,
    borderRadius: Radius.md,
    height: 56,
    paddingHorizontal: Space[4],
    color: Colors.text,
    fontFamily: FontFamily.ui,
    fontSize: FontSize.base,
    borderWidth: 1,
    borderColor: Colors.border,
  },
  primaryButton: {
    backgroundColor: Colors.cyan,
    borderRadius: Radius.lg,
    height: 56,
    alignItems: "center",
    justifyContent: "center",
    marginTop: Space[2],
    ...Platform.select({
      ios: {
        shadowColor: Colors.cyan,
        shadowOffset: { width: 0, height: 0 },
        shadowOpacity: 0.3,
        shadowRadius: 10,
      },
      android: {
        elevation: 4,
      },
      web: {
        boxShadow: `0 0 12px ${Colors.cyan}4D`,
      },
    }),
  },
  primaryButtonText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.base,
    color: "#000",
    fontWeight: "700",
  },
  footerLinks: {
    flexDirection: "row",
    justifyContent: "space-between",
    marginTop: Space[1],
  },
  toggleText: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.sm,
    color: Colors.cyan,
  },
});
