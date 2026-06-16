/**
 * Swimmer add/edit modal sheet.
 * Route: /swimmer-sheet (modal presentation)
 * Query params:
 *   - id?: string — present means edit mode, prefills existing swimmer
 */

import { useState, useEffect, useCallback } from "react";
import {
  View,
  Text,
  TextInput,
  TouchableOpacity,
  StyleSheet,
  ScrollView,
  KeyboardAvoidingView,
  Platform,
} from "react-native";
import { useLocalSearchParams, useRouter, useFocusEffect } from "expo-router";
import DateTimePicker from "@react-native-community/datetimepicker";
import { useAuth } from "../context/AuthContext";
import {
  getGroups,
  createSwimmer,
  updateSwimmer,
  type Swimmer,
} from "../lib/swimmers";
import {
  Colors,
  FontFamily,
  FontSize,
  Space,
  Radius,
  TouchTarget,
} from "../lib/theme";

export default function SwimmerSheetScreen() {
  const { id } = useLocalSearchParams<{ id?: string }>();
  const { coachId } = useAuth();
  const router = useRouter();
  const isEdit = !!id;

  const [firstName, setFirstName] = useState("");
  const [lastName, setLastName] = useState("");
  const [birthdate, setBirthdate] = useState<Date | null>(null);
  const [showDatePicker, setShowDatePicker] = useState(false);
  const [gender, setGender] = useState<"M" | "F" | "X">("X");
  const [notes, setNotes] = useState("");
  const [selectedGroupIds, setSelectedGroupIds] = useState<Set<string>>(
    new Set(),
  );
  const [groups, setGroups] = useState<{ id: string; name: string }[]>([]);
  const [saving, setSaving] = useState(false);

  useFocusEffect(
    useCallback(() => {
      if (!coachId) return;
      getGroups(coachId).then(setGroups);
    }, [coachId]),
  );

  useEffect(() => {
    if (!id || !coachId) return;
    loadSwimmer(id);
  }, [id, coachId]);

  async function loadSwimmer(swimmerId: string) {
    const { supabase } = await import("../lib/supabase");
    const { data } = await supabase
      .from("swimmers")
      .select("first_name, last_name, birthdate, gender, notes, archived_at")
      .eq("id", swimmerId)
      .single();

    if (!data || data.archived_at) return;

    setFirstName(data.first_name ?? "");
    setLastName(data.last_name ?? "");
    if (data.birthdate) setBirthdate(new Date(data.birthdate + "T00:00:00"));
    if (data.gender && ["M", "F", "X"].includes(data.gender))
      setGender(data.gender as "M" | "F" | "X");
    setNotes(data.notes ?? "");

    const { data: memberships } = await supabase
      .from("swimmer_groups")
      .select("group_id")
      .eq("swimmer_id", swimmerId);
    setSelectedGroupIds(new Set(memberships?.map((m) => m.group_id) ?? []));
  }

  function toggleGroup(groupId: string) {
    setSelectedGroupIds((prev) => {
      const next = new Set(prev);
      if (next.has(groupId)) next.delete(groupId);
      else next.add(groupId);
      return next;
    });
  }

  function formatDate(d: Date): string {
    return d.toLocaleDateString("en-US", {
      month: "short",
      day: "numeric",
      year: "numeric",
    });
  }

  async function handleSave() {
    if (!firstName.trim() || !coachId) return;
    setSaving(true);
    try {
      if (isEdit && id) {
        await updateSwimmer(
          id,
          {
            firstName: firstName.trim(),
            lastName: lastName.trim() || null,
            birthdate: birthdate ? birthdate.toISOString().slice(0, 10) : null,
            gender: gender === "X" ? null : gender,
            notes: notes.trim() || null,
          },
          [...selectedGroupIds],
        );
      } else {
        await createSwimmer({
          coachId,
          firstName: firstName.trim(),
          lastName: lastName.trim() || null,
          birthdate: birthdate ? birthdate.toISOString().slice(0, 10) : null,
          gender: gender === "X" ? null : gender,
          notes: notes.trim() || null,
          groupIds: [...selectedGroupIds],
        });
      }
      router.back();
    } catch (err) {
      setSaving(false);
    }
  }

  const canSave = firstName.trim().length > 0;

  return (
    <KeyboardAvoidingView
      behavior={Platform.OS === "ios" ? "padding" : "height"}
      style={styles.container}
    >
      {/* Header */}
      <View style={styles.header}>
        <TouchableOpacity onPress={() => router.back()}>
          <Text style={styles.cancelBtn}>Cancel</Text>
        </TouchableOpacity>
        <Text style={styles.headerTitle}>
          {isEdit ? "Edit Swimmer" : "Add Swimmer"}
        </Text>
        <TouchableOpacity onPress={handleSave} disabled={!canSave || saving}>
          <Text
            style={[
              styles.saveBtn,
              (!canSave || saving) && styles.saveBtnDisabled,
            ]}
          >
            {saving ? "Saving..." : "Save"}
          </Text>
        </TouchableOpacity>
      </View>

      <ScrollView
        style={styles.scroll}
        contentContainerStyle={styles.scrollContent}
        keyboardShouldPersistTaps="handled"
      >
        {/* First Name */}
        <View style={styles.field}>
          <Text style={styles.label}>FIRST NAME *</Text>
          <TextInput
            style={styles.input}
            value={firstName}
            onChangeText={setFirstName}
            placeholder="e.g. Nate"
            placeholderTextColor={Colors.dim}
            autoFocus
            autoCapitalize="words"
            returnKeyType="next"
          />
        </View>

        {/* Last Name */}
        <View style={styles.field}>
          <Text style={styles.label}>LAST NAME</Text>
          <TextInput
            style={styles.input}
            value={lastName}
            onChangeText={setLastName}
            placeholder="e.g. Maxwell"
            placeholderTextColor={Colors.dim}
            autoCapitalize="words"
            returnKeyType="done"
          />
        </View>

        {/* Birthdate */}
        <View style={styles.field}>
          <Text style={styles.label}>BIRTHDATE</Text>
          <TouchableOpacity
            style={styles.dateField}
            onPress={() => setShowDatePicker(true)}
            activeOpacity={0.7}
          >
            <Text style={birthdate ? styles.dateText : styles.datePlaceholder}>
              {birthdate ? formatDate(birthdate) : "Tap to set"}
            </Text>
          </TouchableOpacity>
          {showDatePicker && Platform.OS !== "web" && (
            <DateTimePicker
              value={birthdate ?? new Date()}
              mode="date"
              display="spinner"
              onChange={(_event, picked) => {
                setShowDatePicker(Platform.OS === "ios");
                if (picked) setBirthdate(picked);
              }}
              maximumDate={new Date()}
              themeVariant="dark"
            />
          )}
          {showDatePicker && Platform.OS === "web" && (
            <input
              type="date"
              value={birthdate ? birthdate.toISOString().split("T")[0] : ""}
              onChange={(e) => {
                const d = new Date(e.target.value);
                if (!isNaN(d.getTime())) setBirthdate(d);
              }}
              style={{
                backgroundColor: Colors.surface,
                color: Colors.text,
                border: `1px solid ${Colors.border}`,
                borderRadius: Radius.md,
                padding: `${Space[2]}px ${Space[4]}px`,
                fontFamily: FontFamily.ui,
                fontSize: "16px",
                width: "100%",
                marginTop: Space[2],
                outline: "none",
              }}
            />
          )}
        </View>

        {/* Gender */}
        <View style={styles.field}>
          <Text style={styles.label}>GENDER</Text>
          <View style={styles.segmented}>
            {(["M", "F", "X"] as const).map((g) => (
              <TouchableOpacity
                key={g}
                style={[styles.segment, gender === g && styles.segmentActive]}
                onPress={() => setGender(g)}
                activeOpacity={0.7}
              >
                <Text
                  style={[
                    styles.segmentText,
                    gender === g && styles.segmentTextActive,
                  ]}
                >
                  {g === "X" ? "—" : g}
                </Text>
              </TouchableOpacity>
            ))}
          </View>
        </View>

        {/* Groups */}
        {groups.length > 0 && (
          <View style={styles.field}>
            <Text style={styles.label}>GROUPS</Text>
            <View style={styles.chips}>
              {groups.map((g) => (
                <TouchableOpacity
                  key={g.id}
                  style={[
                    styles.chip,
                    selectedGroupIds.has(g.id) && styles.chipActive,
                  ]}
                  onPress={() => toggleGroup(g.id)}
                  activeOpacity={0.7}
                >
                  <Text
                    style={[
                      styles.chipText,
                      selectedGroupIds.has(g.id) && styles.chipTextActive,
                    ]}
                  >
                    {g.name}
                  </Text>
                </TouchableOpacity>
              ))}
            </View>
          </View>
        )}

        {/* Notes */}
        <View style={styles.field}>
          <Text style={styles.label}>NOTES</Text>
          <TextInput
            style={[styles.input, styles.notesInput]}
            value={notes}
            onChangeText={setNotes}
            placeholder="Optional notes..."
            placeholderTextColor={Colors.dim}
            multiline
            numberOfLines={3}
            textAlignVertical="top"
          />
        </View>
      </ScrollView>
    </KeyboardAvoidingView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: Colors.base },
  header: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingHorizontal: Space[6],
    paddingVertical: Space[4],
    borderBottomWidth: 1,
    borderBottomColor: Colors.border,
  },
  headerTitle: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: 17,
    color: Colors.text,
  },
  cancelBtn: { fontFamily: FontFamily.ui, fontSize: 17, color: Colors.cyan },
  saveBtn: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: 17,
    color: Colors.cyan,
  },
  saveBtnDisabled: { color: Colors.dim },
  scroll: { flex: 1 },
  scrollContent: { padding: Space[6], paddingBottom: Space[12] },
  field: { marginBottom: Space[6] },
  label: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.xs,
    color: Colors.dim,
    letterSpacing: 0.8,
    marginBottom: Space[2],
  },
  input: {
    backgroundColor: Colors.elevated,
    borderWidth: 1,
    borderColor: Colors.border,
    borderRadius: Radius.md,
    paddingVertical: Space[3],
    paddingHorizontal: Space[4],
    fontFamily: FontFamily.ui,
    fontSize: 17,
    color: Colors.text,
  },
  notesInput: { minHeight: 80, paddingTop: Space[3] },
  dateField: {
    backgroundColor: Colors.elevated,
    borderWidth: 1,
    borderColor: Colors.border,
    borderRadius: Radius.md,
    paddingVertical: Space[3],
    paddingHorizontal: Space[4],
  },
  dateText: { fontFamily: FontFamily.ui, fontSize: 17, color: Colors.text },
  datePlaceholder: {
    fontFamily: FontFamily.ui,
    fontSize: 17,
    color: Colors.dim,
  },
  segmented: {
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
    paddingVertical: Space[2] + 2,
    alignItems: "center",
    borderRadius: Radius.md - 2,
  },
  segmentActive: { backgroundColor: Colors.cyan },
  segmentText: {
    fontFamily: FontFamily.uiMedium,
    fontSize: 15,
    color: Colors.muted,
  },
  segmentTextActive: { color: Colors.base },
  chips: { flexDirection: "row", flexWrap: "wrap", gap: Space[2] },
  chip: {
    paddingHorizontal: Space[3],
    paddingVertical: Space[1] + 2,
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
});
