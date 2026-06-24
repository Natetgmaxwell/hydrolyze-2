/**
 * Onboarding flow — 4-screen horizontal slide wizard.
 * Route: /onboarding
 */

import { useState, useRef } from "react";
import {
  View,
  Text,
  TextInput,
  TouchableOpacity,
  StyleSheet,
  Dimensions,
  KeyboardAvoidingView,
  Platform,
  Pressable,
  Animated,
  ScrollView,
} from "react-native";
import { Ionicons } from "@expo/vector-icons";
import { useRouter } from "expo-router";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { useAuth } from "../context/AuthContext";
import {
  updateCoachProfile,
  createTeam,
  completeOnboarding,
} from "../lib/auth";
import { Colors, FontFamily, FontSize, Space, Radius } from "../lib/theme";

const { width: SCREEN_WIDTH } = Dimensions.get("window");
const TOTAL_SCREENS = 4;

export default function OnboardingScreen() {
  const { coachId } = useAuth();
  const router = useRouter();
  const insets = useSafeAreaInsets();
  const scrollRef = useRef<ScrollView>(null);

  const [screen, setScreen] = useState(0);
  const [name, setName] = useState("");
  const [poolUnits, setPoolUnits] = useState<"yards" | "meters">("meters");
  const [teamName, setTeamName] = useState("");
  const [submitting, setSubmitting] = useState(false);

  function goTo(target: number) {
    scrollRef.current?.scrollTo({ x: target * SCREEN_WIDTH, animated: true });
    setScreen(target);
  }

  function goNext() {
    if (screen < TOTAL_SCREENS - 1) {
      goTo(screen + 1);
    }
  }

  function goBack() {
    if (screen > 0) {
      goTo(screen - 1);
    }
  }

  async function handleScreen1() {
    if (!name.trim() || !coachId) return;
    await updateCoachProfile(coachId, { name: name.trim() });
    goNext();
  }

  async function handleScreen2() {
    if (!coachId) return;
    await updateCoachProfile(coachId, { pool_units: poolUnits });
    goNext();
  }

  async function handleScreen3() {
    if (teamName.trim() && coachId) {
      await createTeam(coachId, teamName.trim());
    }
    goNext();
  }

  async function handleScreen4() {
    if (!coachId || submitting) return;
    setSubmitting(true);
    await completeOnboarding(coachId);
    router.replace("/(tabs)/today");
  }

  return (
    <View style={[styles.container, { paddingTop: insets.top }]}>
      <View style={styles.dotsRow}>
        {Array.from({ length: TOTAL_SCREENS }).map((_, i) => (
          <View
            key={i}
            style={[
              styles.dot,
              i === screen ? styles.dotActive : styles.dotInactive,
            ]}
          />
        ))}
      </View>

      {screen > 0 && (
        <TouchableOpacity style={styles.backButton} onPress={goBack}>
          <Ionicons name="chevron-back" size={24} color={Colors.text} />
        </TouchableOpacity>
      )}

      <KeyboardAvoidingView
        behavior={Platform.OS === "ios" ? "padding" : "height"}
        style={styles.flex}
        keyboardVerticalOffset={Platform.OS === "ios" ? 0 : 20}
      >
        <ScrollView
          ref={scrollRef}
          horizontal
          pagingEnabled
          scrollEnabled={false}
          showsHorizontalScrollIndicator={false}
          style={styles.scrollView}
        >
          <Screen1 name={name} setName={setName} onContinue={handleScreen1} />
          <Screen2
            poolUnits={poolUnits}
            setPoolUnits={setPoolUnits}
            onContinue={handleScreen2}
          />
          <Screen3
            teamName={teamName}
            setTeamName={setTeamName}
            onContinue={handleScreen3}
          />
          <Screen4 onDone={handleScreen4} submitting={submitting} />
        </ScrollView>
      </KeyboardAvoidingView>
    </View>
  );
}

