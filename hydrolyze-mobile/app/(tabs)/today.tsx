/**
 * Today tab — shows the next scheduled workout with set list and timing.
 * Route: /(tabs)/today
 */

import { useCallback, useState } from "react";
import { View, Text, TouchableOpacity, StyleSheet } from "react-native";
import { useRouter, useFocusEffect } from "expo-router";
import { supabase } from "../../lib/supabase";
import { useAuth } from "../../context/AuthContext";
import { Colors, FontFamily, FontSize, Space, Radius } from "../../lib/theme";

interface WorkoutDay {
  date: string;
  workouts: { id: string; title: string | null; am_pm: string | null }[];
}

function formatDate(dateStr: string) {
  const d = new Date(dateStr + "T00:00:00");
  return {
    day: d.toLocaleDateString("en-US", { day: "numeric" }),
    month: d.toLocaleDateString("en-US", { month: "short" }).toUpperCase(),
    weekday: d.toLocaleDateString("en-US", { weekday: "short" }).toUpperCase(),
  };
}

function isSameDay(a: Date, b: Date) {
  return (
    a.getFullYear() === b.getFullYear() &&
    a.getMonth() === b.getMonth() &&
    a.getDate() === b.getDate()
  );
}

export default function TodayScreen() {
  const { coachId } = useAuth();
  const router = useRouter();
  const [nextWorkout, setNextWorkout] = useState<{
    id: string;
    title: string | null;
    am_pm: string | null;
    scheduled_at: string;
  } | null>(null);
  const [loading, setLoading] = useState(true);

  useFocusEffect(
    useCallback(() => {
      loadNextWorkout();
    }, [coachId]),
  );

  async function loadNextWorkout() {
    if (!coachId) {
      setLoading(false);
      return;
    }
    setLoading(true);
    const today = new Date();
    const todayStr = today.toISOString().slice(0, 10);
    const { data } = await supabase
      .from("workouts")
      .select("id, title, scheduled_at, am_pm")
      .eq("coach_id", coachId)
      .eq("status", "scheduled")
      .gte("scheduled_at", today.toISOString().split("T")[0])
      .order("scheduled_at", { ascending: true })
      .limit(1)
      .maybeSingle();
    setNextWorkout(data);
    setLoading(false);
  }

  if (!coachId || loading) {
    return (
      <View style={styles.container}>
        <Text style={styles.loadingText}>Loading...</Text>
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <Text style={styles.screenLabel}>TODAY</Text>
        <Text style={styles.dateLabel}>
          {new Date().toLocaleDateString("en-US", {
            weekday: "long",
            month: "long",
            day: "numeric",
          })}
        </Text>
      </View>

      {!nextWorkout ? (
        <View style={styles.emptyState}>
          <Text style={styles.emptyTitle}>No upcoming workouts</Text>
          <Text style={styles.emptyHint}>Create one in the Workouts tab.</Text>
        </View>
      ) : (
        <WorkoutCard
          workout={nextWorkout}
          onStartTiming={() =>
            router.push(`/session/set-picker?workoutId=${nextWorkout.id}`)
          }
        />
      )}
    </View>
  );
}

function WorkoutCard({
  workout,
  onStartTiming,
}: {
  workout: { id: string; title: string | null; am_pm: string | null };
  onStartTiming: () => void;
}) {
  return (
    <View style={styles.card}>
      <View style={styles.cardHeader}>
        <Text style={styles.cardAmPm}>{workout.am_pm ?? "AM"}</Text>
        <Text style={styles.cardTitle}>{workout.title ?? "Workout"}</Text>
      </View>
      <TouchableOpacity
        style={styles.cardCta}
        onPress={onStartTiming}
        activeOpacity={0.85}
      >
        <Text style={styles.cardCtaText}>Start Session</Text>
      </TouchableOpacity>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: Colors.base },
  header: {
    paddingHorizontal: Space[6],
    paddingTop: Space[12],
    paddingBottom: Space[4],
    borderBottomWidth: 1,
    borderBottomColor: Colors.border,
  },
  screenLabel: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.xs,
    color: Colors.dim,
    letterSpacing: 1.2,
    marginBottom: Space[1],
  },
  dateLabel: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.lg,
    color: Colors.text,
  },
  loadingText: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.base,
    color: Colors.muted,
    textAlign: "center",
    marginTop: Space[12],
  },
  emptyState: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    gap: Space[3],
  },
  emptyTitle: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.lg,
    color: Colors.muted,
  },
  emptyHint: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.base,
    color: Colors.dim,
  },
  card: {
    margin: Space[4],
    backgroundColor: Colors.surface,
    borderRadius: Radius.lg,
    borderWidth: 1,
    borderColor: Colors.border,
    padding: Space[6],
  },
  cardHeader: { marginBottom: Space[4] },
  cardAmPm: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.xs,
    color: Colors.amber,
    letterSpacing: 1,
    marginBottom: Space[1],
  },
  cardTitle: {
    fontFamily: FontFamily.uiMedium,
    fontSize: FontSize.lg,
    color: Colors.text,
  },
  cardCta: {
    backgroundColor: Colors.cyan,
    borderRadius: Radius.lg,
    height: 56,
    alignItems: "center",
    justifyContent: "center",
    boxShadow: `0 0 12px ${Colors.cyanGlow}`,
    elevation: 4,
  },
  cardCtaText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.base,
    color: "#000",
    fontWeight: "600",
  },
});
