/**
 * WorkoutBuilder — natural language workout creation screen.
 *
 * Coach types (or speaks) a full workout: "4x100 free @1:30, 4x50 kick fins @1:00, 200 easy"
 * The parser extracts set components, detects gear, and resolves pace targets.
 * Each set is shown as a preview card.
 * Unparsed text is highlighted so the coach can correct it.
 *
 * Route: /workout/new
 */

import { useState, useMemo, useEffect } from "react";
import {
  View,
  Text,
  TextInput,
  TouchableOpacity,
  StyleSheet,
  ScrollView,
  Alert,
  Platform,
} from "react-native";
import { useRouter, useLocalSearchParams } from "expo-router";
import { supabase } from "../../lib/supabase";
import { useAuth } from "../../context/AuthContext";
import {
  parseWorkoutV2,
  formatWorkoutV2,
  formatRepGroup,
} from "../../lib/workout-parser-v2";
import type { RepGroup } from "../../lib/workout-types";
import WorkoutPreview from "../../components/WorkoutPreview";
import {
  parseWorkout,
  isWorkoutReady,
  parsedCount,
  totalReps,
  formatWorkout,
  parseGear,
  GEAR_PENALTIES,
} from "../../lib/workout-parser";
import { formatParsedSet, intensityColor } from "../../lib/set-parser";
import {
  Colors,
  FontFamily,
  FontSize,
  Space,
  Radius,
  TouchTarget,
} from "../../lib/theme";

const GEAR_OPTIONS = [
  { label: "None", value: null },
  { label: "Paddles", value: "paddles" },
  { label: "Fins", value: "fins" },
  { label: "Pull Buoy", value: "pull_buoy" },
  { label: "Kickboard", value: "kickboard" },
  { label: "Drag Suit", value: "dragSuit" },
] as const;

