/**
 * SwimmerCard — shows lap time, swimmer name, residual, source badge, and maturity.
 *
 * Props:
 *   time          — RecordedTime from WorkoutContext
 *   swimmerName    — display name for the assigned swimmer
 *   errorMs       — |lapTime − expected| in ms
 *   source        — 'recorded' | 'curve' | 'seed' | null
 *   sampleCount   — number of recorded times for this swimmer/context
 *   suspicious    — best residual > 4s
 *   ambiguous     — top two swimmers are close
 *   isIM          — IM stroke (always manual)
 *   onDelete      — remove this time
 *   onSwap        — reassign to a different swimmer
 */

import { View, Text, StyleSheet, StyleProp, ViewStyle, TextStyle } from 'react-native'
import { Swipeable } from 'react-native-gesture-handler'
import { TouchableOpacity } from 'react-native'
import { Colors, FontFamily, FontSize, Space, Radius, TouchTarget } from '../lib/theme'
import type { RecordedTime } from '../context/SessionContext'

// ─── Props ─────────────────────────────────────────────────────────────────────

interface SwimmerCardProps {
  time: RecordedTime
  swimmerName?: string
  errorMs?: number
  source?: 'recorded' | 'curve' | 'seed' | 'no_data' | null
  sampleCount?: number
  suspicious?: boolean
  ambiguous?: boolean
  onDelete: (id: string) => void
  onSwap: (id: string) => void
  isIM?: boolean
}

// ─── Formatting helpers ───────────────────────────────────────────────────────

function formatMs(ms: number): string {
  const totalSeconds = ms / 1000
  const mins = Math.floor(totalSeconds / 60)
  const secs = (totalSeconds % 60).toFixed(1).padStart(4, '0')
  return mins > 0 ? `${mins}:${secs}` : `${secs}`
}

function formatError(ms: number): string {
  if (!isFinite(ms) || ms === Infinity) return '—'
  if (ms === 0) return 'exact'
  if (ms < 1000) return `${Math.round(ms)}ms off`
  return `${(ms / 1000).toFixed(1)}s off`
}

// ─── Badge: source ────────────────────────────────────────────────────────────

function SourceBadge({ source }: { source: string | undefined | null }) {
  let label = 'no data'
  let bg = '#30363d'
  let color = '#8b949e'

  if (source === 'recorded') { label = 'real data'; bg = '#1158c7'; color = '#fff' }
  else if (source === 'curve')  { label = 'from PB';   bg = '#6e40c9'; color = '#fff' }
  else if (source === 'seed')   { label = 'estimate';  bg = '#30363d'; color = '#8b949e' }

  return (
    <View style={[badge.badge, { backgroundColor: bg as string }]}>
      <Text style={[badge.badgeText, { color: color as string }]}>{label}</Text>
    </View>
  )
}

// ─── Badge: maturity dot ───────────────────────────────────────────────────────

function MaturityBadge({ count }: { count: number | undefined }) {
  if (!count) {
    return <Text style={styles.sampleLabel}>no data</Text>
  }

  const color = count >= 16 ? '#16a34a'
             : count >= 6  ? '#22c55e'
             : count >= 1  ? '#86efac'
             : '#eab308'

  const label = count >= 16 ? 'excellent'
              : count >= 6  ? 'reliable'
              : 'learning'

  const dotSize = count >= 6 ? 8 : 6

  return (
    <View style={styles.maturityRow}>
      <View style={[badge.dot, { width: dotSize, height: dotSize, borderRadius: dotSize / 2, backgroundColor: color }]} />
      <Text style={styles.sampleLabel}>{label}</Text>
    </View>
  )
}

// ─── Swipe actions ────────────────────────────────────────────────────────────

function DeleteAction({ onDelete, id }: { onDelete: (id: string) => void; id: string }) {
  return (
    <TouchableOpacity style={swipe.deleteAction} onPress={() => onDelete(id)}>
      <Text style={swipe.deleteText}>Delete</Text>
    </TouchableOpacity>
  )
}

function SwapAction({ onSwap, id }: { onSwap: (id: string) => void; id: string }) {
  return (
    <TouchableOpacity style={swipe.swapAction} onPress={() => onSwap(id)}>
      <Text style={swipe.swapText}>Swap</Text>
    </TouchableOpacity>
  )
}

// ─── Main component ───────────────────────────────────────────────────────────

