/**
 * Schedule picker — shown after a workout is saved (or when rescheduling).
 * Coach picks a date + AM/PM, or uses a quick "Today AM/PM" chip.
 * Updates workout.scheduled_at, workout.am_pm, workout.status in Supabase.
 *
 * Route: /workout/set-schedule?workoutId=UUID
 *
 * If preloading from an existing scheduled workout (reschedule flow),
 * pass the current values as search params:
 * ?workoutId=X&initialDate=YYYY-MM-DD&initialAmPm=AM
 */
import { useState } from "react";
import {
  View,
  Text,
  TouchableOpacity,
  StyleSheet,
  ScrollView,
  Alert,
  Platform,
} from "react-native";
import DateTimePicker, {
  DateTimePickerEvent,
} from "@react-native-community/datetimepicker";
import { useRouter, useLocalSearchParams } from "expo-router";
import { supabase } from "../../lib/supabase";
import {
  Colors,
  FontFamily,
  FontSize,
  Space,
  Radius,
  TouchTarget,
} from "../../lib/theme";
import type { TextStyle } from "react-native";

const AM_PM_OPTIONS = [
  { label: "Morning", value: "AM" as const },
  { label: "Afternoon", value: "PM" as const },
] as const;

function formatDate(date: Date): string {
  return date.toLocaleDateString("en-US", {
    weekday: "short",
    month: "short",
    day: "numeric",
  });
}

function todayDateString(): string {
  return new Date().toISOString().split("T")[0];
}

function dateFromString(s: string | undefined): Date {
  return s ? new Date(s + "T00:00:00") : new Date();
}

