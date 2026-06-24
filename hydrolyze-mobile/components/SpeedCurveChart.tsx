import React, { useMemo } from 'react'
import { View, Text, StyleSheet, type ViewStyle } from 'react-native'
import Svg, { Line, Path, Circle, Text as SvgText } from 'react-native-svg'
import { fitSpeedCurve, curvePoints } from '../lib/speed-curve'
import { Colors, FontFamily, FontSize, Space } from '../lib/theme'
import type { Stroke } from '../lib/ml-pairing'

interface PB {
  stroke: Stroke
  distance: number
  pb_ms: number
}

interface Props {
  pbs: PB[]
  stroke: Stroke
  width: number
}

const CHART_HEIGHT = 160
const PAD = { top: 16, right: 16, bottom: 32, left: 44 }

const DIST_MIN = 25
const DIST_MAX = 1500

function logScale(d: number, w: number): number {
  return (Math.log(d) - Math.log(DIST_MIN)) / (Math.log(DIST_MAX) - Math.log(DIST_MIN)) * w
}

function speedMs(distance: number, pb_ms: number): number {
  return distance / pb_ms * 1000
}

export function SpeedCurveChart({ pbs, stroke, width }: Props) {
  const strokePBs = pbs.filter(p => p.stroke === stroke)
  const chartW = width - PAD.left - PAD.right
  const chartH = CHART_HEIGHT - PAD.top - PAD.bottom

  const { curve, speeds, yMin, yMax, xTicks, yTicks, linePath } = useMemo(() => {
    const curvePBs = strokePBs.map(p => ({ distance: p.distance, pb_ms: p.pb_ms }))
    const curve = fitSpeedCurve(curvePBs)

    const speeds = strokePBs.map(p => speedMs(p.distance, p.pb_ms))
    const allSpeeds = speeds.length > 0 ? speeds : [1.0, 2.5]

    const rawMin = Math.min(...allSpeeds)
    const rawMax = Math.max(...allSpeeds)
    const margin = (rawMax - rawMin) * 0.2 || 0.3
    const yMin = rawMin - margin
    const yMax = rawMax + margin

    // X ticks: standard distances within range
    const stdDist = [25, 50, 100, 200, 400, 800, 1500]
    const xTicks = stdDist

    // Y ticks: 4 evenly spaced speed values
    const yStep = (yMax - yMin) / 3
    const yTicks = [0, 1, 2, 3].map(i => yMin + i * yStep)

    // Curve line as SVG path
    let linePath = ''
    if (curve) {
      const pts = curvePoints(curve, DIST_MIN, DIST_MAX, 60)
      pts.forEach(({ distance, speed_ms }, i) => {
        const x = PAD.left + logScale(distance, chartW)
        const y = PAD.top + chartH - ((speed_ms - yMin) / (yMax - yMin)) * chartH
        linePath += i === 0 ? `M${x.toFixed(1)},${y.toFixed(1)}` : ` L${x.toFixed(1)},${y.toFixed(1)}`
      })
    }

    return { curve, speeds, yMin, yMax, xTicks, yTicks, linePath }
  }, [strokePBs, chartW, chartH])

  const toX = (d: number) => PAD.left + logScale(d, chartW)
  const toY = (s: number) => PAD.top + chartH - ((s - yMin) / (yMax - yMin)) * chartH

  if (strokePBs.length === 0) {
    return (
      <View style={[styles.empty, { width, height: CHART_HEIGHT }]}>
        <Text style={styles.emptyText}>No PBs for {stroke} — add one to see the curve</Text>
      </View>
    )
  }

  return (
    <View style={styles.container}>
      <Svg width={width} height={CHART_HEIGHT}>
        {/* Axis lines */}
        <Line
          x1={PAD.left} y1={PAD.top}
          x2={PAD.left} y2={PAD.top + chartH}
          stroke={Colors.border} strokeWidth={1}
        />
        <Line
          x1={PAD.left} y1={PAD.top + chartH}
          x2={PAD.left + chartW} y2={PAD.top + chartH}
          stroke={Colors.border} strokeWidth={1}
        />

        {/* Y gridlines + labels */}
        {yTicks.map((s, i) => {
          const y = toY(s)
          return (
            <React.Fragment key={i}>
              <Line
                x1={PAD.left} y1={y}
                x2={PAD.left + chartW} y2={y}
                stroke={Colors.border} strokeWidth={0.5} strokeDasharray="3,4"
              />
              <SvgText
                x={PAD.left - 4} y={y + 4}
                textAnchor="end"
                fontSize={9}
                fontFamily={FontFamily.monoMedium}
                fill={Colors.dim}
              >
                {s.toFixed(1)}
              </SvgText>
            </React.Fragment>
          )
        })}

        {/* X tick labels */}
        {xTicks.map(d => {
          const x = toX(d)
          const label = d >= 1000 ? `${d / 1000}k` : `${d}`
          return (
            <SvgText
              key={d}
              x={x} y={PAD.top + chartH + 14}
              textAnchor="middle"
              fontSize={9}
              fontFamily={FontFamily.monoMedium}
              fill={Colors.dim}
            >
              {label}
            </SvgText>
          )
        })}

        {/* Fitted curve */}
        {linePath ? (
          <Path
            d={linePath}
            stroke={curve?.fitMethod === 'single_pb_fixed_slope' ? Colors.dim : Colors.muted}
            strokeWidth={1.5}
            strokeDasharray={curve?.fitMethod === 'single_pb_fixed_slope' ? '5,4' : undefined}
            fill="none"
          />
        ) : null}

        {/* PB dots */}
        {strokePBs.map((pb, i) => {
          const x = toX(pb.distance)
          const y = toY(speedMs(pb.distance, pb.pb_ms))
          return (
            <Circle
              key={i}
              cx={x} cy={y}
              r={4}
              fill={Colors.cyan}
              stroke={Colors.base}
              strokeWidth={1.5}
            />
          )
        })}
      </Svg>

      {/* Axis labels */}
      <View style={styles.axisLabels}>
        <Text style={styles.yLabel}>m/s</Text>
        <Text style={styles.xLabel}>distance (m)</Text>
      </View>
    </View>
  )
}

const styles = StyleSheet.create({
  container: {
    backgroundColor: Colors.surface,
    borderRadius: 8,
    overflow: 'hidden',
    position: 'relative',
  },
  axisLabels: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    pointerEvents: 'none',
  } as ViewStyle,
  yLabel: {
    position: 'absolute',
    top: PAD.top,
    left: 2,
    fontFamily: FontFamily.ui,
    fontSize: 8,
    color: Colors.dim,
  },
  xLabel: {
    position: 'absolute',
    bottom: 2,
    right: PAD.right,
    fontFamily: FontFamily.ui,
    fontSize: 8,
    color: Colors.dim,
  },
  empty: {
    backgroundColor: Colors.surface,
    borderRadius: 8,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: Space[4],
  },
  emptyText: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.xs,
    color: Colors.dim,
    textAlign: 'center',
  },
})