export default function WorkoutBuilderScreen() {
  const router = useRouter();
  const { workoutId } = useLocalSearchParams<{ workoutId?: string }>();
  const { coachId } = useAuth();
  const [title, setTitle] = useState("");
  const [input, setInput] = useState("");
  const [saving, setSaving] = useState(false);
  const [initialLoad, setInitialLoad] = useState(false);

  useEffect(() => {
    if (!workoutId) return;
    setInitialLoad(true);
    (async () => {
      const { data, error } = await supabase
        .from("workouts")
        .select("title, workout_text")
        .eq("id", workoutId)
        .single();
      if (!error && data) {
        setTitle(data.title ?? "");
        setInput(data.workout_text ?? "");
      }
      setInitialLoad(false);
    })();
  }, [workoutId]);

  // Override state per set index: key = setIndex, value = array of gear items
  const [gearOverrides, setGearOverrides] = useState<Record<number, string[]>>(
    {},
  );

  const workoutV2 = useMemo(() => parseWorkoutV2(input), [input]);

  // ready if we have at least one rep group with a valid distance
  const totalRepGroups = workoutV2.sections.reduce(
    (sum, s) =>
      sum + s.namedSets.reduce((nsSum, ns) => nsSum + ns.repGroups.length, 0),
    0,
  );
  const ready = totalRepGroups > 0;

  // Build the workout payload for Supabase
  const workoutPayload = useMemo(
    () => ({
      title: title.trim() || null,
      coach_id: coachId, // resolved by AuthContext
      scheduled_at: null,
      am_pm: null as string | null,
    }),
    [title, coachId],
  );

  async function handleSaveWorkout() {
    if (!coachId) {
      Alert.alert("Error", "Not signed in.");
      return;
    }
    setSaving(true);
    try {
      let workoutIdToUse = workoutId;

      // Build the new sets list first, before any deletions.
      // This ensures we know whether there's anything to insert.
      const setsToInsert: any[] = [];
      let orderIndex = 0;
      for (const section of workoutV2.sections) {
        for (const ns of section.namedSets) {
          for (const rg of ns.repGroups) {
            setsToInsert.push({
              workout_id: workoutIdToUse!,
              order_index: orderIndex++,
              reps: rg.reps ?? null,
              distance: rg.distance ?? null,
              stroke: rg.stroke ?? "Free",
              interval_text: rg.interval ?? null,
              intensity_type: rg.intensity?.type ?? null,
              pace_target_distance: null,
              intensity_label: rg.intensity?.label ?? null,
              gear: (rg.gear ?? []).join("|") || null,
              drill: (rg.details ?? []).join("|") || null,
            });
          }
        }
      }

      if (workoutId) {
        // Update the workouts record with new title and text.
        const { error: updateError } = await supabase
          .from("workouts")
          .update({
            title: title.trim() || null,
            workout_text: input,
          })
          .eq("id", workoutId);
        if (updateError) throw updateError;

        // Only replace sets if there are new sets to insert.
        // This preserves existing workout_sets when parsing produces zero sets.
        if (setsToInsert.length > 0) {
          await supabase
            .from("workout_sets")
            .delete()
            .eq("workout_id", workoutId);
          const { error: setsError } = await supabase
            .from("workout_sets")
            .insert(setsToInsert);
          if (setsError) throw setsError;
        }
        // setsToInsert.length === 0 → preserve existing sets (parse failed or user cleared text)
      } else {
        const { data: workout, error: workoutError } = await supabase
          .from("workouts")
          .insert({
            title: title.trim() || null,
            coach_id: coachId,
            status: "draft",
            scheduled_at: null,
            am_pm: null,
            workout_text: input,
          })
          .select("id")
          .single();

        if (workoutError || !workout) {
          throw workoutError ?? new Error("No workout returned");
        }
        workoutIdToUse = workout.id;

        if (setsToInsert.length > 0) {
          const { error: setsError } = await supabase
            .from("workout_sets")
            .insert(setsToInsert);
          if (setsError) throw setsError;
        }
      }

      router.replace(`/workout/${workoutIdToUse}`);
    } catch (err) {
      const msg = err instanceof Error ? err.message : JSON.stringify(err);
      if (Platform.OS === "web") window.alert(`Save error: ${msg}`);
      else Alert.alert("Save error", msg);
    } finally {
      setSaving(false);
    }
  }

  function toggleGearOverride(index: number, gearItem: string | null) {
    // V2 currently has no per-rep-group gear — v1 gear override not applicable
  }

  // V2 tree rendering
  function fmtIntensity(
    i: {
      type: string;
      label: string;
      percentLow?: number | null;
      percentHigh?: number | null;
    } | null,
    opts: { pacing?: string | null; descend?: string | null } = {},
  ): string | null {
    if (!i) return null;
    let value: string;
    if (i.type === "percent_range") {
      if (i.percentLow != null && i.percentHigh != null)
        value = `${i.percentLow}–${i.percentHigh}%`;
      else if (i.percentLow != null) value = `~${i.percentLow}%`;
      else value = i.label;
    } else {
      value = i.label;
    }
    const glyph = opts.descend ? "↘ " : opts.pacing === "build" ? "→ " : "";
    return `${glyph}${value}`;
  }

  function fmtSubRep(r: any): string {
    const parts: string[] = [];
    if (r.meters != null) parts.push(`${r.meters}`);
    // Drop pacing word when glyph carries it (sub-rep has intensity with → or ↘)
    const hasGlyph = r.pacing === "build" && r.intensity;
    if (r.pacing && !hasGlyph) parts.push(r.pacing);
    if (r.stroke) parts.push(r.stroke);
    if (r.intensity)
      parts.push(fmtIntensity(r.intensity, { pacing: r.pacing }) ?? "");
    return parts.join(" ");
  }

  function renderDrillSwimLine(rg: RepGroup): string | null {
    if (rg.patternType !== "drill_swim") return null;
    const ds = rg.pattern.find((p) => p.type === "drill_swim") as any;
    if (!ds) return null;
    const parts: string[] = [];
    if (ds.drillMeters != null) parts.push(`${ds.drillMeters} dr`);
    if (ds.swimMeters != null) parts.push(`${ds.swimMeters} sw`);
    return parts.join(" · ");
  }

  function renderOddEvenLines(
    rg: RepGroup,
  ): Array<{ label: string; text: string }> | null {
    if (rg.patternType !== "odd_even") return null;
    const oe = rg.pattern.find((p) => p.type === "odd_even") as any;
    if (!oe) return null;
    return [
      { label: "Odd:", text: oe.odd },
      { label: "Even:", text: oe.even },
    ];
  }

  function renderSubRepsLine(rg: RepGroup): string | null {
    if (rg.patternType === "drill_swim") return renderDrillSwimLine(rg);
    if (rg.patternType === "odd_even") return null;
    if (rg.patternType === "simple" && rg.pattern.length > 1) {
      return rg.pattern
        .map((r: any) => fmtSubRep(r))
        .filter(Boolean)
        .join("  ·  ");
    }
    return null;
  }

  const renderV2Tree = () => {
    if (workoutV2.sections.length === 0) return null;

    return (
      <View style={styles.v2TreeContainer}>
        {workoutV2.sections.map((section, si) => (
          <View key={si} style={styles.v2Section}>
            {section.title && (
              <>
                <View style={styles.v2SectionDivider} />
                <Text style={styles.v2SectionTitle}>
                  {section.title.replace(/\s*\(\d+m\)\s*$/, "").toUpperCase()}
                </Text>
                <View style={styles.v2SectionDividerLine} />
              </>
            )}

            {section.namedSets.map((ns, ni) => (
              <View key={ni} style={styles.v2NamedSetBlock}>
                {ns.label && (
                  <Text style={styles.v2NamedSetLabel}>
                    {ns.label.replace(/\s*\(\d+\s*m?\)\s*$/i, "").toUpperCase()}
                  </Text>
                )}

                {ns.repGroups.map((rg, gi) => {
                  const subLine = renderSubRepsLine(rg);
                  const oddEvenLines = renderOddEvenLines(rg);
                  const hasConnector = gi < ns.repGroups.length - 1;

                  return (
                    <View key={gi} style={styles.v2RepGroupBlock}>
                      {/* Main spine line */}
                      <View style={styles.v2RepGroupRow}>
                        {/* Spine: reps × distance in mono */}
                        <Text style={styles.v2RepGroupSpine}>
                          {rg.reps != null && rg.distance != null
                            ? `${rg.reps}×${rg.distance}m`
                            : rg.distance != null
                              ? `${rg.distance}m`
                              : ""}
                        </Text>
                        {/* Stroke */}
                        {rg.stroke && (
                          <Text style={styles.v2RepGroupMeta}>
                            {" "}
                            {rg.stroke}
                          </Text>
                        )}
                        {/* Intensity */}
                        {rg.intensity && (
                          <Text style={styles.v2RepGroupIntensity}>
                            {" "}
                            @{" "}
                            {fmtIntensity(rg.intensity, {
                              pacing: rg.pacing,
                              descend: rg.descend,
                            })}
                          </Text>
                        )}
                        {/* Interval */}
                        {rg.interval && (
                          <Text style={styles.v2RepGroupMuted}>
                            {" "}
                            on {rg.interval}
                          </Text>
                        )}
                        {/* Gear badge */}
                        {rg.gear && rg.gear.length > 0 && (
                          <View style={styles.v2GearBadge}>
                            <Text style={styles.v2GearBadgeText}>
                              {rg.gear[0].charAt(0).toUpperCase() +
                                rg.gear[0].slice(1)}
                              {rg.gearOptional ? " optional" : ""}
                            </Text>
                          </View>
                        )}
                        {/* Descend range — drop, glyph ↘ carries the signal */}
                        {/* Connector */}
                        {hasConnector && (
                          <Text style={styles.v2Connector}> + </Text>
                        )}
                      </View>

                      {/* Sub-row: drill/swim or simple multi-sub */}
                      {subLine && (
                        <View style={styles.v2SubRow}>
                          <Text style={styles.v2SubRowText}>{subLine}</Text>
                        </View>
                      )}

                      {/* Odd/Even lines */}
                      {oddEvenLines &&
                        oddEvenLines.map((oe, idx) => (
                          <View key={idx} style={styles.v2OddEvenRow}>
                            <Text style={styles.v2OddEvenLabel}>
                              {oe.label}
                            </Text>
                            <Text style={styles.v2OddEvenText}>{oe.text}</Text>
                          </View>
                        ))}

                      {/* Note */}
                      {rg.note && <Text style={styles.v2Note}> {rg.note}</Text>}
                    </View>
                  );
                })}
              </View>
            ))}
          </View>
        ))}
      </View>
    );
  };

  return (
    <ScrollView
      style={styles.scroll}
      contentContainerStyle={styles.container}
      keyboardShouldPersistTaps="handled"
    >
      {/* Header */}
      <Text style={styles.screenLabel}>WORKOUT BUILDER</Text>

      {/* Workout title */}
      <TextInput
        style={styles.titleInput}
        value={title}
        onChangeText={setTitle}
        placeholder="Workout title (optional)"
        placeholderTextColor={Colors.dim}
      />

      {/* Natural language input */}
      <TextInput
        style={styles.nlInput}
        value={input}
        onChangeText={setInput}
        placeholder={
          '4x100 free @1:30, 4x50 kick fins paddles @1:00, 200 easy\n\nTip: separate sets with commas. Include gear like "fins" or "paddles".'
        }
        placeholderTextColor={Colors.muted}
        multiline
        autoFocus
        autoCapitalize="none"
        autoCorrect={false}
      />

      {/* V2 tree output */}
      {ready && workoutV2.sections.length > 0 && (
        <WorkoutPreview workout={workoutV2} />
      )}

      {/* Next button */}
      <TouchableOpacity
        style={[styles.saveButton, !ready && styles.saveButtonDisabled]}
        onPress={handleSaveWorkout}
        disabled={!ready || saving}
        activeOpacity={0.85}
      >
        <Text style={styles.saveButtonText}>
          {saving
            ? "Saving..."
            : ready
              ? workoutId
                ? `Update Workout (${totalRepGroups} sets)`
                : `Schedule Workout (${totalRepGroups} sets)`
              : "Fix unparsed sets first"}
        </Text>
      </TouchableOpacity>
    </ScrollView>
  );
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

function componentGear(
  component: ReturnType<typeof parseWorkout>[number],
): string[] | null {
  return component.gear;
}

// ─── SetPreviewCard ───────────────────────────────────────────────────────────

function SetPreviewCard({
  index,
  component,
  label,
  gearOverride,
  onGearToggle,
}: {
  index: number;
  component: ReturnType<typeof parseWorkout>[number];
  label: string;
  gearOverride: string[] | null;
  onGearToggle: (gear: string | null) => void;
}) {
  const effectiveGear = gearOverride ?? component.gear ?? [];

  return (
    <View style={styles.setCard}>
      {/* Index badge + parsed status */}
      <View style={styles.setCardHeader}>
        <Text style={styles.setIndexBadge}>{index + 1}</Text>
        <Text
          style={[
            styles.setStatusText,
            !component.parsed && styles.setStatusUnparsed,
          ]}
        >
          {component.parsed ? "✓ Parsed" : "⚠ Unparsed"}
        </Text>
      </View>

      {/* Formatted label */}
      <Text
        style={[styles.setLabel, !component.parsed && styles.setLabelUnparsed]}
      >
        {label}
      </Text>

      {/* Gear selector (only shown if set is parsed) */}
      {component.parsed && (
        <View style={styles.gearSelector}>
          <Text style={styles.gearLabel}>GEAR</Text>
          <View style={styles.gearOptions}>
            <TouchableOpacity
              style={[
                styles.gearChip,
                effectiveGear.length === 0 && styles.gearChipActive,
              ]}
              onPress={() => onGearToggle(null)}
            >
              <Text
                style={[
                  styles.gearChipText,
                  effectiveGear.length === 0 && styles.gearChipTextActive,
                ]}
              >
                None
              </Text>
            </TouchableOpacity>
            {GEAR_OPTIONS.filter((o) => o.value !== null).map((opt) => (
              <TouchableOpacity
                key={opt.label}
                style={[
                  styles.gearChip,
                  effectiveGear.includes(opt.value!) && styles.gearChipActive,
                ]}
                onPress={() => onGearToggle(opt.value!)}
              >
                <Text
                  style={[
                    styles.gearChipText,
                    effectiveGear.includes(opt.value!) &&
                      styles.gearChipTextActive,
                  ]}
                >
                  {opt.label}
                </Text>
              </TouchableOpacity>
            ))}
          </View>
        </View>
      )}

      {/* Unparsed text: show raw input with warning */}
      {!component.parsed && (
        <Text style={styles.unparsedRawText}>"{component.rawText}"</Text>
      )}
    </View>
  );
}

// ─── Styles ───────────────────────────────────────────────────────────────────

const styles = StyleSheet.create({
  scroll: { flex: 1, backgroundColor: Colors.base },
  container: { padding: Space[6], paddingBottom: Space[12] },

  screenLabel: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.xs,
    color: Colors.dim,
    letterSpacing: 1.2,
    marginBottom: Space[4],
  },

  titleInput: {
    backgroundColor: Colors.elevated,
    borderWidth: 1,
    borderColor: Colors.border,
    borderRadius: Radius.md,
    padding: Space[4],
    fontSize: FontSize.lg,
    fontFamily: FontFamily.ui,
    color: Colors.text,
    marginBottom: Space[4],
  },

  nlInput: {
    backgroundColor: Colors.elevated,
    borderWidth: 1,
    borderColor: Colors.cyan,
    borderRadius: Radius.md,
    padding: Space[4],
    fontSize: FontSize.lg,
    fontFamily: FontFamily.ui,
    color: Colors.text,
    minHeight: 120,
    textAlignVertical: "top",
    lineHeight: 28,
    marginBottom: Space[4],
  },

  summaryRow: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    marginBottom: Space[4],
  },
  summaryText: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.sm,
    color: Colors.muted,
  },
  summaryWarning: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.sm,
    color: Colors.amber,
  },

  // Set cards
  setCard: {
    backgroundColor: Colors.surface,
    borderRadius: Radius.md,
    padding: Space[4],
    marginBottom: Space[3],
    borderWidth: 1,
    borderColor: Colors.border,
  },

  setCardHeader: {
    flexDirection: "row",
    alignItems: "center",
    marginBottom: Space[2],
  },
  setIndexBadge: {
    fontFamily: FontFamily.mono,
    fontSize: FontSize.sm,
    color: Colors.cyan,
    backgroundColor: Colors.cyanDim,
    borderRadius: 4,
    paddingHorizontal: 6,
    paddingVertical: 2,
    marginRight: Space[2],
  },
  setStatusText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.xs,
    color: Colors.optimal,
    letterSpacing: 0.8,
  },
  setStatusUnparsed: { color: Colors.amber },

  setLabel: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.base,
    color: Colors.text,
    lineHeight: 20,
    marginBottom: Space[2],
  },
  setLabelUnparsed: {
    color: Colors.muted,
    fontStyle: "italic",
  },

  // Gear selector
  gearSelector: {
    flexDirection: "row",
    alignItems: "center",
    marginTop: Space[2],
  },
  gearLabel: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.xs,
    color: Colors.dim,
    letterSpacing: 0.8,
    marginRight: Space[3],
  },
  gearOptions: {
    flexDirection: "row",
    flexWrap: "wrap",
    gap: Space[1],
  },
  gearChip: {
    paddingHorizontal: Space[3],
    paddingVertical: Space[1],
    borderRadius: Radius.sm,
    borderWidth: 1,
    borderColor: Colors.border,
    backgroundColor: Colors.elevated,
  },
  gearChipActive: {
    borderColor: Colors.cyan,
    backgroundColor: Colors.cyanDim,
  },
  gearChipText: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.xs,
    color: Colors.muted,
  },
  gearChipTextActive: {
    color: Colors.cyan,
  },

  unparsedRawText: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.sm,
    color: Colors.muted,
    fontStyle: "italic",
    marginTop: Space[2],
  },

  // Save button
  saveButton: {
    backgroundColor: Colors.cyan,
    borderRadius: Radius.lg,
    height: TouchTarget.lap,
    alignItems: "center",
    justifyContent: "center",
    boxShadow: `0 0 12px ${Colors.cyanGlow}`,
    elevation: 4,
  },

  saveButtonDisabled: {
    opacity: 0.3,
  },
  saveButtonText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.lg,
    color: "#000",
    fontWeight: "600",
  },

  // V2 tree rendering
  v2TreeContainer: {
    marginTop: Space[4],
  },
  v2Section: {
    marginBottom: Space[6],
  },
  v2SectionDivider: {
    height: 1,
    backgroundColor: Colors.border,
    marginBottom: Space[2],
    marginTop: Space[4],
  },
  v2SectionDividerLine: {
    height: 0,
  },
  v2SectionTitle: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.xs,
    color: Colors.dim,
    letterSpacing: 1.2,
    textTransform: "uppercase" as const,
    marginBottom: Space[1],
  },
  v2NamedSetBlock: {
    marginBottom: Space[4],
  },
  v2NamedSetLabel: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: 14,
    fontWeight: "600" as const,
    color: Colors.cyan,
    marginBottom: Space[1],
  },
  v2RepGroupBlock: {
    marginBottom: Space[3],
  },
  v2RepGroupRow: {
    flexDirection: "row" as const,
    alignItems: "center" as const,
    flexWrap: "wrap" as const,
    marginBottom: 2,
  },
  v2RepGroupSpine: {
    fontFamily: FontFamily.mono,
    fontSize: 15,
    color: Colors.text,
    marginRight: 4,
  },
  v2RepGroupMeta: {
    fontFamily: FontFamily.ui,
    fontSize: 13,
    color: Colors.text,
    marginRight: 4,
  },
  v2RepGroupIntensity: {
    fontFamily: FontFamily.uiMedium,
    fontSize: 13,
    color: Colors.amber,
    marginRight: 4,
  },
  v2RepGroupMuted: {
    fontFamily: FontFamily.ui,
    fontSize: 13,
    color: Colors.muted,
    marginRight: 4,
  },
  v2GearBadge: {
    backgroundColor: Colors.cyanDim,
    borderRadius: 4,
    paddingHorizontal: 6,
    paddingVertical: 2,
    borderWidth: 1,
    borderColor: Colors.cyan,
    marginRight: 4,
  },
  v2GearBadgeText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: 11,
    color: Colors.cyan,
  },
  v2DescendRange: {
    fontFamily: FontFamily.ui,
    fontSize: 12,
    color: Colors.muted,
    fontStyle: "italic" as const,
  },
  v2Connector: {
    fontFamily: FontFamily.ui,
    fontSize: 12,
    color: Colors.dim,
    marginRight: 8,
  },
  v2SubRow: {
    paddingLeft: 12,
    borderLeftWidth: 1,
    borderLeftColor: Colors.border,
    marginTop: 4,
    marginBottom: 4,
  },
  v2SubRowText: {
    fontFamily: FontFamily.ui,
    fontSize: 13,
    color: Colors.muted,
    fontStyle: "italic" as const,
  },
  v2OddEvenRow: {
    paddingLeft: 12,
    borderLeftWidth: 1,
    borderLeftColor: Colors.border,
    marginBottom: 3,
  },
  v2OddEvenLabel: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: 11,
    color: Colors.dim,
    marginRight: 6,
  },
  v2OddEvenText: {
    fontFamily: FontFamily.ui,
    fontSize: 13,
    color: Colors.muted,
    fontStyle: "italic" as const,
  },
  v2Note: {
    fontFamily: FontFamily.ui,
    fontSize: 12,
    color: Colors.dim,
    fontStyle: "italic" as const,
    marginTop: 2,
  },
  v2Details: {
    fontFamily: FontFamily.ui,
    fontSize: 11,
    color: Colors.dim,
    fontStyle: "italic" as const,
    marginTop: 2,
  },
  v2RepGroupMain: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.base,
    color: Colors.text,
    lineHeight: 22,
  },
});
