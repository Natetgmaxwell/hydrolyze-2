/**
 * WorkoutDetail — shows workout info and allows starting a session.
 * Route: /workout/[id]
 */
import { useCallback, useState } from "react";
import {
  View,
  Text,
  TouchableOpacity,
  StyleSheet,
  ScrollView,
  Alert,
  Platform,
} from "react-native";
import { useRouter, useLocalSearchParams, useFocusEffect } from "expo-router";
import { supabase } from "../../lib/supabase";
import { useAuth } from "../../context/AuthContext";
import { parseWorkoutV2 } from "../../lib/workout-parser-v2";
import type { Workout } from "../../lib/workout-types";
import WorkoutPreview from "../../components/WorkoutPreview";
import {
  Colors,
  FontFamily,
  FontSize,
  Space,
  Radius,
  TouchTarget,
} from "../../lib/theme";

interface WorkoutSet {
  id: string;
  order_index: number;
  reps: number;
  distance: number;
  stroke: string;
  interval_text: string | null;
  gear: string | null;
  intensity_type: string | null;
  intensity_label: string | null;
  pace_target_distance: number | null;
  drill: string | null;
}

interface WorkoutDetail {
  id: string;
  title: string | null;
  status: string;
  scheduled_at: string | null;
  am_pm: string | null;
  workout_text: string | null;
  sets: WorkoutSet[];
  parsedWorkout: Workout | null;
}

function formatDate(dateStr: string) {
  const d = new Date(dateStr + "T00:00:00");
  return d
    .toLocaleDateString("en-US", {
      weekday: "short",
      month: "short",
      day: "numeric",
    })
    .toUpperCase();
}

