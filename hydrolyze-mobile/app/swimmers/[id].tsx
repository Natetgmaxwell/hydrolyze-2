/**
 * Swimmer detail screen — name, groups, PBs, recent times.
 * Route: /swimmers/[id]
 */

import { useCallback, useState } from "react";
import {
  View,
  Text,
  FlatList,
  TouchableOpacity,
  StyleSheet,
  Alert,
  TextInput,
  ScrollView,
  Platform,
  Modal,
  useWindowDimensions,
} from "react-native";
import { useRouter, useLocalSearchParams, useFocusEffect } from "expo-router";
import { supabase } from "../../lib/supabase";
import { withTimeout } from "../../lib/supabase-helpers";
import { useAuth } from "../../context/AuthContext";
import { getInitials } from "../../lib/swimmers";
import {
  Colors,
  FontFamily,
  FontSize,
  Space,
  Radius,
  TouchTarget,
} from "../../lib/theme";

const STROKES = ["Free", "Back", "Breast", "Fly", "IM"];
const DISTANCES = [25, 50, 100, 200, 400, 800, 1500];

interface Group {
  id: string;
  name: string;
}

interface SwimmerPB {
  id: string;
  distance: number;
  stroke: string;
  time_ms: number;
  gear: string | null;
  recorded_at: string;
}

function parseTime(raw: string): number | null {
  const trimmed = raw.trim();
  const withMinutes = trimmed.match(/^(\d+):(\d{1,2})(?:\.(\d+))?$/);
  if (withMinutes) {
    const mins = parseInt(withMinutes[1], 10);
    const secs = parseInt(withMinutes[2], 10);
    const frac = withMinutes[3] ? parseFloat(`0.${withMinutes[3]}`) : 0;
    if (secs >= 60) return null;
    return Math.round((mins * 60 + secs + frac) * 1000);
  }
  const secsOnly = trimmed.match(/^(\d+)(?:\.(\d+))?$/);
  if (secsOnly) {
    const secs = parseInt(secsOnly[1], 10);
    const frac = secsOnly[2] ? parseFloat(`0.${secsOnly[2]}`) : 0;
    return Math.round((secs + frac) * 1000);
  }
  return null;
}

