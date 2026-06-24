/**
 * ProgressionChart — pool-deck swimmer progression chart.
 *
 * Renders a one-swimmer trend line with:
 * - Dot size by rep position (5px rep 1 → 12px final rep, linear)
 * - Dot saturation by fatigue (30% opacity early → 100% late, linear)
 * - PB dot highlighted with amber ring + label
 * - "First time" collapsed state when no data
 * - Read-only, no interaction
 *
 * Used in app/session/timing.tsx Ready and Running states.
 */

import React, { useMemo } from "react";
import { View, Text, StyleSheet } from "react-native";
import Svg, {
  Path,
  Defs,
  LinearGradient,
  Stop,
  Circle,
  G,
} from "react-native-svg";
import { Colors, FontFamily, FontSize, Space, Radius } from "../lib/theme";
import type { ProgressionPoint, PBPoint } from "../lib/swimmer-stats";

interface Props {
  points: ProgressionPoint[];
  pb: PBPoint | null;
  setLabel: string; // e.g. "100 free @ threshold"
  width?: number;
  height?: number;
  loading?: boolean;
}

const CHART_HEIGHT = 64;
const PAD_X = 12;
const PAD_Y = 8;

function interpolate(min: number, max: number, t: number): number {
  return min + (max - min) * t;
}

// Dot size: 5px (rep position 0) → 12px (rep position 1)
function dotRadius(repPosition: number): number {
  return interpolate(2.5, 6, repPosition);
}

// Dot opacity: 0.3 (rep position 0) → 1.0 (rep position 1)
function dotOpacity(repPosition: number): number {
  return interpolate(0.3, 1.0, repPosition);
}