function toLocalISODate(d: Date): string {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

function parseLocalDate(value: string): Date {
  const [y, m, d] = value.split("-").map(Number);
  return new Date(y, m - 1, d);
}

export default function ScheduleScreen() {
  const router = useRouter();
  const { workoutId, initialDate, initialAmPm } = useLocalSearchParams<{
    workoutId: string;
    initialDate?: string;
    initialAmPm?: string;
  }>();

  const [date, setDate] = useState<Date>(
    initialDate ? dateFromString(initialDate) : new Date(),
  );
  const [amPm, setAmPm] = useState<"AM" | "PM">(
    (initialAmPm as "AM" | "PM") ?? "AM",
  );
  const [saving, setSaving] = useState(false);
  const [showDatePicker, setShowDatePicker] = useState(false);

  if (!workoutId) {
    return (
      <View style={styles.container}>
        <Text style={styles.errorText}>No workout ID provided.</Text>
      </View>
    );
  }

  async function handleSave(startNow = false) {
    console.log(
      "[Schedule] handleSave called. startNow:",
      startNow,
      "workoutId:",
      workoutId,
    );
    setSaving(true);
    try {
      // Guard: check auth session before doing anything network-y
      const { data: sessionData } = await supabase.auth.getSession();
      if (
        !sessionData.session ||
        (sessionData.session.expires_at &&
          sessionData.session.expires_at * 1000 < Date.now())
      ) {
        const msg = "Session expired — please reload to sign in again";
        if (Platform.OS === "web") window.alert(msg);
        else Alert.alert("Session expired", msg);
        setSaving(false);
        return;
      }

      // Safely generate local date string YYYY-MM-DD
      const yyyy = date.getFullYear();
      const mm = String(date.getMonth() + 1).padStart(2, "0");
      const dd = String(date.getDate()).padStart(2, "0");
      const scheduledAt = `${yyyy}-${mm}-${dd}`;

      console.log("[Schedule] Updating workout status to scheduled...", {
        scheduledAt,
        amPm,
      });

      // Wrap UPDATE with 10s timeout
      const updatePromise = supabase
        .from("workouts")
        .update({
          scheduled_at: scheduledAt,
          am_pm: amPm,
          status: "scheduled",
          updated_at: new Date().toISOString(),
        })
        .eq("id", workoutId)
        .select();

      const { data, error, status } = await new Promise<any>(
        (resolve, reject) => {
          const timer = setTimeout(
            () =>
              reject(
                new Error(
                  "Request timed out after 10s — likely network or auth issue, try reloading",
                ),
              ),
            10000,
          );
          updatePromise
            .then((result: any) => {
              clearTimeout(timer);
              resolve(result);
            })
            .catch((err: any) => {
              clearTimeout(timer);
              reject(err);
            });
        },
      );

      console.log("[Schedule] Supabase response status:", status);

      if (error) {
        console.error("[Schedule] Supabase error:", error);
        throw error;
      }

      console.log("[Schedule] Update successful. Navigating...", { startNow });

      if (startNow) {
        router.replace(`/session/attendance?workoutId=${workoutId}`);
      } else {
        router.replace(`/workout/${workoutId}`);
      }
    } catch (err) {
      console.error("[Schedule] handleSave failed:", err);
      const msg = err instanceof Error ? err.message : JSON.stringify(err);
      if (Platform.OS === "web") window.alert(`Error saving schedule: ${msg}`);
      else Alert.alert("Error saving schedule", msg);
    } finally {
      setSaving(false);
    }
  }

  async function handleUnschedule() {
    setSaving(true);
    try {
      const { error } = await supabase
        .from("workouts")
        .update({
          scheduled_at: null,
          am_pm: null,
          status: "draft",
        })
        .eq("id", workoutId);

      if (error) throw error;
      router.replace(`/workout/${workoutId}`);
    } catch (err) {
      const msg = err instanceof Error ? err.message : JSON.stringify(err);
      if (Platform.OS === "web") window.alert(`Error: ${msg}`);
      else Alert.alert("Error", msg);
    } finally {
      setSaving(false);
    }
  }

  function handleDateChange(event: DateTimePickerEvent, selectedDate?: Date) {
    if (Platform.OS === "android") setShowDatePicker(false);
    if (selectedDate) setDate(selectedDate);
  }

  function handleTodayAmPm(selectedAmPm: "AM" | "PM") {
    setAmPm(selectedAmPm);
    setDate(new Date());
    setShowDatePicker(false);
  }

  const todayFormatted = formatDate(new Date());
  const dateFormatted = formatDate(date);
  const isToday = date.toISOString().split("T")[0] === todayDateString();

  return (
    <ScrollView
      style={styles.scroll}
      contentContainerStyle={styles.container}
      keyboardShouldPersistTaps="handled"
    >
      <Text style={styles.screenLabel}>SCHEDULE WORKOUT</Text>
      <Text style={styles.heading}>When is this workout?</Text>

      {/* Today AM / Today PM quick chips */}
      <View style={styles.section}>
        <Text style={styles.sectionLabel}>QUICK SCHEDULE</Text>
        <View style={styles.todayRow}>
          <TouchableOpacity
            style={[
              styles.todayChip,
              isToday && amPm === "AM" && styles.todayChipActive,
            ]}
            onPress={() => handleTodayAmPm("AM")}
            activeOpacity={0.8}
          >
            <Text
              style={[
                styles.todayChipText,
                isToday && amPm === "AM" && styles.todayChipTextActive,
              ]}
            >
              Today AM
            </Text>
          </TouchableOpacity>
          <TouchableOpacity
            style={[
              styles.todayChip,
              isToday && amPm === "PM" && styles.todayChipActive,
            ]}
            onPress={() => handleTodayAmPm("PM")}
            activeOpacity={0.8}
          >
            <Text
              style={[
                styles.todayChipText,
                isToday && amPm === "PM" && styles.todayChipTextActive,
              ]}
            >
              Today PM
            </Text>
          </TouchableOpacity>
        </View>
      </View>

      {/* Divider */}
      <View style={styles.dividerRow}>
        <View style={styles.dividerLine} />
        <Text style={styles.dividerText}>or pick a date</Text>
        <View style={styles.dividerLine} />
      </View>

      {/* Date picker */}
      <View style={styles.section}>
        <Text style={styles.sectionLabel}>DATE</Text>

        {/* Visible date label — tappable on iOS to open picker */}
        <TouchableOpacity
          style={styles.dateSelector}
          onPress={() => setShowDatePicker((v) => !v)}
          activeOpacity={0.8}
        >
          <Text style={styles.dateSelectorText}>{dateFormatted}</Text>
          <Text style={styles.dateSelectorChevron}>
            {showDatePicker ? "▲" : "▼"}
          </Text>
        </TouchableOpacity>

        {/* iOS inline picker (shown when tapped) */}
        {Platform.OS === "ios" && showDatePicker && (
          <View style={styles.datePickerCard}>
            <DateTimePicker
              value={date}
              mode="date"
              display="spinner"
              onChange={handleDateChange}
              style={styles.datePicker}
              textColor={Colors.text}
              minimumDate={new Date()}
            />
          </View>
        )}

        {/* Android picker */}
        {Platform.OS === "android" && showDatePicker && (
          <DateTimePicker
            value={date}
            mode="date"
            display="default"
            onChange={handleDateChange}
          />
        )}

        {/* Web picker fallback */}
        {Platform.OS === "web" && showDatePicker && (
          <View style={styles.webDatePickerContainer}>
            <input
              type="date"
              value={toLocalISODate(date)}
              onChange={(e) => {
                const d = parseLocalDate(e.target.value);
                if (!isNaN(d.getTime())) setDate(d);
              }}
              style={{
                backgroundColor: Colors.surface,
                color: Colors.text,
                border: `1px solid ${Colors.border}`,
                borderRadius: Radius.md,
                padding: Space[4],
                fontFamily: FontFamily.ui,
                fontSize: "16px",
                width: "100%",
                marginTop: Space[2],
                outline: "none",
              }}
            />
          </View>
        )}
      </View>

      {/* AM / PM toggle */}
      <View style={styles.section}>
        <Text style={styles.sectionLabel}>SESSION</Text>
        <View style={styles.amPmRow}>
          {AM_PM_OPTIONS.map((opt) => (
            <TouchableOpacity
              key={opt.value}
              style={[
                styles.amPmButton,
                amPm === opt.value && styles.amPmButtonActive,
              ]}
              onPress={() => setAmPm(opt.value)}
              activeOpacity={0.8}
            >
              <Text
                style={[
                  styles.amPmButtonText,
                  amPm === opt.value && styles.amPmButtonTextActive,
                ]}
              >
                {opt.label}
              </Text>
            </TouchableOpacity>
          ))}
        </View>
      </View>

      {/* Summary */}
      <View style={styles.summary}>
        <Text style={styles.summaryText}>
          {isToday ? "Today" : dateFormatted} ·{" "}
          {amPm === "AM" ? "Morning" : "Afternoon"} Session
        </Text>
      </View>

      {/* Save */}
      <TouchableOpacity
        style={[styles.saveButton, saving && styles.saveButtonDisabled]}
        onPress={() => handleSave(false)}
        disabled={saving}
        activeOpacity={0.85}
      >
        <Text style={styles.saveButtonText}>
          {saving ? "Saving..." : "Save Schedule"}
        </Text>
      </TouchableOpacity>

      <TouchableOpacity
        style={[styles.secondaryButton, saving && styles.saveButtonDisabled]}
        onPress={() => handleSave(true)}
        disabled={saving}
        activeOpacity={0.8}
      >
        <Text style={styles.secondaryButtonText}>
          {saving ? "Saving..." : "Save & Start Now"}
        </Text>
      </TouchableOpacity>

      {/* Unschedule — only shown when rescheduling an already-scheduled workout */}
      {initialDate && (
        <TouchableOpacity
          style={styles.unscheduleButton}
          onPress={handleUnschedule}
          activeOpacity={0.7}
        >
          <Text style={styles.unscheduleButtonText}>
            Unschedule (move to drafts)
          </Text>
        </TouchableOpacity>
      )}

      {/* Skip scheduling — save without a date, go to workouts list */}
      <TouchableOpacity
        style={styles.skipButton}
        onPress={() => router.replace("/(tabs)/workouts")}
        activeOpacity={0.7}
      >
        <Text style={styles.skipButtonText}>Skip scheduling</Text>
      </TouchableOpacity>

      {/* Back without saving */}
      <TouchableOpacity
        style={styles.backLink}
        onPress={() => router.back()}
        activeOpacity={0.7}
      >
        <Text style={styles.backLinkText}>← Back without saving</Text>
      </TouchableOpacity>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  scroll: { flex: 1, backgroundColor: Colors.base },
  container: { padding: Space[6], paddingBottom: Space[12] },
  screenLabel: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.xs,
    color: Colors.dim,
    letterSpacing: 1.2,
    marginBottom: Space[2],
  },
  heading: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.xl,
    color: Colors.text,
    marginBottom: Space[6],
  },
  section: { marginBottom: Space[4] },
  sectionLabel: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.xs,
    color: Colors.dim,
    letterSpacing: 0.8,
    marginBottom: Space[3],
  },

  // Today chips
  todayRow: { flexDirection: "row", gap: Space[3] },
  todayChip: {
    flex: 1,
    backgroundColor: Colors.surface,
    borderRadius: Radius.md,
    borderWidth: 1.5,
    borderColor: Colors.border,
    height: TouchTarget.lap,
    alignItems: "center",
    justifyContent: "center",
  },
  todayChipActive: {
    borderColor: Colors.cyan,
    backgroundColor: Colors.cyanDim,
  },
  todayChipText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.base,
    color: Colors.muted,
  },
  todayChipTextActive: { color: Colors.cyan },

  // Divider
  dividerRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: Space[3],
    marginBottom: Space[4],
  },
  dividerLine: { flex: 1, height: 1, backgroundColor: Colors.border },
  dividerText: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.xs,
    color: Colors.dim,
    flex: 0,
  } as TextStyle,

  // Date selector
  dateSelector: {
    backgroundColor: Colors.surface,
    borderRadius: Radius.md,
    borderWidth: 1,
    borderColor: Colors.border,
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    padding: Space[4],
    height: TouchTarget.lap,
  },
  dateSelectorText: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.base,
    color: Colors.text,
  },
  dateSelectorChevron: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.sm,
    color: Colors.dim,
  },
  datePickerCard: {
    backgroundColor: Colors.surface,
    borderRadius: Radius.md,
    borderWidth: 1,
    borderColor: Colors.border,
    overflow: "hidden",
    marginTop: Space[2],
  },
  datePicker: { height: 160 },

  // AM/PM
  amPmRow: { flexDirection: "row", gap: Space[3] },
  amPmButton: {
    flex: 1,
    backgroundColor: Colors.surface,
    borderRadius: Radius.md,
    borderWidth: 1,
    borderColor: Colors.border,
    height: TouchTarget.lap,
    alignItems: "center",
    justifyContent: "center",
  },
  amPmButtonActive: {
    borderColor: Colors.cyan,
    backgroundColor: Colors.cyanDim,
  },
  amPmButtonText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.base,
    color: Colors.muted,
  },
  amPmButtonTextActive: { color: Colors.cyan },

  // Summary
  summary: {
    backgroundColor: Colors.cyanDim,
    borderRadius: Radius.md,
    padding: Space[4],
    marginBottom: Space[6],
    alignItems: "center",
  },
  summaryText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.base,
    color: Colors.cyan,
  },

  // Buttons
  saveButton: {
    backgroundColor: Colors.cyan,
    borderRadius: Radius.lg,
    height: TouchTarget.lap,
    alignItems: "center",
    justifyContent: "center",
    marginBottom: Space[4],
    boxShadow: `0 0 12px ${Colors.cyanGlow}`,
    elevation: 4,
    elevation: 4,
  },
  saveButtonDisabled: { opacity: 0.5 },
  saveButtonText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.lg,
    color: "#000",
    fontWeight: "600",
  },
  secondaryButton: {
    backgroundColor: Colors.surface,
    borderRadius: Radius.lg,
    borderWidth: 1,
    borderColor: Colors.border,
    height: TouchTarget.lap,
    alignItems: "center",
    justifyContent: "center",
    marginBottom: Space[4],
  },
  secondaryButtonText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.base,
    color: Colors.muted,
  },
  unscheduleButton: {
    marginBottom: Space[2],
    height: TouchTarget.min,
    alignItems: "center",
    justifyContent: "center",
  },
  unscheduleButtonText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.sm,
    color: Colors.amber,
  },
  skipButton: {
    height: TouchTarget.min,
    alignItems: "center",
    justifyContent: "center",
    marginBottom: Space[2],
  },
  skipButtonText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.sm,
    color: Colors.dim,
  },
  backLink: {
    height: TouchTarget.min,
    alignItems: "center",
    justifyContent: "center",
  },
  backLinkText: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.sm,
    color: Colors.muted,
  },
  errorText: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.base,
    color: Colors.muted,
    textAlign: "center",
    marginTop: Space[12],
  },
  webDatePickerContainer: {
    marginTop: Space[2],
  },
});
