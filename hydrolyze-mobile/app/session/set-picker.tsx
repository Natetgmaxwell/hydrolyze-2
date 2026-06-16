/**
 * SetPicker — multi-set navigation hub.
 *
 * Loads the workout from Supabase, re-parses workout_text through parseWorkoutV2,
 * and renders the structured tree using shared WorkoutPreview atoms.
 * Completed sets show a checkmark. Tapping any non-completed set
 * begins the session flow for that set.
 *
 * Route: /session/set-picker?workoutId=UUID
 */

import { useEffect, useState, useMemo } from "react";
import {
  View,
  Text,
  TouchableOpacity,
  StyleSheet,
  ScrollView,
  Pressable,
} from "react-native";
import { useRouter, useLocalSearchParams } from "expo-router";
import { supabase } from "../../lib/supabase";
import { useAuth } from "../../context/AuthContext";
import { useWorkout } from "../../context/WorkoutContext";
import { parseWorkoutV2 } from "../../lib/workout-parser-v2";
import type { Workout } from "../../lib/workout-types";
import WorkoutPreview, {
  RepGroupRow,
  SectionHeader,
} from "../../components/WorkoutPreview";
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
  intensity_type: string | null;
  intensity_label: string | null;
  interval_text: string | null;
  gear: string | null;
  drill: string | null;
}

interface WorkoutData {
  id: string;
  title: string | null;
  am_pm: string | null;
  scheduled_at: string | null;
  status: string;
  workout_text: string | null;
  sets: WorkoutSet[];
}