function Screen1({
  name,
  setName,
  onContinue,
}: {
  name: string;
  setName: (v: string) => void;
  onContinue: () => void;
}) {
  return (
    <View style={styles.slide}>
      <View style={styles.slideContent}>
        <Text style={styles.title}>What should I call you?</Text>
        <Text style={styles.subhead}>
          This is how you'll appear in the app.
        </Text>
        <TextInput
          style={styles.textInput}
          value={name}
          onChangeText={setName}
          placeholder="Your full name"
          placeholderTextColor={Colors.dim}
          autoFocus
          autoCapitalize="words"
          returnKeyType="done"
          onSubmitEditing={onContinue}
        />
      </View>
      <View style={styles.ctaContainer}>
        <TouchableOpacity
          style={[styles.ctaButton, !name.trim() && styles.ctaButtonDisabled]}
          onPress={onContinue}
          disabled={!name.trim()}
          activeOpacity={0.8}
        >
          <Text style={styles.ctaButtonText}>Continue</Text>
        </TouchableOpacity>
      </View>
    </View>
  );
}

function Screen2({
  poolUnits,
  setPoolUnits,
  onContinue,
}: {
  poolUnits: "yards" | "meters";
  setPoolUnits: (v: "yards" | "meters") => void;
  onContinue: () => void;
}) {
  return (
    <View style={styles.slide}>
      <View style={styles.slideContent}>
        <Text style={styles.title}>Pool length?</Text>
        <Text style={styles.subhead}>
          This sets the default for your workouts.
        </Text>
        <View style={styles.segmentedControl}>
          <TouchableOpacity
            style={[
              styles.segment,
              poolUnits === "yards" && styles.segmentActive,
            ]}
            onPress={() => setPoolUnits("yards")}
            activeOpacity={0.7}
          >
            <Text
              style={[
                styles.segmentText,
                poolUnits === "yards" && styles.segmentTextActive,
              ]}
            >
              Yards
            </Text>
          </TouchableOpacity>
          <TouchableOpacity
            style={[
              styles.segment,
              poolUnits === "meters" && styles.segmentActive,
            ]}
            onPress={() => setPoolUnits("meters")}
            activeOpacity={0.7}
          >
            <Text
              style={[
                styles.segmentText,
                poolUnits === "meters" && styles.segmentTextActive,
              ]}
            >
              Meters
            </Text>
          </TouchableOpacity>
        </View>
      </View>
      <View style={styles.ctaContainer}>
        <TouchableOpacity
          style={styles.ctaButton}
          onPress={onContinue}
          activeOpacity={0.8}
        >
          <Text style={styles.ctaButtonText}>Continue</Text>
        </TouchableOpacity>
      </View>
    </View>
  );
}

function Screen3({
  teamName,
  setTeamName,
  onContinue,
}: {
  teamName: string;
  setTeamName: (v: string) => void;
  onContinue: () => void;
}) {
  return (
    <View style={styles.slide}>
      <View style={styles.slideContent}>
        <Text style={styles.title}>What's your team or group?</Text>
        <Text style={styles.subhead}>
          Optional — you can always add this later.
        </Text>
        <TextInput
          style={styles.textInput}
          value={teamName}
          onChangeText={setTeamName}
          placeholder="e.g. Dolphins Swim Club"
          placeholderTextColor={Colors.dim}
          autoFocus
          autoCapitalize="words"
          returnKeyType="done"
          onSubmitEditing={onContinue}
        />
        <Pressable onPress={onContinue}>
          <Text style={styles.skipLink}>Skip for now</Text>
        </Pressable>
      </View>
      <View style={styles.ctaContainer}>
        <TouchableOpacity
          style={styles.ctaButton}
          onPress={onContinue}
          activeOpacity={0.8}
        >
          <Text style={styles.ctaButtonText}>Continue</Text>
        </TouchableOpacity>
      </View>
    </View>
  );
}

