import React, { useMemo } from 'react'
import { View, StyleSheet, Dimensions } from 'react-native'
import Svg, { Path, Defs, LinearGradient, Stop, Circle } from 'react-native-svg'
import { Colors, Space } from '../lib/theme'

interface Props {
  times: { rep: number; time: number }[]
  width?: number
  height?: number
}

const PAD = 10

export function WorkoutTrendChart({ times, width, height = 80 }: Props) {
  const chartWidth = width || Dimensions.get('window').width - Space[12]
  const chartHeight = height
  
  const { path, areaPath, points } = useMemo(() => {
    if (times.length < 2) return { path: '', areaPath: '', points: [] }

    const minTime = Math.min(...times.map(t => t.time))
    const maxTime = Math.max(...times.map(t => t.time))
    const range = maxTime - minTime || 1000 // handle flat lines
    
    // Add 10% vertical padding
    const yMin = minTime - range * 0.1
    const yMax = maxTime + range * 0.1
    const yRange = yMax - yMin

    const stepX = (chartWidth - 2 * PAD) / (times.length - 1)
    
    const pts = times.map((t, i) => ({
      x: PAD + i * stepX,
      y: chartHeight - PAD - ((t.time - yMin) / yRange) * (chartHeight - 2 * PAD)
    }))

    // Generate smooth curve using simple Catmull-Rom or Bezier logic
    // For now, let's start with a clean line and then smoothing
    let p = `M${pts[0].x},${pts[0].y}`
    
    // Bezier smoothing
    for (let i = 0; i < pts.length - 1; i++) {
      const curr = pts[i]
      const next = pts[i + 1]
      const cpX = (curr.x + next.x) / 2
      p += ` C${cpX},${curr.y} ${cpX},${next.y} ${next.x},${next.y}`
    }

    const area = `${p} L${pts[pts.length - 1].x},${chartHeight} L${pts[0].x},${chartHeight} Z`

    return { path: p, areaPath: area, points: pts }
  }, [times, chartWidth, chartHeight])

  if (times.length < 2) return null

  return (
    <View style={styles.container}>
      <Svg width={chartWidth} height={chartHeight}>
        <Defs>
          <LinearGradient id="grad" x1="0" y1="0" x2="0" y2="1">
            <Stop offset="0" stopColor={Colors.cyan} stopOpacity="0.3" />
            <Stop offset="1" stopColor={Colors.cyan} stopOpacity="0" />
          </LinearGradient>
        </Defs>

        {/* Area fill */}
        <Path d={areaPath} fill="url(#grad)" />

        {/* Trend line */}
        <Path
          d={path}
          stroke={Colors.cyan}
          strokeWidth={2.5}
          fill="none"
          strokeLinecap="round"
          strokeLinejoin="round"
        />

        {/* Dot for last rep */}
        <Circle
          cx={points[points.length - 1].x}
          cy={points[points.length - 1].y}
          r={3}
          fill={Colors.cyan}
          stroke={Colors.surface}
          strokeWidth={1}
        />
      </Svg>
    </View>
  )
}

const styles = StyleSheet.create({
  container: {
    marginVertical: Space[2],
    alignItems: 'center',
  },
})