export function ProgressionChart({
  points,
  pb,
  setLabel,
  width = 0,
  height = CHART_HEIGHT,
  loading = false,
}: Props) {
  const chartWidth = width || 300;

  const { path, areaPath, dotPositions, pbDotPos, yMin, yMax } = useMemo(() => {
    if (points.length < 2) {
      return {
        path: "",
        areaPath: "",
        dotPositions: [],
        pbDotPos: null,
        yMin: 0,
        yMax: 0,
      };
    }

    const times = points.map((p) => p.timeMs);
    const minTime = Math.min(...times);
    const maxTime = Math.max(...times);
    const range = maxTime - minTime || 1000;

    const yMinVal = minTime - range * 0.1;
    const yMaxVal = maxTime + range * 0.1;
    const yRange = yMaxVal - yMinVal;

    const innerWidth = chartWidth - 2 * PAD_X;
    const innerHeight = height - 2 * PAD_Y;
    const stepX = innerWidth / Math.max(points.length - 1, 1);

    const pts = points.map((p, i) => ({
      x: PAD_X + i * stepX,
      y: PAD_Y + innerHeight - ((p.timeMs - yMinVal) / yRange) * innerHeight,
      repPosition: p.repPosition,
      isPB: p.isPB,
    }));

    let p = `M${pts[0].x},${pts[0].y}`;
    for (let i = 0; i < pts.length - 1; i++) {
      const curr = pts[i];
      const next = pts[i + 1];
      const cpX = (curr.x + next.x) / 2;
      p += ` C${cpX},${curr.y} ${cpX},${next.y} ${next.x},${next.y}`;
    }

    const area = `${p} L${pts[pts.length - 1].x},${height - PAD_Y} L${pts[0].x},${height - PAD_Y} Z`;

    // PB dot position
    let pbPos: { x: number; y: number } | null = null;
    if (pb) {
      const pbY =
        PAD_Y + innerHeight - ((pb.timeMs - yMinVal) / yRange) * innerHeight;
      pbPos = { x: PAD_X + (pts.length - 1) * stepX, y: pbY };
    }

    return {
      path: p,
      areaPath: area,
      dotPositions: pts,
      pbDotPos: pbPos,
      yMin: yMinVal,
      yMax: yMaxVal,
    };
  }, [points, chartWidth, height]);

  if (loading) return null;

  if (points.length === 0) {
    return (
      <View style={styles.firstTimeCard}>
        <Text style={styles.firstTimeStar}>★</Text>
        <Text style={styles.firstTimeText}>
          First time swimming this exact set
        </Text>
        <Text style={styles.firstTimeSubtext}>
          No prior data for this set yet
        </Text>
      </View>
    );
  }

  return (
    <View style={styles.card}>
      <View style={styles.cardHeader}>
        <Text style={styles.setLabelText}>{setLabel}</Text>
        {pb && <Text style={styles.pbLabel}>★ PB</Text>}
      </View>

      <View style={styles.chartArea}>
        <Svg width={chartWidth} height={height}>
          <Defs>
            <LinearGradient id="progGrad" x1="0" y1="0" x2="0" y2="1">
              <Stop offset="0" stopColor={Colors.cyan} stopOpacity="0.25" />
              <Stop offset="1" stopColor={Colors.cyan} stopOpacity="0" />
            </LinearGradient>
          </Defs>

          {/* Area fill */}
          {areaPath && <Path d={areaPath} fill="url(#progGrad)" />}

          {/* Trend line */}
          {path && (
            <Path
              d={path}
              stroke={Colors.cyan}
              strokeWidth={2}
              fill="none"
              strokeLinecap="round"
              strokeLinejoin="round"
            />
          )}

          {/* Data dots */}
          {dotPositions.map((pt, i) => (
            <Circle
              key={i}
              cx={pt.x}
              cy={pt.y}
              r={dotRadius(pt.repPosition)}
              fill={Colors.cyan}
              opacity={dotOpacity(pt.repPosition)}
            />
          ))}

          {/* PB dot with amber ring */}
          {pbDotPos && (
            <G>
              <Circle
                cx={pbDotPos.x}
                cy={pbDotPos.y}
                r={7}
                fill="none"
                stroke={Colors.amber}
                strokeWidth={2}
              />
              <Circle
                cx={pbDotPos.x}
                cy={pbDotPos.y}
                r={4}
                fill={Colors.amber}
              />
            </G>
          )}
        </Svg>
      </View>

      <View style={styles.legend}>
        <View style={styles.legendDotSmall} />
        <Text style={styles.legendText}>rep 1–3</Text>
        <View style={[styles.legendDotMedium, { opacity: 0.65 }]} />
        <Text style={styles.legendText}>rep 4–6</Text>
        <View style={[styles.legendDotLarge, { opacity: 1 }]} />
        <Text style={styles.legendText}>rep 7–10</Text>
        <View style={styles.legendDotPB} />
        <Text style={styles.legendText}>PB</Text>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  card: {
    backgroundColor: Colors.surface,
    borderRadius: Radius.md,
    borderWidth: 1,
    borderColor: Colors.border,
    padding: Space[3],
    marginHorizontal: Space[4],
    marginVertical: Space[2],
  },
  cardHeader: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    marginBottom: Space[2],
  },
  setLabelText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.xs,
    color: Colors.muted,
    letterSpacing: 0.5,
    textTransform: "uppercase",
  },
  pbLabel: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.xs,
    color: Colors.amber,
  },
  chartArea: {
    alignItems: "center",
  },
  legend: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    gap: Space[2],
    marginTop: Space[2],
  },
  legendDotSmall: {
    width: 5,
    height: 5,
    borderRadius: 2.5,
    backgroundColor: Colors.cyan,
    opacity: 0.3,
  },
  legendDotMedium: {
    width: 7,
    height: 7,
    borderRadius: 3.5,
    backgroundColor: Colors.cyan,
  },
  legendDotLarge: {
    width: 10,
    height: 10,
    borderRadius: 5,
    backgroundColor: Colors.cyan,
  },
  legendDotPB: {
    width: 8,
    height: 8,
    borderRadius: 4,
    backgroundColor: Colors.amber,
  },
  legendText: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.xs - 1,
    color: Colors.dim,
  },
  firstTimeCard: {
    backgroundColor: Colors.surface,
    borderRadius: Radius.md,
    borderWidth: 1,
    borderColor: Colors.border,
    paddingVertical: Space[4],
    paddingHorizontal: Space[4],
    marginHorizontal: Space[4],
    marginVertical: Space[2],
    alignItems: "center",
    minHeight: 56,
    justifyContent: "center",
  },
  firstTimeStar: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.base,
    color: Colors.cyan,
    marginBottom: Space[1],
  },
  firstTimeText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.sm,
    color: Colors.muted,
  },
  firstTimeSubtext: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.xs,
    color: Colors.dim,
    marginTop: 2,
  },
});