export default function WorkoutDetailScreen() {
  const router = useRouter();
  const { coachId } = useAuth();
  const { id } = useLocalSearchParams<{ id: string }>();
  const [workout, setWorkout] = useState<WorkoutDetail | null>(null);
  const [loading, setLoading] = useState(true);

  useFocusEffect(
    useCallback(() => {
      loadWorkout();
    }, [id, coachId]),
  );

  async function loadWorkout() {
    if (!id || !coachId) {
      setLoading(false);
      return;
    }
    setLoading(true);
    const [{ data: w }, { data: sets }] = await Promise.all([
      supabase
        .from("workouts")
        .select("id, title, status, scheduled_at, am_pm, workout_text")
        .eq("id", id!)
        .maybeSingle(),
      supabase
        .from("workout_sets")
        .select(
          "id, order_index, reps, distance, stroke, interval_text, gear, intensity_type, intensity_label, pace_target_distance, drill",
        )
        .eq("workout_id", id!)
        .order("order_index"),
    ]);

    if (w) {
      const pw = w.workout_text
        ? parseWorkoutV2(w.workout_text)
        : { title: null, sections: [] };
      setWorkout({ ...w, sets: sets ?? [], parsedWorkout: pw });
    }
    setLoading(false);
  }

  async function handleStartSession() {
    if (!id) return;
    await supabase
      .from("workouts")
      .update({ status: "in_progress" })
      .eq("id", id);
    router.push(`/session/set-picker?workoutId=${id}`);
  }

  async function handleMarkComplete() {
    if (!id) return;
    const { error } = await supabase
      .from("workouts")
      .update({ status: "complete" })
      .eq("id", id);

    if (error) {
      if (Platform.OS === "web") window.alert(`Error: ${error.message}`);
      else Alert.alert("Error", error.message);
    } else {
      setWorkout((prev) => (prev ? { ...prev, status: "complete" } : null));
    }
  }

  async function handleDelete() {
    if (!id) return;

    const title = "Delete Workout?";
    const message =
      "This cannot be undone and will remove all associated set data.";

    const performDelete = async () => {
      try {
        console.log("[WorkoutDetail] Deleting workout:", id);
        const { error } = await supabase.from("workouts").delete().eq("id", id);
        if (error) {
          console.error("[WorkoutDetail] Delete error:", error);
          throw error;
        }
        console.log("[WorkoutDetail] Delete successful");
        router.replace("/(tabs)/workouts");
      } catch (err) {
        const msg = err instanceof Error ? err.message : JSON.stringify(err);
        console.error("[WorkoutDetail] Catch error:", msg);
        if (Platform.OS === "web") {
          window.alert(`Error deleting workout: ${msg}`);
        } else {
          Alert.alert("Error deleting workout", msg);
        }
      }
    };

    if (Platform.OS === "web") {
      if (window.confirm(`${title}\n\n${message}`)) {
        performDelete();
      }
    } else {
      Alert.alert(title, message, [
        { text: "Cancel", style: "cancel" },
        {
          text: "Delete",
          style: "destructive",
          onPress: performDelete,
        },
      ]);
    }
  }

  if (loading) {
    return (
      <View style={styles.center}>
        <Text style={styles.loadingText}>Loading...</Text>
      </View>
    );
  }

  if (!workout) {
    return (
      <View style={styles.center}>
        <Text style={styles.errorText}>Workout not found.</Text>
        <TouchableOpacity
          style={styles.backButton}
          onPress={() => router.back()}
        >
          <Text style={styles.backButtonText}>Go Back</Text>
        </TouchableOpacity>
      </View>
    );
  }

  return (
    <ScrollView style={styles.scroll} contentContainerStyle={styles.container}>
      <Text style={styles.screenLabel}>WORKOUT</Text>

      {/* Title + date */}
      <Text style={styles.title}>{workout.title ?? "Untitled Workout"}</Text>
      <View style={styles.metaRow}>
        {workout.scheduled_at && (
          <Text style={styles.meta}>{formatDate(workout.scheduled_at)}</Text>
        )}
        {workout.am_pm && <Text style={styles.meta}>{workout.am_pm}</Text>}
        <Text style={styles.statusBadge}>
          {workout.status.replace("_", " ")}
        </Text>
      </View>

      {/* Parsed preview */}
      {workout.parsedWorkout && workout.parsedWorkout.sections.length > 0 ? (
        <WorkoutPreview workout={workout.parsedWorkout} />
      ) : (
        <Text style={styles.noPreviewText}>No preview available</Text>
      )}

      {/* Edit Workout */}
      {workout.status !== "complete" && (
        <TouchableOpacity
          style={styles.editButton}
          onPress={() => router.push(`/workout/new?workoutId=${id}`)}
          activeOpacity={0.7}
        >
          <Text style={styles.editButtonText}>Edit Workout</Text>
        </TouchableOpacity>
      )}

      {workout.status === "complete" ? (
        <TouchableOpacity
          style={styles.startButton}
          onPress={() => router.push(`/session/results?workoutId=${id}`)}
          activeOpacity={0.85}
        >
          <Text style={styles.startButtonText}>View Results</Text>
        </TouchableOpacity>
      ) : (
        <>
          <TouchableOpacity
            style={styles.startButton}
            onPress={handleStartSession}
            activeOpacity={0.85}
          >
            <Text style={styles.startButtonText}>
              {workout.status === "scheduled"
                ? "Start Session"
                : workout.status === "in_progress"
                  ? "Continue Session"
                  : "Start Workout"}
            </Text>
          </TouchableOpacity>

          {workout.status === "in_progress" && (
            <TouchableOpacity
              style={styles.secondaryButton}
              onPress={handleMarkComplete}
              activeOpacity={0.7}
            >
              <Text style={styles.secondaryButtonText}>Mark as Complete</Text>
            </TouchableOpacity>
          )}

          {workout.status !== "scheduled" && (
            <TouchableOpacity
              style={styles.secondaryButton}
              onPress={() =>
                router.push(`/workout/set-schedule?workoutId=${id}`)
              }
              activeOpacity={0.7}
            >
              <Text style={styles.secondaryButtonText}>Schedule Workout</Text>
            </TouchableOpacity>
          )}

          {workout.status === "scheduled" && (
            <TouchableOpacity
              style={styles.secondaryButton}
              onPress={() =>
                router.push(
                  `/workout/set-schedule?workoutId=${id}&initialDate=${workout.scheduled_at}&initialAmPm=${workout.am_pm ?? "AM"}`,
                )
              }
              activeOpacity={0.7}
            >
              <Text style={styles.secondaryButtonText}>Reschedule</Text>
            </TouchableOpacity>
          )}
        </>
      )}

      <View style={styles.dangerZone}>
        <TouchableOpacity
          style={styles.deleteButton}
          onPress={handleDelete}
          activeOpacity={0.7}
        >
          <Text style={styles.deleteButtonText}>Delete Workout</Text>
        </TouchableOpacity>
      </View>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  scroll: { flex: 1, backgroundColor: Colors.base },
  container: { padding: Space[6], paddingBottom: Space[12] },
  center: {
    flex: 1,
    backgroundColor: Colors.base,
    alignItems: "center",
    justifyContent: "center",
  },
  screenLabel: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.xs,
    color: Colors.dim,
    letterSpacing: 1.2,
    marginBottom: Space[3],
  },
  title: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.xl,
    color: Colors.text,
    marginBottom: Space[3],
  },
  metaRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: Space[3],
    marginBottom: Space[8],
  },
  meta: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.sm,
    color: Colors.muted,
  },
  statusBadge: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.xs,
    color: Colors.amber,
    textTransform: "capitalize",
  },
  sectionLabel: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.xs,
    color: Colors.dim,
    letterSpacing: 0.8,
    marginBottom: Space[4],
  },
  setRow: {
    flexDirection: "row",
    alignItems: "center",
    backgroundColor: Colors.surface,
    borderRadius: Radius.md,
    padding: Space[4],
    marginBottom: Space[2],
    borderWidth: 1,
    borderColor: Colors.border,
  },
  setIndex: {
    fontFamily: FontFamily.mono,
    fontSize: FontSize.lg,
    color: Colors.cyan,
    width: 28,
    textAlign: "center",
    marginRight: Space[3],
  },
  setInfo: { flex: 1 },
  setLabel: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.base,
    color: Colors.text,
  },
  setGear: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.sm,
    color: Colors.muted,
    marginTop: 2,
  },
  setIntensity: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.sm,
    color: Colors.amber,
    marginTop: 2,
  },
  setInterval: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.sm,
    color: Colors.dim,
  },
  editButton: {
    marginTop: Space[8],
    backgroundColor: Colors.cyan,
    borderRadius: Radius.lg,
    height: TouchTarget.min,
    alignItems: "center",
    justifyContent: "center",
    boxShadow: `0 0 12px ${Colors.cyanGlow}`,
    elevation: 4,
  },
  editButtonText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.base,
    color: "#000",
    fontWeight: "600",
  },
  startButton: {
    marginTop: Space[8],
    backgroundColor: Colors.cyan,
    borderRadius: Radius.lg,
    height: TouchTarget.lap,
    alignItems: "center",
    justifyContent: "center",
    boxShadow: `0 0 12px ${Colors.cyanGlow}`,
    elevation: 4,
  },
  startButtonText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.lg,
    color: "#000",
    fontWeight: "600",
  },
  secondaryButton: {
    marginTop: Space[3],
    backgroundColor: Colors.surface,
    borderRadius: Radius.lg,
    borderWidth: 1,
    borderColor: Colors.border,
    height: TouchTarget.min,
    alignItems: "center",
    justifyContent: "center",
  },
  secondaryButtonText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.base,
    color: Colors.muted,
  },
  dangerZone: {
    marginTop: Space[12],
    borderTopWidth: 1,
    borderTopColor: Colors.border,
    paddingTop: Space[4],
  },
  deleteButton: {
    height: TouchTarget.min,
    backgroundColor: Colors.dangerSurface,
    borderRadius: Radius.md,
    borderWidth: 1,
    borderColor: "rgba(239,68,68,0.3)",
    alignItems: "center",
    justifyContent: "center",
  },
  deleteButtonText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.sm,
    color: Colors.danger,
  },
  backButton: {
    marginTop: Space[4],
    backgroundColor: Colors.cyan,
    borderRadius: Radius.lg,
    paddingHorizontal: Space[6],
    height: TouchTarget.min,
    alignItems: "center",
    justifyContent: "center",
  },
  backButtonText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.base,
    color: "#000",
  },
  loadingText: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.base,
    color: Colors.muted,
  },
  errorText: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.base,
    color: Colors.muted,
    marginBottom: Space[4],
  },
  noPreviewText: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.sm,
    color: Colors.dim,
    fontStyle: "italic",
    textAlign: "center",
    marginTop: Space[4],
  },
});
