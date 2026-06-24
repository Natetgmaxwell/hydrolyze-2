/**
 * WorkoutPreview — renders a parsed Workout tree (sections, namedSets, repGroups).
 * Used by: WorkoutBuilder (new.tsx), WorkoutDetail ([id].tsx), SetPicker (set-picker.tsx).
 * Pure presentation — no parser invocation, no Supabase calls.
 */
import type { Workout, RepGroup, Section } from "../lib/workout-types";
import { Colors, FontFamily, FontSize, Space, Radius } from "../lib/theme";
import { View, Text, StyleSheet } from "react-native";

export interface IntensityProps {
  type: string;
  label: string;
  percentLow?: number | null;
  percentHigh?: number | null;
}

export function fmtIntensity(
  i: IntensityProps | null,
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
  const hasGlyph = r.pacing === "build" && r.intensity;
  if (r.pacing && !hasGlyph) parts.push(r.pacing);
  if (r.stroke) parts.push(r.stroke);
  if (r.intensity)
    parts.push(fmtIntensityWithLabel(r.intensity, { pacing: r.pacing }) ?? "");
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

function fmtIntensityWithLabel(
  i: IntensityProps | null,
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
  const descendText = opts.descend ? ` ↘ ${opts.descend}` : "";
  const pacingLabel = opts.pacing ? ` ${opts.pacing}` : "";
  return `${value}${pacingLabel}${descendText}`;
}

export function RepGroupRow({
  rg,
  onPress,
  showAffordance,
  affordance,
}: {
  rg: RepGroup;
  onPress?: () => void;
  showAffordance?: boolean;
  affordance?: "start" | "done";
}) {
  const spine =
    rg.reps != null && rg.distance != null
      ? `${rg.reps}×${rg.distance}m`
      : rg.distance != null
        ? `${rg.distance}m`
        : "";

  const subLine = (() => {
    if (rg.patternType === "drill_swim") return renderDrillSwimLine(rg);
    if (rg.patternType === "odd_even") return null;
    if (rg.patternType === "simple" && rg.pattern.length > 1) {
      return rg.pattern
        .map((r: any) => fmtSubRep(r))
        .filter(Boolean)
        .join(" · ");
    }
    return null;
  })();
  const oddEvenLines = renderOddEvenLines(rg);

  const cleanDetails =
    rg.details?.filter(
      (d) =>
        !/^~.*[—–-].*$/.test(d) &&
        d.toLowerCase() !== "optional" &&
        d.toLowerCase() !== "as",
    ) ?? null;

  return (
    <View style={styles.v2RepGroupBlock}>
      <View style={styles.repGroupRow}>
        <View style={styles.repGroupSpineContainer}>
          <Text style={styles.repGroupSpine}>{spine}</Text>
          {rg.stroke && <Text style={styles.repGroupMeta}> {rg.stroke}</Text>}
        </View>

        {rg.intensity && (
          <Text style={styles.repGroupIntensity}>
            {" @ "}
            {fmtIntensityWithLabel(rg.intensity, {
              pacing: rg.pacing,
              descend: rg.descend,
            })}
          </Text>
        )}

        {rg.pattern.length === 0 &&
          cleanDetails &&
          cleanDetails.length > 0 &&
          cleanDetails.map((detail, idx) => (
            <View key={idx} style={styles.chip}>
              <Text style={styles.chipTextDrill}>
                {detail.charAt(0).toUpperCase() + detail.slice(1)}
              </Text>
            </View>
          ))}

        {rg.gear && rg.gear.length > 0 && (
          <View style={styles.chip}>
            <Text style={styles.chipTextGear}>
              {rg.gear[0].charAt(0).toUpperCase() + rg.gear[0].slice(1)}
              {rg.gearOptional ? " optional" : ""}
            </Text>
          </View>
        )}

        {rg.interval && (
          <Text style={styles.repGroupInterval}> on {rg.interval}</Text>
        )}

        {rg.note && <Text style={styles.v2Note}> {rg.note}</Text>}

        {showAffordance && (
          <View style={styles.affordanceContainer}>
            {affordance === "done" ? (
              <Text style={styles.affordanceDone}>✓</Text>
            ) : (
              <Text style={styles.affordanceStart}>Start</Text>
            )}
          </View>
        )}
      </View>

      {subLine && (
        <View style={styles.v2SubRow}>
          <Text style={styles.v2SubRowText}>{subLine}</Text>
        </View>
      )}

      {oddEvenLines &&
        oddEvenLines.map((oe, idx) => (
          <View key={idx} style={styles.v2OddEvenRow}>
            <Text style={styles.v2OddEvenLabel}>{oe.label}</Text>
            <Text style={styles.v2OddEvenText}>{oe.text}</Text>
          </View>
        ))}
    </View>
  );
}

export function SectionHeader({ section }: { section: Section }) {
  if (!section.title) return null;
  return (
    <View style={styles.sectionHeaderContainer}>
      <View style={styles.sectionDivider} />
      <Text style={styles.sectionTitle}>
        {section.title.replace(/\s*\(\d+m\)\s*$/, "").toUpperCase()}
      </Text>
      <View style={styles.sectionDividerLine} />
    </View>
  );
}

function NamedSetLabel({ label }: { label: string }) {
  return (
    <Text style={styles.v2NamedSetLabel}>
      {label.replace(/\s*\(\d+\s*m?\)\s*$/i, "").toUpperCase()}
    </Text>
  );
}

export default function WorkoutPreview({ workout }: { workout: Workout }) {
  if (workout.sections.length === 0) return null;

  return (
    <View style={styles.v2TreeContainer}>
      {workout.sections.map((section, si) => (
        <View key={si} style={styles.v2Section}>
          <SectionHeader section={section} />

          {section.namedSets.map((ns, ni) => (
            <View key={ni} style={styles.v2NamedSetBlock}>
              {ns.label && <NamedSetLabel label={ns.label} />}

              {ns.repGroups.map((rg, gi) => (
                <RepGroupRow key={gi} rg={rg} />
              ))}
            </View>
          ))}
        </View>
      ))}
    </View>
  );
}

const styles = StyleSheet.create({
  v2TreeContainer: { marginTop: Space[4] },
  v2Section: { marginBottom: Space[6] },
  v2SectionDivider: {
    height: 1,
    backgroundColor: Colors.border,
    marginBottom: Space[3],
  },
  v2SectionTitle: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.sm,
    color: Colors.muted,
    letterSpacing: 1,
    marginBottom: Space[2],
  },
  v2SectionDividerLine: {
    height: 1,
    backgroundColor: Colors.border,
    marginBottom: Space[4],
    marginTop: Space[1],
  },
  v2NamedSetBlock: { marginBottom: Space[4], paddingLeft: Space[2] },
  v2NamedSetLabel: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.xs,
    color: Colors.cyan,
    letterSpacing: 0.8,
    marginBottom: Space[2],
  },
  v2RepGroupBlock: { marginBottom: Space[3] },
  v2RepGroupRow: {
    flexDirection: "row",
    alignItems: "center",
    flexWrap: "wrap",
  },
  v2RepGroupSpine: {
    fontFamily: FontFamily.mono,
    fontSize: FontSize.base,
    color: Colors.text,
  },
  v2RepGroupMeta: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.base,
    color: Colors.text,
  },
  v2RepGroupIntensity: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.sm,
    color: Colors.amber,
  },
  v2RepGroupMuted: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.sm,
    color: Colors.dim,
  },
  v2DrillBadge: {
    backgroundColor: Colors.elevated,
    borderRadius: Radius.sm,
    borderWidth: 1,
    borderColor: Colors.border,
    paddingHorizontal: Space[2],
    paddingVertical: 1,
    marginLeft: Space[1],
  },
  v2DrillBadgeText: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.xs,
    color: Colors.cyan,
  },
  v2GearBadge: {
    backgroundColor: Colors.surface,
    borderRadius: Radius.sm,
    borderWidth: 1,
    borderColor: Colors.border,
    paddingHorizontal: Space[2],
    paddingVertical: 1,
    marginLeft: Space[1],
  },
  v2GearBadgeText: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.xs,
    color: Colors.muted,
  },
  v2Connector: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.base,
    color: Colors.muted,
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
    fontStyle: "italic",
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
    fontStyle: "italic",
  },
  v2Note: {
    fontFamily: FontFamily.ui,
    fontSize: 12,
    color: Colors.dim,
    fontStyle: "italic",
    marginTop: 2,
  },

  repGroupRow: {
    flexDirection: "row",
    alignItems: "center",
    flexWrap: "wrap",
  },
  repGroupSpineContainer: {
    flexDirection: "row",
    alignItems: "center",
  },
  repGroupSpine: {
    fontFamily: FontFamily.mono,
    fontSize: FontSize.base,
    color: Colors.text,
  },
  repGroupMeta: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.base,
    color: Colors.text,
  },
  repGroupIntensity: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.sm,
    color: Colors.amber,
  },
  repGroupInterval: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.sm,
    color: Colors.dim,
  },
  chip: {
    backgroundColor: Colors.elevated,
    borderRadius: Radius.sm,
    borderWidth: 1,
    borderColor: Colors.border,
    paddingHorizontal: Space[2],
    paddingVertical: 1,
    marginLeft: Space[1],
  },
  chipTextDrill: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.xs,
    color: Colors.cyan,
  },
  chipTextGear: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.xs,
    color: Colors.muted,
  },
  affordanceContainer: {
    marginLeft: "auto",
    paddingLeft: Space[3],
  },
  affordanceDone: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.base,
    color: Colors.optimal,
  },
  affordanceStart: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.xs,
    color: Colors.cyan,
    letterSpacing: 0.8,
  },

  sectionHeaderContainer: { marginBottom: Space[3] },
  sectionDivider: {
    height: 1,
    backgroundColor: Colors.border,
    marginBottom: Space[2],
  },
  sectionDividerLine: {
    height: 1,
    backgroundColor: Colors.border,
    marginBottom: Space[4],
    marginTop: Space[1],
  },
  sectionTitle: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.sm,
    color: Colors.muted,
    letterSpacing: 1,
    marginBottom: Space[2],
  },
});