export default function SetPickerScreen() {
  const { workoutId } = useLocalSearchParams<{ workoutId: string }>();
  const { coachId } = useAuth();
  const { state } = useWorkout();
  const router = useRouter();
  const [workout, setWorkout] = useState<WorkoutData | null>(null);
  const [loading, setLoading] = useState(true);
  const [completedSetIds, setCompletedSetIds] = useState<Set<string>>(
    new Set(),
  );

  const parsedWorkout: Workout | null = useMemo(() => {
    if (!workout?.workout_text) return null;
    return parseWorkoutV2(workout.workout_text);
  }, [workout?.workout_text]);

  const setsByIndex = useMemo(() => {
    if (!workout?.sets) return new Map<number, WorkoutSet>();
    return new Map(workout.sets.map((s) => [s.order_index, s]));
  }, [workout?.sets]);

  useEffect(() => {
    if (!workoutId || !coachId) return;
    loadWorkout();
  }, [workoutId, coachId]);

  async function loadWorkout() {
    setLoading(true);
    const [{ data: workoutData }, { data: setsData }, { data: timesData }] =
      await Promise.all([
        supabase
          .from("workouts")
          .select("id, title, am_pm, scheduled_at, status, workout_text")
          .eq("id", workoutId!)
          .single(),
        supabase
          .from("workout_sets")
          .select("*")
          .eq("workout_id", workoutId!)
          .order("order_index"),
        supabase
          .from("recorded_times")
          .select("workout_set_id")
          .eq("workout_id", workoutId!),
      ]);

    if (workoutData) {
      setWorkout({ ...workoutData, sets: setsData ?? [] });
    }

    const completed = new Set(
      (timesData ?? [])
        .map((t: { workout_set_id: string | null }) => t.workout_set_id)
        .filter((id): id is string => !!id),
    );
    setCompletedSetIds(completed);

    setLoading(false);
  }

  function handleSelectSet(setId: string, setIndex: number) {
    if (completedSetIds.has(setId)) return;
    const hasAttendance = state.attendanceList.length > 0;
    router.push(
      `/session/attendance?workoutId=${workoutId}&setId=${setId}${hasAttendance ? "&auto=true" : ""}`,
    );
  }

  function handleStartSession() {
    const firstUncompleted = workout?.sets.find(
      (s) => !completedSetIds.has(s.id),
    );
    if (!firstUncompleted) return;
    const hasAttendance = state.attendanceList.length > 0;
    router.push(
      `/session/attendance?workoutId=${workoutId}&setId=${firstUncompleted.id}${hasAttendance ? "&auto=true" : ""}`,
    );
  }

  if (!workoutId) {
    return (
      <View style={styles.emptyContainer}>
        <Text style={styles.emptyText}>No workout selected.</Text>
        <TouchableOpacity
          style={styles.emptyButton}
          onPress={() => router.replace("/(tabs)/today")}
        >
          <Text style={styles.emptyButtonText}>Go to Today</Text>
        </TouchableOpacity>
      </View>
    );
  }

  if (loading) {
    return (
      <View style={styles.container}>
        <Text style={styles.loadingText}>Loading...</Text>
      </View>
    );
  }

  if (!workout) {
    return (
      <View style={styles.emptyContainer}>
        <Text style={styles.emptyText}>Workout not found.</Text>
      </View>
    );
  }

  const completedCount = completedSetIds.size;
  const allDone = completedCount === workout.sets.length;

  let repGroupIndex = 0;

  return (
    <View style={styles.container}>
      <ScrollView
        style={styles.scroll}
        contentContainerStyle={styles.scrollContent}
      >
        <Text style={styles.screenLabel}>WORKOUT</Text>

        {workout.title && (
          <Text style={styles.workoutTitle}>{workout.title}</Text>
        )}
        <Text style={styles.progressLabel}>
          {completedCount}/{workout.sets.length} sets complete
        </Text>

        {parsedWorkout ? (
          <View>
            {parsedWorkout.sections.map((section, si) => (
              <View key={si}>
                <SectionHeader section={section} />
                {section.namedSets.map((ns, ni) => (
                  <View key={ni}>
                    {ns.label && (
                      <Text style={styles.namedSetLabel}>
                        {ns.label
                          .replace(/\s*\(\d+\s*m?\)\s*$/i, "")
                          .toUpperCase()}
                      </Text>
                    )}
                    {ns.repGroups.map((rg, gi) => {
                      const setId = setsByIndex.get(repGroupIndex)?.id ?? null;
                      const isDone = setId ? completedSetIds.has(setId) : false;
                      const currentIndex = repGroupIndex;
                      repGroupIndex++;

                      if (!setId) {
                        return (
                          <View key={gi} style={styles.setRow}>
                            <RepGroupRow rg={rg} />
                          </View>
                        );
                      }

                      return (
                        <Pressable
                          key={gi}
                          style={[styles.setRow, isDone && styles.setRowDone]}
                          onPress={() => handleSelectSet(setId, currentIndex)}
                          disabled={isDone}
                        >
                          <RepGroupRow
                            rg={rg}
                            showAffordance
                            affordance={isDone ? "done" : "start"}
                          />
                        </Pressable>
                      );
                    })}
                  </View>
                ))}
              </View>
            ))}
          </View>
        ) : (
          <View style={styles.fallbackContainer}>
            <Text style={styles.fallbackText}>
              Re-save this workout to enable full preview
            </Text>
            {workout.sets.map((set, index) => {
              const isDone = completedSetIds.has(set.id);
              return (
                <View key={set.id} style={styles.fallbackRow}>
                  <Text style={styles.setLabel}>
                    {set.reps}×{set.distance}m {set.stroke}
                  </Text>
                  {isDone && <Text style={styles.checkmark}>✓</Text>}
                </View>
              );
            })}
          </View>
        )}
      </ScrollView>

      <View style={styles.footer}>
        {allDone ? (
          <TouchableOpacity
            style={styles.primaryButton}
            onPress={() =>
              router.push(`/session/results?workoutId=${workoutId}`)
            }
            activeOpacity={0.85}
          >
            <Text style={styles.primaryButtonText}>View Results</Text>
          </TouchableOpacity>
        ) : (
          <TouchableOpacity
            style={styles.primaryButton}
            onPress={handleStartSession}
            activeOpacity={0.85}
          >
            <Text style={styles.primaryButtonText}>
              {completedCount > 0 ? "Continue Session" : "Start Session"}
            </Text>
          </TouchableOpacity>
        )}
        <TouchableOpacity
          style={styles.secondaryButton}
          onPress={() => router.push("/(tabs)/workouts")}
          activeOpacity={0.7}
        >
          <Text style={styles.secondaryButtonText}>Back to Workouts</Text>
        </TouchableOpacity>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: Colors.base },
  scroll: { flex: 1 },
  scrollContent: { padding: Space[6], paddingBottom: Space[12] },
  loadingText: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.base,
    color: Colors.muted,
    marginTop: Space[12],
    textAlign: "center",
  },
  screenLabel: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.xs,
    color: Colors.dim,
    letterSpacing: 1.2,
    marginBottom: Space[2],
  },
  workoutTitle: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.xl,
    color: Colors.text,
    marginBottom: Space[1],
  },
  progressLabel: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.sm,
    color: Colors.muted,
    marginBottom: Space[6],
  },
  setRow: {
    backgroundColor: Colors.surface,
    borderRadius: Radius.md,
    padding: Space[4],
    marginBottom: Space[3],
    borderWidth: 1,
    borderColor: Colors.border,
  },
  setRowDone: { opacity: 0.5, borderColor: Colors.optimal },
  namedSetLabel: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.xs,
    color: Colors.cyan,
    letterSpacing: 0.8,
    marginBottom: Space[2],
  },
  footer: {
    padding: Space[4],
    borderTopWidth: 1,
    borderTopColor: Colors.border,
    backgroundColor: Colors.surface,
  },
  primaryButton: {
    backgroundColor: Colors.cyan,
    borderRadius: Radius.lg,
    height: TouchTarget.lap,
    alignItems: "center",
    justifyContent: "center",
    marginBottom: Space[3],
    boxShadow: `0 0 12px ${Colors.cyanGlow}`,
    elevation: 4,
  },
  primaryButtonText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.lg,
    color: "#000",
    fontWeight: "600",
  },
  secondaryButton: {
    height: 44,
    alignItems: "center",
    justifyContent: "center",
  },
  secondaryButtonText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.sm,
    color: Colors.muted,
    letterSpacing: 0.8,
  },
  emptyContainer: {
    flex: 1,
    backgroundColor: Colors.base,
    alignItems: "center",
    justifyContent: "center",
    padding: Space[6],
  },
  emptyText: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.lg,
    color: Colors.muted,
    marginBottom: Space[6],
    textAlign: "center",
  },
  emptyButton: {
    backgroundColor: Colors.cyan,
    borderRadius: Radius.lg,
    height: TouchTarget.lap,
    paddingHorizontal: Space[8],
    alignItems: "center",
    justifyContent: "center",
  },
  emptyButtonText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.base,
    color: "#000",
    fontWeight: "600",
  },
  fallbackContainer: {
    backgroundColor: Colors.surface,
    borderRadius: Radius.md,
    padding: Space[4],
    borderWidth: 1,
    borderColor: Colors.border,
  },
  fallbackText: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.xs,
    color: Colors.muted,
    fontStyle: "italic",
    marginBottom: Space[3],
  },
  fallbackRow: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingVertical: Space[2],
  },
  setLabel: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.base,
    color: Colors.text,
  },
  checkmark: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.base,
    color: Colors.optimal,
  },
});
