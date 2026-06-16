/**
 * Workouts tab — list all workouts with filters, create, and manage.
 * Route: /(tabs)/workouts
 */

import { useEffect, useState, useCallback } from "react";
import {
  View,
  Text,
  FlatList,
  TouchableOpacity,
  StyleSheet,
  Alert,
  Platform,
} from "react-native";
import { useRouter, useFocusEffect } from "expo-router";
import { supabase } from "../../lib/supabase";
import { withTimeout } from "../../lib/supabase-helpers";
import { useAuth } from "../../context/AuthContext";
import {
  Colors,
  FontFamily,
  FontSize,
  Space,
  Radius,
  TouchTarget,
} from "../../lib/theme";

type Filter = "all" | "scheduled" | "draft" | "complete";
type WorkoutStatus = "draft" | "scheduled" | "in_progress" | "complete";

interface WorkoutRow {
  id: string;
  title: string | null;
  status: WorkoutStatus;
  scheduled_at: string | null;
  am_pm: string | null;
}

export default function WorkoutsScreen() {
  const { coachId } = useAuth();
  const router = useRouter();
  const [filter, setFilter] = useState<Filter>("all");
  const [workouts, setWorkouts] = useState<WorkoutRow[]>([]);
  const [loading, setLoading] = useState(true);

  useFocusEffect(
    useCallback(() => {
      if (!coachId) return;
      loadWorkouts();
    }, [coachId, filter]),
  );

  async function loadWorkouts() {
    setLoading(true);
    let query = supabase
      .from("workouts")
      .select("id, title, status, scheduled_at, am_pm")
      .eq("coach_id", coachId)
      .order("scheduled_at", { ascending: false });

    if (filter === "scheduled") query = query.eq("status", "scheduled");
    else if (filter === "draft") query = query.eq("status", "draft");
    else if (filter === "complete") query = query.eq("status", "complete");

    const { data } = await query;
    setWorkouts(data ?? []);
    setLoading(false);
  }

  async function handleDelete(workout: WorkoutRow) {
    const title = "Delete Workout?";
    const message = `Are you sure you want to delete "${workout.title ?? "Untitled workout"}"?`;

    const performDelete = async () => {
      try {
        console.log("[Workouts] Deleting workout:", workout.id);
        await withTimeout(
          supabase.from("workouts").delete().eq("id", workout.id),
          10000,
        );
        console.log("[Workouts] Delete successful");
        loadWorkouts();
      } catch (err) {
        const msg = err instanceof Error ? err.message : JSON.stringify(err);
        console.error("[Workouts] Catch error:", msg);
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

  const filters: Filter[] = ["all", "scheduled", "draft", "complete"];

  return (
    <View style={styles.container}>
      {/* Header */}
      <View style={styles.header}>
        <View>
          <Text style={styles.screenLabel}>WORKOUTS</Text>
          <Text style={styles.screenHint}>Long-press to delete</Text>
        </View>
        <TouchableOpacity
          style={styles.createButton}
          onPress={() => router.push("/workout/new")}
          activeOpacity={0.85}
        >
          <Text style={styles.createButtonText}>+ New</Text>
        </TouchableOpacity>
      </View>

      {/* Filter pills */}
      <View style={styles.filterRow}>
        {filters.map((f) => (
          <TouchableOpacity
            key={f}
            style={[styles.filterPill, filter === f && styles.filterPillActive]}
            onPress={() => setFilter(f)}
          >
            <Text
              style={[
                styles.filterText,
                filter === f && styles.filterTextActive,
              ]}
            >
              {f.charAt(0).toUpperCase() + f.slice(1)}
            </Text>
          </TouchableOpacity>
        ))}
      </View>

      {/* List */}
      <FlatList
        data={workouts}
        keyExtractor={(w) => w.id}
        style={styles.list}
        contentContainerStyle={styles.listContent}
        refreshing={loading}
        onRefresh={loadWorkouts}
        ListEmptyComponent={
          <View style={styles.empty}>
            <Text style={styles.emptyText}>No workouts</Text>
          </View>
        }
        renderItem={({ item }) => (
          <TouchableOpacity
            style={styles.workoutRow}
            onPress={() => router.push(`/workout/${item.id}`)}
            onLongPress={() => handleDelete(item)}
            activeOpacity={0.7}
          >
            <View style={styles.rowLeft}>
              {item.scheduled_at && (
                <Text style={styles.rowDate}>
                  {formatDate(item.scheduled_at)}
                </Text>
              )}
              <Text style={styles.rowTitle}>{item.title ?? "Untitled"}</Text>
              {item.status === "draft" && (
                <Text style={styles.rowStatusDraft}>Draft</Text>
              )}
              {item.status === "complete" && (
                <Text style={styles.rowStatusComplete}>Complete</Text>
              )}
              {item.status === "in_progress" && (
                <Text style={styles.rowStatusActive}>In Progress</Text>
              )}
            </View>
            <View style={styles.rowRight}>
              {item.am_pm && <Text style={styles.rowAmPm}>{item.am_pm}</Text>}
              <Text style={styles.chevron}>›</Text>
            </View>
          </TouchableOpacity>
        )}
        ItemSeparatorComponent={() => <View style={styles.separator} />}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: Colors.base },
  header: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingHorizontal: Space[6],
    paddingTop: Space[12],
    paddingBottom: Space[4],
  },
  screenLabel: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.xs,
    color: Colors.dim,
    letterSpacing: 1.2,
  },
  screenHint: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.xs,
    color: Colors.muted,
    marginTop: 2,
  },
  createButton: {
    backgroundColor: Colors.cyan,
    borderRadius: Radius.lg,
    paddingHorizontal: Space[4],
    paddingVertical: Space[2],
    height: 36,
    alignItems: "center",
    justifyContent: "center",
  },
  createButtonText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.sm,
    color: "#000",
    fontWeight: "600",
  },
  filterRow: {
    flexDirection: "row",
    gap: Space[2],
    paddingHorizontal: Space[6],
    paddingBottom: Space[4],
    borderBottomWidth: 1,
    borderBottomColor: Colors.border,
  },
  filterPill: {
    paddingHorizontal: Space[3],
    paddingVertical: Space[1],
    borderRadius: Radius.sm,
    borderWidth: 1,
    borderColor: Colors.border,
    backgroundColor: Colors.surface,
  },
  filterPillActive: {
    borderColor: Colors.cyan,
    backgroundColor: Colors.cyanDim,
  },
  filterText: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.sm,
    color: Colors.muted,
  },
  filterTextActive: { color: Colors.cyan },
  list: { flex: 1 },
  listContent: { paddingBottom: Space[8] },
  workoutRow: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    height: TouchTarget.swimRow,
    paddingHorizontal: Space[6],
  },
  rowLeft: { flex: 1 },
  rowDate: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.xs,
    color: Colors.dim,
    letterSpacing: 0.5,
    marginBottom: 2,
  },
  rowTitle: {
    fontFamily: FontFamily.uiMedium,
    fontSize: FontSize.base,
    color: Colors.text,
  },
  rowStatusDraft: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: 10,
    color: Colors.amber,
    marginTop: 4,
    textTransform: "uppercase",
    letterSpacing: 0.5,
  },
  rowStatusComplete: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: 10,
    color: Colors.optimal,
    marginTop: 4,
    textTransform: "uppercase",
    letterSpacing: 0.5,
  },
  rowStatusActive: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: 10,
    color: Colors.cyan,
    marginTop: 4,
    textTransform: "uppercase",
    letterSpacing: 0.5,
  },
  rowRight: { flexDirection: "row", alignItems: "center", gap: Space[3] },
  rowAmPm: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.xs,
    color: Colors.amber,
  },
  chevron: { fontFamily: FontFamily.ui, fontSize: 20, color: Colors.border },
  separator: {
    height: 1,
    backgroundColor: Colors.border,
    marginHorizontal: Space[6],
  },
  empty: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    paddingTop: Space[12],
  },
  emptyText: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.base,
    color: Colors.dim,
  },
});
