import { useState, useEffect, useMemo } from "react";
import {
  View,
  Text,
  ScrollView,
  TouchableOpacity,
  StyleSheet,
  Alert,
  Platform,
  ActivityIndicator,
  Dimensions,
} from "react-native";
import { useRouter, useLocalSearchParams } from "expo-router";
import { GestureHandlerRootView } from "react-native-gesture-handler";
import { supabase } from "../../lib/supabase";
import { useWorkout } from "../../context/WorkoutContext";
import { clearSavedWorkout as clearSavedSession } from "../../context/WorkoutContext";
import { SwimmerCard } from "../../components/SwimmerCard";
import { WorkoutTrendChart } from "../../components/WorkoutTrendChart";
import {
  Colors,
  FontFamily,
  FontSize,
  Space,
  Radius,
  TouchTarget,
} from "../../lib/theme";
import type { IntensityLevel } from "../../lib/set-parser";

interface HistoricalTime {
  id: string;
  swimmer_id: string;
  swimmers: { name: string };
  time_ms: number;
  rep_index: number;
  intensity: string;
  workout_set_id: string;
  workout_sets: {
    reps: number;
    distance: number;
    stroke: string;
    gear: string | null;
  };
}

function welfordUpdate(mean: number, m2: number, count: number, value: number) {
  count += 1;
  const delta = value - mean;
  mean += delta / count;
  const delta2 = value - mean;
  m2 += delta * delta2;
  return { mean, m2, count };
}

function formatTime(ms: number) {
  const mins = Math.floor(ms / 60000);
  const secs = Math.floor((ms % 60000) / 1000);
  const tenths = Math.floor((ms % 1000) / 100);
  if (mins > 0) return `${mins}:${String(secs).padStart(2, "0")}.${tenths}`;
  return `${secs}.${tenths}`;
}