export default function SwimmerDetailScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { coachId } = useAuth();
  const router = useRouter();
  const { width: screenWidth } = useWindowDimensions();

  const [swimmer, setSwimmer] = useState<{
    id: string;
    first_name: string;
    last_name: string | null;
    form_stroke: string | null;
  } | null>(null);
  const [groups, setGroups] = useState<Group[]>([]);
  const [allGroups, setAllGroups] = useState<Group[]>([]);
  const [pbs, setPBs] = useState<SwimmerPB[]>([]);
  const [editingName, setEditingName] = useState(false);
  const [nameInput, setNameInput] = useState("");
  const [loading, setLoading] = useState(true);

  // Modal state
  const [showModal, setShowModal] = useState(false);
  const [modalStroke, setModalStroke] = useState<string | null>("Free");
  const [modalDistance, setModalDistance] = useState<number | null>(50);
  const [timeInput, setTimeInput] = useState("");
  const [savingPB, setSavingPB] = useState(false);

  useFocusEffect(
    useCallback(() => {
      load();
    }, [id, coachId]),
  );

  async function load() {
    if (!id || !coachId) {
      setLoading(false);
      return;
    }
    setLoading(true);
    const [
      { data: swimmerData },
      { data: groupData },
      { data: allGroupData },
      { data: pbData },
    ] = await Promise.all([
      supabase
        .from("swimmers")
        .select("id, first_name, last_name, form_stroke")
        .eq("id", id!)
        .single(),
      supabase.from("swimmer_groups").select("group_id").eq("swimmer_id", id!),
      supabase
        .from("groups")
        .select("id, name")
        .eq("coach_id", coachId!)
        .order("name"),
      supabase
        .from("swimmer_pbs")
        .select("id, distance, stroke, time_ms, gear, recorded_at")
        .eq("swimmer_id", id!)
        .order("recorded_at", { ascending: false }),
    ]);

    setSwimmer(swimmerData);
    setNameInput(
      (swimmerData?.first_name ?? "") +
        (swimmerData?.last_name ? ` ${swimmerData.last_name}` : ""),
    );
    setGroups(
      (groupData ?? [])
        .map(
          (g: { group_id: string }) =>
            allGroupData?.find((x) => x.id === g.group_id)!,
        )
        .filter(Boolean),
    );
    setAllGroups(allGroupData ?? []);
    setPBs(pbData ?? []);
    setLoading(false);
  }

  async function updateSwimmerName() {
    if (!nameInput.trim() || !swimmer) return;
    const parts = nameInput.trim().split(/\s+/);
    const firstName = parts[0] ?? "";
    const lastName = parts.length > 1 ? parts.slice(1).join(" ") : null;
    await supabase
      .from("swimmers")
      .update({ first_name: firstName, last_name: lastName })
      .eq("id", swimmer.id);
    setSwimmer({ ...swimmer, first_name: firstName, last_name: lastName });
    setEditingName(false);
  }

  async function updateFormStroke(stroke: string) {
    if (!swimmer) return;
    const { error } = await supabase
      .from("swimmers")
      .update({ form_stroke: stroke })
      .eq("id", swimmer.id);
    if (error) {
      Platform.OS === "web"
        ? window.alert(error.message)
        : Alert.alert("Error", error.message);
      return;
    }
    setSwimmer({ ...swimmer, form_stroke: stroke });
  }

  async function toggleGroupMembership(group: Group) {
    if (!swimmer) return;
    const isMember = groups.some((g) => g.id === group.id);
    if (isMember) {
      await supabase
        .from("swimmer_groups")
        .delete()
        .eq("swimmer_id", swimmer.id)
        .eq("group_id", group.id);
      setGroups(groups.filter((g) => g.id !== group.id));
    } else {
      await supabase
        .from("swimmer_groups")
        .insert({ swimmer_id: swimmer.id, group_id: group.id });
      setGroups([...groups, group]);
    }
  }

  async function handleAddPB() {
    if (!modalStroke || !modalDistance || !timeInput.trim() || !id) return;
    const ms = parseTime(timeInput);
    if (!ms || ms <= 0) {
      const msg = "Enter a time like 25.4 or 1:03.5";
      Platform.OS === "web"
        ? window.alert(msg)
        : Alert.alert("Invalid time", msg);
      return;
    }

    setSavingPB(true);
    const { error } = await withTimeout(
      supabase.from("swimmer_pbs").upsert(
        {
          swimmer_id: id,
          stroke: modalStroke,
          distance: modalDistance,
          time_ms: ms,
          recorded_at: new Date().toISOString(),
        },
        { onConflict: "swimmer_id,stroke,distance,gear" },
      ),
      10000,
    );

    setSavingPB(false);
    if (error) {
      Platform.OS === "web"
        ? window.alert(error.message)
        : Alert.alert("Error", error.message);
      return;
    }

    setShowModal(false);
    setTimeInput("");
    load();
  }

  async function deletePB(pbId: string) {
    const confirmed =
      Platform.OS === "web"
        ? window.confirm("Remove this personal best?")
        : await new Promise<boolean>((resolve) => {
            Alert.alert("Delete PB", "Remove this personal best?", [
              {
                text: "Cancel",
                style: "cancel",
                onPress: () => resolve(false),
              },
              {
                text: "Delete",
                style: "destructive",
                onPress: () => resolve(true),
              },
            ]);
          });
    if (!confirmed) return;

    await withTimeout(
      supabase.from("swimmer_pbs").delete().eq("id", pbId),
      10000,
    );
    load();
  }

  async function deleteSwimmer() {
    if (!swimmer) return;

    const confirmed =
      Platform.OS === "web"
        ? window.confirm(
            `Delete ${swimmer.first_name}${swimmer.last_name ? " " + swimmer.last_name : ""}?\n\nAll their times and PBs will be removed.`,
          )
        : await new Promise<boolean>((resolve) => {
            Alert.alert(
              `Delete ${swimmer.first_name}${swimmer.last_name ? " " + swimmer.last_name : ""}?`,
              "All their times and PBs will be removed.",
              [
                {
                  text: "Cancel",
                  style: "cancel",
                  onPress: () => resolve(false),
                },
                {
                  text: "Delete",
                  style: "destructive",
                  onPress: () => resolve(true),
                },
              ],
            );
          });
    if (!confirmed) return;

    const deleteResult = (await withTimeout(
      supabase.from("swimmers").delete({ count: "exact" }).eq("id", swimmer.id),
      10000,
    )) as any;
    const { error, count } = deleteResult;

    if (error) {
      const msg = `Could not delete: ${error.message}`;
      Platform.OS === "web" ? window.alert(msg) : Alert.alert("Error", msg);
      return;
    }
    if (!count) {
      const msg = "Delete blocked — you may not own this swimmer record (RLS).";
      Platform.OS === "web" ? window.alert(msg) : Alert.alert("Error", msg);
      return;
    }
    router.back();
  }

  function formatTime(ms: number): string {
    const mins = Math.floor(ms / 60000);
    const secs = Math.floor((ms % 60000) / 1000);
    const tenths = Math.floor((ms % 1000) / 100);
    if (mins > 0) return `${mins}:${String(secs).padStart(2, "0")}.${tenths}`;
    return `${secs}.${tenths}`;
  }

  if (loading) {
    return (
      <View style={styles.container}>
        <Text style={styles.loading}>Loading...</Text>
      </View>
    );
  }

  if (!swimmer) {
    return (
      <View style={styles.container}>
        <Text style={styles.loading}>Swimmer not found.</Text>
      </View>
    );
  }

  const canSave =
    modalStroke !== null &&
    modalDistance !== null &&
    timeInput.trim().length > 0;

  return (
    <ScrollView style={styles.scroll} contentContainerStyle={styles.container}>
      {/* Initials + Edit */}
      <View style={styles.initialsHeader}>
        <View style={styles.initialsCircle}>
          <Text style={styles.initialsText}>
            {getInitials(swimmer.first_name, swimmer.last_name)}
          </Text>
        </View>
        <TouchableOpacity
          style={styles.editBtn}
          onPress={() => router.push(`/swimmer-sheet?id=${swimmer.id}`)}
        >
          <Text style={styles.editBtnText}>Edit</Text>
        </TouchableOpacity>
      </View>

      {/* Name */}
      <View style={styles.nameRow}>
        {editingName ? (
          <View style={styles.nameEditRow}>
            <TextInput
              style={styles.nameInput}
              value={nameInput}
              onChangeText={setNameInput}
              autoFocus
              autoCapitalize="words"
            />
            <TouchableOpacity onPress={updateSwimmerName}>
              <Text style={styles.saveText}>Save</Text>
            </TouchableOpacity>
            <TouchableOpacity
              onPress={() => {
                setEditingName(false);
                setNameInput(
                  (swimmer.first_name ?? "") +
                    (swimmer.last_name ? " " + swimmer.last_name : ""),
                );
              }}
            >
              <Text style={styles.cancelText}>Cancel</Text>
            </TouchableOpacity>
          </View>
        ) : (
          <TouchableOpacity onPress={() => setEditingName(true)}>
            <Text style={styles.name}>
              {swimmer.first_name}
              {swimmer.last_name ? ` ${swimmer.last_name}` : ""}
            </Text>
          </TouchableOpacity>
        )}
      </View>

      {/* Form Stroke */}
      <View style={styles.section}>
        <Text style={styles.sectionLabel}>FORM STROKE</Text>
        <Text style={styles.sectionHint}>
          The stroke used when timing a "Form" set.
        </Text>
        <View style={styles.groupChips}>
          {["Free", "Back", "Breast", "Fly"].map((s) => {
            const active = swimmer.form_stroke === s;
            return (
              <TouchableOpacity
                key={s}
                style={[styles.chip, active && styles.chipActive]}
                onPress={() => updateFormStroke(s)}
              >
                <Text
                  style={[styles.chipText, active && styles.chipTextActive]}
                >
                  {s}
                </Text>
              </TouchableOpacity>
            );
          })}
        </View>
      </View>

      {/* Groups */}
      <View style={styles.section}>
        <Text style={styles.sectionLabel}>GROUPS</Text>
        <View style={styles.groupChips}>
          {allGroups.map((g) => {
            const isMember = groups.some((x) => x.id === g.id);
            return (
              <TouchableOpacity
                key={g.id}
                style={[styles.chip, isMember && styles.chipActive]}
                onPress={() => toggleGroupMembership(g)}
              >
                <Text
                  style={[styles.chipText, isMember && styles.chipTextActive]}
                >
                  {g.name}
                </Text>
              </TouchableOpacity>
            );
          })}
        </View>
      </View>

      {/* PBs */}
      <View style={styles.section}>
        <View style={styles.sectionHeader}>
          <Text style={styles.sectionLabel}>PERSONAL BESTS</Text>
          <TouchableOpacity onPress={() => setShowModal(true)}>
            <Text style={styles.addPBLink}>+ Add PB</Text>
          </TouchableOpacity>
        </View>
        {pbs.length === 0 ? (
          <Text style={styles.emptyText}>No personal bests recorded.</Text>
        ) : (
          <View style={styles.pbList}>
            {pbs.map((pb) => (
              <TouchableOpacity
                key={pb.id}
                style={styles.pbRow}
                onLongPress={() => deletePB(pb.id)}
              >
                <View style={styles.pbInfo}>
                  <Text style={styles.pbDetail}>
                    {pb.distance}m {pb.stroke}
                  </Text>
                  {pb.gear && pb.gear !== "none" && (
                    <Text style={styles.pbGear}>({pb.gear})</Text>
                  )}
                </View>
                <Text style={styles.pbTime}>{formatTime(pb.time_ms)}</Text>
              </TouchableOpacity>
            ))}
          </View>
        )}
      </View>

      {/* Danger zone */}
      <View style={styles.dangerZone}>
        <TouchableOpacity style={styles.deleteBtn} onPress={deleteSwimmer}>
          <Text style={styles.deleteBtnText}>Delete swimmer</Text>
        </TouchableOpacity>
      </View>

      {/* Add PB Modal */}
      <Modal
        visible={showModal}
        transparent
        animationType="slide"
        onRequestClose={() => setShowModal(false)}
      >
        <TouchableOpacity
          style={styles.backdrop}
          activeOpacity={1}
          onPress={() => setShowModal(false)}
        />
        <View style={styles.sheet}>
          <View style={styles.handle} />
          <Text style={styles.modalTitle}>Add Personal Best</Text>

          <Text style={styles.sectionLabel}>STROKE</Text>
          <View style={styles.optionRow}>
            {STROKES.map((s) => (
              <TouchableOpacity
                key={s}
                style={[
                  styles.optionChip,
                  modalStroke === s && styles.optionChipActive,
                ]}
                onPress={() => setModalStroke(s)}
              >
                <Text
                  style={[
                    styles.optionChipText,
                    modalStroke === s && styles.optionChipTextActive,
                  ]}
                >
                  {s}
                </Text>
              </TouchableOpacity>
            ))}
          </View>

          <Text style={styles.sectionLabel}>DISTANCE</Text>
          <View style={styles.optionRow}>
            {DISTANCES.map((d) => (
              <TouchableOpacity
                key={d}
                style={[
                  styles.optionChip,
                  modalDistance === d && styles.optionChipActive,
                ]}
                onPress={() => setModalDistance(d)}
              >
                <Text
                  style={[
                    styles.optionChipText,
                    modalDistance === d && styles.optionChipTextActive,
                  ]}
                >
                  {d}m
                </Text>
              </TouchableOpacity>
            ))}
          </View>

          <Text style={styles.sectionLabel}>TIME</Text>
          <TextInput
            style={styles.timeInput}
            value={timeInput}
            onChangeText={setTimeInput}
            placeholder="e.g. 25.4 or 1:03.5"
            placeholderTextColor={Colors.dim}
            keyboardType="numbers-and-punctuation"
            autoCorrect={false}
          />

          <TouchableOpacity
            style={[
              styles.saveButton,
              (!canSave || savingPB) && styles.saveButtonDisabled,
            ]}
            onPress={handleAddPB}
            disabled={!canSave || savingPB}
            activeOpacity={0.85}
          >
            <Text style={styles.saveButtonText}>
              {savingPB ? "Saving..." : "Save PB"}
            </Text>
          </TouchableOpacity>
        </View>
      </Modal>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  scroll: { flex: 1, backgroundColor: Colors.base },
  container: { padding: Space[6], paddingBottom: Space[12] },
  loading: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.base,
    color: Colors.muted,
    marginTop: Space[12],
  },
  initialsHeader: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    marginBottom: Space[6],
  },
  initialsCircle: {
    width: 56,
    height: 56,
    borderRadius: 28,
    backgroundColor: Colors.elevated,
    borderWidth: 1,
    borderColor: Colors.border,
    alignItems: "center",
    justifyContent: "center",
  },
  initialsText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: 20,
    color: Colors.cyan,
  },
  editBtn: {
    paddingHorizontal: Space[4],
    paddingVertical: Space[2],
    borderRadius: Radius.md,
    borderWidth: 1,
    borderColor: Colors.border,
    backgroundColor: Colors.elevated,
  },
  editBtnText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.sm,
    color: Colors.cyan,
  },
  nameRow: { marginBottom: Space[6] },
  name: { fontFamily: FontFamily.uiSemiBold, fontSize: 28, color: Colors.text },
  nameEditRow: { flexDirection: "row", alignItems: "center", gap: Space[3] },
  nameInput: {
    flex: 1,
    backgroundColor: Colors.elevated,
    borderRadius: Radius.md,
    paddingHorizontal: Space[3],
    paddingVertical: Space[2],
    fontFamily: FontFamily.ui,
    fontSize: FontSize.lg,
    color: Colors.text,
    borderWidth: 1,
    borderColor: Colors.cyan,
  },
  saveText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.sm,
    color: Colors.cyan,
  },
  cancelText: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.sm,
    color: Colors.dim,
  },
  section: { marginBottom: Space[6] },
  sectionHeader: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    marginBottom: Space[2],
  },
  sectionLabel: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.xs,
    color: Colors.dim,
    letterSpacing: 0.8,
    marginBottom: Space[2],
  },
  sectionHint: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.xs,
    color: Colors.muted,
    marginBottom: Space[3],
  },
  addPBLink: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.sm,
    color: Colors.cyan,
  },
  groupChips: { flexDirection: "row", flexWrap: "wrap", gap: Space[2] },
  chip: {
    paddingHorizontal: Space[3],
    paddingVertical: Space[1],
    borderRadius: Radius.sm,
    borderWidth: 1,
    borderColor: Colors.border,
    backgroundColor: Colors.elevated,
  },
  chipActive: { borderColor: Colors.cyan, backgroundColor: Colors.cyanDim },
  chipText: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.sm,
    color: Colors.muted,
  },
  chipTextActive: { color: Colors.cyan },
  pbList: { gap: Space[1] },
  pbRow: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingVertical: Space[2],
    borderBottomWidth: 1,
    borderBottomColor: Colors.border,
  },
  pbInfo: { flexDirection: "row", alignItems: "center", gap: Space[2] },
  pbDetail: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.base,
    color: Colors.text,
  },
  pbGear: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.xs,
    color: Colors.muted,
  },
  pbTime: {
    fontFamily: FontFamily.monoMedium,
    fontSize: FontSize.base,
    color: Colors.cyan,
  },
  emptyText: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.sm,
    color: Colors.dim,
  },
  dangerZone: {
    marginTop: Space[8],
    paddingTop: Space[6],
    borderTopWidth: 1,
    borderTopColor: Colors.border,
  },
  deleteBtn: {
    backgroundColor: Colors.dangerSurface,
    borderRadius: Radius.md,
    borderWidth: 1,
    borderColor: "rgba(239,68,68,0.3)",
    paddingVertical: Space[3],
    alignItems: "center",
  },
  deleteBtnText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.base,
    color: Colors.danger,
  },

  // Modal styles
  backdrop: { flex: 1, backgroundColor: "rgba(0,0,0,0.6)" },
  sheet: {
    backgroundColor: Colors.surface,
    borderTopLeftRadius: 20,
    borderTopRightRadius: 20,
    borderTopWidth: 1,
    borderColor: Colors.border,
    padding: Space[6],
    paddingBottom: Space[12],
    position: "absolute",
    bottom: 0,
    width: "100%",
  },
  handle: {
    width: 36,
    height: 4,
    borderRadius: 2,
    backgroundColor: Colors.border,
    alignSelf: "center",
    marginBottom: Space[4],
  },
  modalTitle: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.lg,
    color: Colors.text,
    marginBottom: Space[4],
  },
  optionRow: {
    flexDirection: "row",
    flexWrap: "wrap",
    gap: Space[2],
    marginBottom: Space[4],
  },
  optionChip: {
    paddingHorizontal: Space[3],
    paddingVertical: Space[2],
    borderRadius: Radius.md,
    backgroundColor: Colors.elevated,
    borderWidth: 1,
    borderColor: Colors.border,
  },
  optionChipActive: { backgroundColor: Colors.cyan, borderColor: Colors.cyan },
  optionChipText: {
    fontFamily: FontFamily.uiMedium,
    fontSize: FontSize.sm,
    color: Colors.muted,
  },
  optionChipTextActive: { color: "#000", fontFamily: FontFamily.uiSemiBold },
  timeInput: {
    backgroundColor: Colors.elevated,
    borderWidth: 1,
    borderColor: Colors.border,
    borderRadius: Radius.md,
    padding: Space[4],
    fontFamily: FontFamily.mono,
    fontSize: 28,
    color: Colors.text,
    textAlign: "center",
    marginBottom: Space[4],
  },
  saveButton: {
    backgroundColor: Colors.cyan,
    borderRadius: Radius.lg,
    height: TouchTarget.min,
    alignItems: "center",
    justifyContent: "center",
  },
  saveButtonDisabled: { opacity: 0.25 },
  saveButtonText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.base,
    color: "#000",
    fontWeight: "600",
  },
});