export function SwimmerCard({
  time, swimmerName, errorMs, source, sampleCount,
  suspicious, ambiguous, onDelete, onSwap, isIM,
}: SwimmerCardProps) {
  const isTappable = !!time.assignment

  // Row background — type as string to accept rgba and hex values
  let rowBg: string = Colors.surface
  if (suspicious)        rowBg = 'rgba(220,38,38,0.08)'
  else if (ambiguous)    rowBg = 'rgba(234,179,8,0.06)'
  else if (isIM)         rowBg = 'rgba(9,212,238,0.04)'
  else if (time.assignment) rowBg = 'rgba(16,185,129,0.04)'

  // Name + residual colors
  const nameColor = suspicious ? '#fca5a5' : ambiguous ? '#fde68a' : isIM ? Colors.amber : Colors.text
  const nameStyle = { color: nameColor }

  return (
    <Swipeable
      renderRightActions={() => <SwapAction onSwap={onSwap} id={time.id} />}
      renderLeftActions={() => <DeleteAction onDelete={onDelete} id={time.id} />}
      friction={2}
      overshootLeft={false}
      overshootRight={false}
    >
      <TouchableOpacity
        style={[styles.row, { backgroundColor: rowBg }]}
        activeOpacity={isTappable ? 0.7 : 1}
        onPress={() => { if (isTappable) onSwap(time.id) }}
      >
        {/* Column 1: elapsed time */}
        <Text style={styles.time}>{formatMs(time.elapsedMs)}</Text>

        {/* Column 2: swimmer name + residual */}
        <View style={styles.nameCol}>
          {isIM ? (
            <Text style={[styles.name, { color: Colors.amber }]}>IM — assign after</Text>
          ) : (
            <Text style={[styles.name, nameStyle]}>{swimmerName ?? '—'}</Text>
          )}
          {time.assignment && !isIM && (
            <Text style={styles.residual}>{formatError(errorMs ?? 0)}</Text>
          )}
        </View>

        {/* Column 3: source badge + maturity */}
        <View style={styles.badgeCol}>
          {source != null && !isIM && <SourceBadge source={source} />}
          {source == null && !isIM && <SourceBadge source={null} />}
          {sampleCount !== undefined && (
            <MaturityBadge count={sampleCount} />
          )}
        </View>

        {/* Swipe affordance hint */}
        {time.assignment && <Text style={styles.swapHint}>swap</Text>}
      </TouchableOpacity>
    </Swipeable>
  )
}

// ─── Styles ───────────────────────────────────────────────────────────────────

const styles = StyleSheet.create({
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    height: TouchTarget.swimRow,
    paddingHorizontal: Space[4],
    backgroundColor: Colors.surface,
    borderBottomWidth: 1,
    borderBottomColor: Colors.border,
    gap: Space[2],
  },

  time: {
    fontFamily: FontFamily.mono,
    fontSize: FontSize.lg,
    color: Colors.text,
    width: 72,
    fontVariant: ['tabular-nums'],
  },

  nameCol: {
    flex: 1,
    flexDirection: 'row',
    alignItems: 'center',
    gap: Space[2],
    minWidth: 0,
  },

  name: {
    fontFamily: FontFamily.uiMedium,
    fontSize: FontSize.base,
    color: Colors.text,
    flexShrink: 0,
  },

  residual: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.sm,
    color: Colors.dim,
    flexShrink: 0,
  },

  badgeCol: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: Space[2],
    flexShrink: 0,
  },

  maturityRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 4,
  },

  sampleLabel: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.xs,
    color: Colors.dim,
  },

  swapHint: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.xs,
    color: Colors.dim,
    width: 32,
    textAlign: 'right',
  },
})

const badge = StyleSheet.create({
  badge: {
    paddingHorizontal: 6,
    paddingVertical: 2,
    borderRadius: Radius.sm,
  },
  badgeText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.xs - 1,
    letterSpacing: 0.3,
  },
  dot: {
    // sized dynamically
  },
})

const swipe = StyleSheet.create({
  swapAction: {
    backgroundColor: Colors.cyan,
    justifyContent: 'center',
    alignItems: 'center',
    width: 72,
  },
  swapText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.sm,
    color: '#000',
  },
  deleteAction: {
    backgroundColor: Colors.danger,
    justifyContent: 'center',
    alignItems: 'center',
    width: 72,
  },
  deleteText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.sm,
    color: Colors.text,
  },
})