export default function ResultsScreen() {
  const router = useRouter();
  const { workoutId: queryWorkoutId } = useLocalSearchParams<{
    workoutId?: string;
  }>();
  const { state, dispatch, syncPayload } = useWorkout();
  const { currentSet, attendanceList } = state;

  const [saving, setSaving] = useState(false);
  const [loadingHistorical, setLoadingHistorical] = useState(false);
  const [historicalTimes, setHistoricalTimes] = useState<HistoricalTime[]>([]);

  const isReviewMode = !currentSet && !!queryWorkoutId;

  useEffect(() => {
    if (isReviewMode && queryWorkoutId) {
      const loadData = async () => {
        setLoadingHistorical(true);
        try {
          console.log(
            "[Results] Review Mode: Loading results for:",
            queryWorkoutId,
          );
          const { data, error } = await supabase
            .from("recorded_times")
            .select(
              `
              id, swimmer_id, time_ms, rep_index, intensity, workout_set_id,
              swimmers(name),
              workout_sets(reps, distance, stroke, gear)
            `,
            )
            .eq("workout_id", queryWorkoutId)
            .order("created_at", { ascending: true });

          if (error) throw error;
          setHistoricalTimes((data as any) ?? []);
        } catch (err) {
          console.error("[Results] Load error:", err);
        } finally {
          setLoadingHistorical(false);
        }
      };
      loadData();
    }
  }, [isReviewMode, queryWorkoutId]);

  const swimmerMap = Object.fromEntries(
    attendanceList.map((s) => [s.id, s.name]),
  );
  const needsAttention = syncPayload.filter((t) => !t.assignment);
  const assigned = syncPayload.filter((t) => !!t.assignment);

  function handleDelete(id: string) {
    dispatch({ type: "DELETE_TIME", payload: { id } });
  }

  function handleSwap(id: string) {
    const assignedIds = new Set(
      syncPayload
        .filter((t) => !!t.assignment)
        .map((t) => t.assignment!.swimmerId),
    );
    const options = attendanceList.filter((s) => !assignedIds.has(s.id));
    Alert.alert("Assign to swimmer", undefined, [
      ...options.map((s) => ({
        text: s.name,
        onPress: () =>
          dispatch({ type: "ASSIGN_TIME", payload: { id, swimmerId: s.id } }),
      })),
      { text: "Cancel", style: "cancel" },
    ]);
  }

  async function handleSave(startNext: boolean) {
    if (!currentSet) {
      Alert.alert("Error", "No active set. Please go back and start a set.");
      return;
    }
    const { workoutId, setIndex } = currentSet;

    if (syncPayload.length === 0) {
      await clearSavedSession();
      dispatch({ type: "SET_COMPLETE", payload: { setIndex } });
      dispatch({ type: "END_SET" });
      router.replace(`/session/set-picker?workoutId=${workoutId}`);
      return;
    }

    if (needsAttention.length > 0) {
      const msg = `${needsAttention.length} time(s) need attention.`;
      if (Platform.OS === "web") window.alert(msg);
      else Alert.alert("Unresolved times", msg);
      return;
    }

    setSaving(true);
    try {
      const { stroke, gear, distance, paceTargetDistance } = currentSet;
      const effectiveGear = gear ?? "none";
      const effectiveDist = paceTargetDistance ?? distance;

      const rows = syncPayload.map((t) => ({
        swimmer_id: t.assignment!.swimmerId,
        workout_set_id: currentSet.id,
        workout_id: workoutId,
        time_ms: t.elapsedMs,
        rep_index: t.repNumber,
        intensity: t.intensity ?? "moderate",
        gear: gear,
      }));

      const insertResult = await new Promise<any>((resolve, reject) => {
        const timer = setTimeout(
          () =>
            reject(
              new Error("Save timed out after 10s — check network connection"),
            ),
          10000,
        );
        Promise.resolve(supabase.from("recorded_times").insert(rows))
          .then((result: any) => {
            clearTimeout(timer);
            resolve(result);
          })
          .catch((err: any) => {
            clearTimeout(timer);
            reject(err);
          });
      });
      if (insertResult?.error) throw insertResult.error;

      // Intensity calibrations
      const pendingCalibs: any[] = [];
      const statsCache = state.statsCache;
      for (const t of syncPayload) {
        if (!t.assignment) continue;
        const intensity = t.intensity ?? "moderate";
        const cacheKey = `${t.assignment.swimmerId}:${stroke}:${effectiveDist}:${intensity}:${effectiveGear}`;
        const stats = statsCache[cacheKey];
        if (stats?.pb_predicted_ms) {
          pendingCalibs.push({
            swimmerId: t.assignment.swimmerId,
            stroke,
            intensity,
            gear: effectiveGear,
            ratio: t.elapsedMs / stats.pb_predicted_ms,
          });
        }
      }

      if (pendingCalibs.length > 0) {
        const swimmerIds = [...new Set(pendingCalibs.map((p) => p.swimmerId))];
        const { data: existing } = await supabase
          .from("swimmer_intensity_calibrations")
          .select(
            "swimmer_id, stroke, intensity, gear, multiplier_mean, multiplier_m2, sample_count",
          )
          .in("swimmer_id", swimmerIds);

        const working = new Map<string, any>();
        for (const row of existing ?? []) {
          const k = `${row.swimmer_id}:${row.stroke}:${row.intensity}:${row.gear ?? "none"}`;
          working.set(k, {
            mean: row.multiplier_mean,
            m2: row.multiplier_m2,
            count: row.sample_count,
          });
        }

        for (const p of pendingCalibs) {
          const k = `${p.swimmerId}:${p.stroke}:${p.intensity}:${p.gear}`;
          const prev = working.get(k) ?? { mean: 1.0, m2: 0.0, count: 0 };
          working.set(
            k,
            welfordUpdate(prev.mean, prev.m2, prev.count, p.ratio),
          );
        }

        const upsertRows = [...working.entries()].map(([k, v]) => {
          const [swimmerId, s, intensity, g] = k.split(":");
          return {
            swimmer_id: swimmerId,
            stroke: s,
            intensity,
            gear: g,
            multiplier_mean: v.mean,
            multiplier_m2: v.m2,
            sample_count: v.count,
            updated_at: new Date().toISOString(),
          };
        });
        await supabase
          .from("swimmer_intensity_calibrations")
          .upsert(upsertRows, {
            onConflict: "swimmer_id,stroke,intensity,gear",
          });
      }

      await clearSavedSession();
      dispatch({ type: "SET_COMPLETE", payload: { setIndex } });
      dispatch({ type: "END_SET" });
      router.replace(`/session/set-picker?workoutId=${workoutId}`);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      if (Platform.OS === "web") window.alert(`Save failed: ${msg}`);
      else Alert.alert("Save failed", msg);
    } finally {
      setSaving(false);
    }
  }

  const handleReviewDone = async () => {
    const targetId = String(queryWorkoutId || state.workout?.id || "");
    if (targetId) {
      console.log(
        "[Results] Review finished. Marking workout COMPLETE:",
        targetId,
      );

      const { error } = await supabase
        .from("workouts")
        .update({ status: "complete" })
        .eq("id", targetId);

      if (error) {
        console.error("[Results] Supabase Error Details:", error);
        if (Platform.OS === "web")
          window.alert(`Could not mark workout as complete: ${error.message}`);
      } else {
        console.log("[Results] Workout status updated successfully.");
      }
    }
    dispatch({ type: "END_WORKOUT" });
    router.replace("/(tabs)/workouts");
  };

  const consolidatedResults = useMemo(() => {
    if (!historicalTimes.length) return [];
    const groupsMap = new Map<
      string,
      {
        props: {
          distance: number;
          stroke: string;
          gear: string | null;
          intensity: string;
        };
        totalReps: number;
        swimmers: Map<
          string,
          { name: string; times: { rep: number; time: number }[] }
        >;
      }
    >();

    historicalTimes.forEach((t) => {
      const props = {
        distance: t.workout_sets?.distance,
        stroke: t.workout_sets?.stroke,
        gear: t.workout_sets?.gear,
        intensity: t.intensity,
      };
      const key = `${props.distance}-${props.stroke}-${props.gear}-${props.intensity}`;
      if (!groupsMap.has(key)) {
        groupsMap.set(key, { props, totalReps: 0, swimmers: new Map() });
      }
      const group = groupsMap.get(key)!;
      if (!group.swimmers.has(t.swimmer_id)) {
        group.swimmers.set(t.swimmer_id, {
          name: t.swimmers?.name ?? "Unknown",
          times: [],
        });
      }
      const swimmerGroup = group.swimmers.get(t.swimmer_id)!;
      swimmerGroup.times.push({
        rep: swimmerGroup.times.length + 1,
        time: t.time_ms,
      });
      if (swimmerGroup.times.length > group.totalReps)
        group.totalReps = swimmerGroup.times.length;
    });

    return Array.from(groupsMap.values()).map((g) => ({
      ...g,
      swimmers: Array.from(g.swimmers.values()),
    }));
  }, [historicalTimes]);

  if (loadingHistorical) {
    return (
      <View style={[styles.container, styles.center]}>
        <ActivityIndicator color={Colors.cyan} size="large" />
        <Text style={styles.loadingText}>Loading results...</Text>
      </View>
    );
  }

  if (isReviewMode) {
    const chartWidth = Dimensions.get("window").width - Space[16];
    return (
      <View style={styles.container}>
        <View style={styles.header}>
          <Text style={styles.screenLabel}>WORKOUT RESULTS</Text>
          <Text style={styles.setDesc}>Workout Summary</Text>
        </View>
        <ScrollView
          style={styles.list}
          contentContainerStyle={styles.listContent}
        >
          {consolidatedResults.length === 0 ? (
            <View style={styles.emptyResults}>
              <Text style={styles.emptyText}>No times recorded.</Text>
            </View>
          ) : (
            consolidatedResults.map((group, gIdx) => (
              <View key={gIdx} style={styles.setCard}>
                <View style={styles.setCardHeaderRow}>
                  <Text style={styles.setCardHeader}>
                    {group.totalReps} × {group.props.distance}m{" "}
                    {group.props.stroke}
                  </Text>
                  {group.props.gear && group.props.gear !== "none" && (
                    <View style={styles.gearBadge}>
                      <Text style={styles.gearBadgeText}>
                        {group.props.gear}
                      </Text>
                    </View>
                  )}
                  {group.props.intensity !== "moderate" && (
                    <Text style={styles.intensityLabel}>
                      {group.props.intensity}
                    </Text>
                  )}
                </View>
                {group.swimmers.map((swimmer, swimmerIdx) => (
                  <View key={swimmerIdx} style={styles.swimmerRow}>
                    <View style={styles.swimmerHeader}>
                      <Text style={styles.swimmerName}>{swimmer.name}</Text>
                      <Text style={styles.avgTime}>
                        Avg:{" "}
                        {formatTime(
                          swimmer.times.reduce((acc, t) => acc + t.time, 0) /
                            swimmer.times.length,
                        )}
                      </Text>
                    </View>
                    <WorkoutTrendChart
                      times={swimmer.times}
                      width={chartWidth}
                      height={60}
                    />
                    <ScrollView
                      horizontal
                      showsHorizontalScrollIndicator={false}
                      style={styles.timesScroll}
                    >
                      {swimmer.times.map((t, tIdx) => (
                        <View key={tIdx} style={styles.timePill}>
                          <Text style={styles.repLabel}>R{t.rep}</Text>
                          <Text style={styles.timeLabel}>
                            {formatTime(t.time)}
                          </Text>
                        </View>
                      ))}
                    </ScrollView>
                  </View>
                ))}
              </View>
            ))
          )}
        </ScrollView>
        <View style={styles.footer}>
          <TouchableOpacity
            style={styles.primaryButton}
            onPress={handleReviewDone}
            activeOpacity={0.85}
          >
            <Text style={styles.primaryButtonText}>Done</Text>
          </TouchableOpacity>
        </View>
      </View>
    );
  }

  const setDesc = currentSet
    ? `${currentSet.reps} × ${currentSet.distance}m ${currentSet.stroke}`
    : "";

  return (
    <GestureHandlerRootView style={styles.container}>
      <View style={styles.header}>
        <Text style={styles.screenLabel}>SET RESULTS</Text>
        <Text style={styles.setDesc}>{setDesc}</Text>
      </View>
      <ScrollView style={styles.list}>
        {needsAttention.concat(assigned).map((t) => (
          <SwimmerCard
            key={t.id}
            time={t}
            swimmerName={
              t.assignment ? swimmerMap[t.assignment.swimmerId] : undefined
            }
            onDelete={handleDelete}
            onSwap={handleSwap}
          />
        ))}
      </ScrollView>
      <View style={styles.footer}>
        <TouchableOpacity
          style={[styles.primaryButton, saving && styles.buttonDisabled]}
          onPress={() => handleSave(true)}
          disabled={saving}
          activeOpacity={0.85}
        >
          <Text style={styles.primaryButtonText}>
            {saving ? "Saving..." : "Save & Start Next Set"}
          </Text>
        </TouchableOpacity>
        <TouchableOpacity
          style={[styles.secondaryButton, saving && styles.buttonDisabled]}
          onPress={() => handleSave(false)}
          disabled={saving}
          activeOpacity={0.7}
        >
          <Text style={styles.secondaryButtonText}>
            {saving ? "Saving..." : "End Session"}
          </Text>
        </TouchableOpacity>
      </View>
    </GestureHandlerRootView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: Colors.base },
  center: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    backgroundColor: Colors.base,
  },
  header: {
    paddingHorizontal: Space[6],
    paddingTop: Space[6],
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
  setDesc: {
    fontFamily: FontFamily.monoMedium,
    fontSize: FontSize.base,
    color: Colors.muted,
  },
  list: { flex: 1 },
  listContent: { padding: Space[4] },
  footer: {
    padding: Space[4],
    gap: Space[2],
    borderTopWidth: 1,
    borderTopColor: Colors.border,
  },
  primaryButton: {
    backgroundColor: Colors.cyan,
    borderRadius: Radius.lg,
    height: TouchTarget.lap,
    alignItems: "center",
    justifyContent: "center",
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
    backgroundColor: Colors.elevated,
    borderRadius: Radius.lg,
    height: TouchTarget.min,
    alignItems: "center",
    justifyContent: "center",
    borderWidth: 1,
    borderColor: Colors.border,
  },
  secondaryButtonText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.base,
    color: Colors.muted,
  },
  buttonDisabled: { opacity: 0.4 },
  loadingText: {
    marginTop: Space[4],
    color: Colors.muted,
    fontFamily: FontFamily.ui,
  },
  emptyResults: { padding: Space[12], alignItems: "center" },
  emptyText: {
    color: Colors.dim,
    fontFamily: FontFamily.ui,
    textAlign: "center",
  },
  setCard: {
    backgroundColor: Colors.surface,
    borderRadius: Radius.lg,
    padding: Space[4],
    marginBottom: Space[4],
    borderWidth: 1,
    borderColor: Colors.border,
  },
  setCardHeaderRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: Space[2],
    marginBottom: Space[4],
    flexWrap: "wrap",
  },
  setCardHeader: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.base,
    color: Colors.cyan,
    letterSpacing: 0.5,
  },
  gearBadge: {
    backgroundColor: Colors.elevated,
    paddingHorizontal: Space[2],
    paddingVertical: 2,
    borderRadius: Radius.sm,
    borderWidth: 1,
    borderColor: Colors.border,
  },
  gearBadgeText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: 9,
    color: Colors.dim,
    textTransform: "uppercase",
  },
  intensityLabel: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.xs,
    color: Colors.muted,
  },
  swimmerRow: {
    marginBottom: Space[6],
    borderTopWidth: 1,
    borderTopColor: "rgba(255,255,255,0.05)",
    paddingTop: Space[3],
  },
  swimmerHeader: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    marginBottom: Space[2],
  },
  swimmerName: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.sm,
    color: Colors.text,
  },
  avgTime: {
    fontFamily: FontFamily.monoMedium,
    fontSize: 10,
    color: Colors.dim,
  },
  timesScroll: { flexDirection: "row", marginTop: Space[2] },
  timePill: {
    backgroundColor: Colors.elevated,
    borderRadius: Radius.md,
    paddingHorizontal: Space[3],
    paddingVertical: Space[2],
    marginRight: Space[2],
    minWidth: 70,
    alignItems: "center",
    borderWidth: 1,
    borderColor: Colors.border,
  },
  repLabel: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: 9,
    color: Colors.dim,
    textTransform: "uppercase",
    marginBottom: 2,
  },
  timeLabel: {
    fontFamily: FontFamily.monoMedium,
    fontSize: FontSize.sm,
    color: Colors.cyan,
  },
});