function Screen4({
  onDone,
  submitting,
}: {
  onDone: () => void;
  submitting: boolean;
}) {
  return (
    <View style={styles.slide}>
      <View style={styles.slideContent}>
        <Text style={styles.title}>One more thing —</Text>
        <Text style={styles.subhead}>
          The volume button records laps.{"\n"}Keeps your eyes on the pool.
        </Text>
        <View style={styles.iconPlaceholder}>
          <Ionicons
            name="phone-portrait-outline"
            size={80}
            color={Colors.cyan}
          />
        </View>
      </View>
      <View style={styles.ctaContainer}>
        <TouchableOpacity
          style={[styles.ctaButton, submitting && styles.ctaButtonDisabled]}
          onPress={onDone}
          disabled={submitting}
          activeOpacity={0.8}
        >
          <Text style={styles.ctaButtonText}>
            {submitting ? "Finishing..." : "Got it"}
          </Text>
        </TouchableOpacity>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: Colors.base },
  flex: { flex: 1 },
  scrollView: { flex: 1 },
  dotsRow: {
    flexDirection: "row",
    justifyContent: "center",
    alignItems: "center",
    paddingTop: Space[4],
    paddingBottom: Space[2],
    gap: Space[2],
  },
  dot: { width: 8, height: 8, borderRadius: 4 },
  dotActive: { backgroundColor: Colors.cyan },
  dotInactive: { backgroundColor: Colors.border },
  backButton: {
    position: "absolute",
    top: Space[4] + 4,
    left: Space[4],
    width: 44,
    height: 44,
    alignItems: "center",
    justifyContent: "center",
    zIndex: 10,
  },
  slide: {
    width: SCREEN_WIDTH,
    flex: 1,
    justifyContent: "space-between",
  },
  slideContent: {
    flex: 1,
    paddingHorizontal: Space[6],
    paddingTop: Space[12],
  },
  title: {
    fontFamily: FontFamily.uiMedium,
    fontSize: 28,
    color: Colors.text,
    marginBottom: Space[2],
  },
  subhead: {
    fontFamily: FontFamily.ui,
    fontSize: 15,
    color: Colors.muted,
    marginBottom: Space[8],
    lineHeight: 22,
  },
  textInput: {
    backgroundColor: Colors.elevated,
    borderWidth: 1,
    borderColor: Colors.border,
    borderRadius: Radius.md,
    paddingVertical: Space[4],
    paddingHorizontal: Space[4],
    fontFamily: FontFamily.ui,
    fontSize: 17,
    color: Colors.text,
    marginBottom: Space[4],
  },
  skipLink: {
    fontFamily: FontFamily.ui,
    fontSize: 15,
    color: Colors.muted,
    textAlign: "center",
    marginTop: Space[2],
    textDecorationLine: "underline",
  },
  segmentedControl: {
    flexDirection: "row",
    backgroundColor: Colors.elevated,
    borderRadius: Radius.md,
    borderWidth: 1,
    borderColor: Colors.border,
    padding: 2,
    gap: 2,
  },
  segment: {
    flex: 1,
    paddingVertical: Space[3],
    borderRadius: Radius.md - 2,
    alignItems: "center",
  },
  segmentActive: { backgroundColor: Colors.cyan },
  segmentText: {
    fontFamily: FontFamily.uiMedium,
    fontSize: 15,
    color: Colors.muted,
  },
  segmentTextActive: { color: Colors.base },
  iconPlaceholder: {
    alignItems: "center",
    justifyContent: "center",
    paddingTop: Space[8],
  },
  ctaContainer: {
    paddingHorizontal: Space[6],
    paddingBottom: Space[8],
  },
  ctaButton: {
    backgroundColor: Colors.cyan,
    borderRadius: Radius.lg,
    height: 56,
    alignItems: "center",
    justifyContent: "center",
  },
  ctaButtonDisabled: { opacity: 0.4 },
  ctaButtonText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.base,
    color: Colors.base,
    fontWeight: "600",
  },
});
