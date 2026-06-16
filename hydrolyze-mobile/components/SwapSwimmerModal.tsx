/**
 * SwapSwimmerModal — reassign a recorded lap time to a different swimmer.
 *
 * Shows the full ranking so the coach can see exactly why the current
 * assignment was made and what the alternatives are.
 *
 * Coach sees:
 *   - Recorded time (what they tapped)
 *   - Current assignment (who it was assigned to)
 *   - Full ranked list: swimmer | their typical pace | how far off
 *
 * The ranking uses residual = |lap - expected| sorted ascending.
 * Lower residual = more likely to have swum this time.
 */

import React, { useMemo } from 'react'
import {
  View, Text, ScrollView, TouchableOpacity, StyleSheet, Modal
} from 'react-native'
import { Colors, FontFamily, FontSize, Space, Radius, TouchTarget } from '../lib/theme'
import type { Swimmer, StatsCache } from '../lib/ml-pairing'
import { rankSwimmers } from '../lib/ml-pairing'
import type { Stroke } from '../lib/ml-pairing'
import type { IntensityLevel } from '../lib/set-parser'

interface SwapModalProps {
  visible: boolean
  recordedTimeMs: number
  currentAssignment: { swimmerId: string } | null
  currentSwimmerName: string | undefined
  pool: Swimmer[]
  statsCache: StatsCache
  stroke: Stroke
  intensity: IntensityLevel | null
  distance: number
  gear: string | null
  onSelect: (swimmerId: string) => void
  onClose: () => void
}

// ─── Formatting helpers ─────────────────────────────────────────────────────────

function formatMs(ms: number): string {
  const totalSeconds = ms / 1000
  const mins = Math.floor(totalSeconds / 60)
  const secs = (totalSeconds % 60).toFixed(1).padStart(4, '0')
  return mins > 0 ? `${mins}:${secs}` : `${secs}`
}

function formatError(errorMs: number): string {
  if (errorMs === Infinity) return '—'
  if (errorMs === 0) return 'exact'
  if (errorMs < 1000) return `${Math.round(errorMs)}ms off`
  return `${(errorMs / 1000).toFixed(1)}s off`
}

function sourceLabel(source: string): string {
  if (source === 'recorded') return 'real data'
  if (source === 'curve') return 'from PB'
  if (source === 'seed') return 'estimate'
  return 'no data'
}

// ─── Swimmer row ────────────────────────────────────────────────────────────────

interface SwimmerRowProps {
  swimmerId: string
  swimmerName: string
  expectedTimeMs: number
  errorMs: number
  source: string
  sampleCount: number
  isCurrentAssignment: boolean
  onPress: () => void
}

function SwimmerRow({
  swimmerId, swimmerName, expectedTimeMs, errorMs,
  source, sampleCount, isCurrentAssignment, onPress,
}: SwimmerRowProps) {
  const errorLabel = formatError(errorMs)
  const isExact = errorMs === 0
  const hasData = source !== 'no_data'

  return (
    <TouchableOpacity
      style={[styles.row, isCurrentAssignment && styles.rowSelected]}
      activeOpacity={0.7}
      onPress={onPress}
    >
      <View style={styles.nameCol}>
        {isCurrentAssignment && <View style={styles.currentDot} />}
        <Text style={[styles.name, isCurrentAssignment && styles.nameSelected]}>
          {swimmerName}
        </Text>
        {hasData && (
          <Text style={styles.sourceLabel}>{sourceLabel(source)}</Text>
        )}
        {sampleCount > 0 && (
          <Text style={styles.sampleLabel}>{sampleCount}×</Text>
        )}
      </View>
      <View style={styles.expectedCol}>
        {hasData ? (
          <Text style={styles.expected}>{formatMs(expectedTimeMs)}</Text>
        ) : (
          <Text style={styles.expectedNoData}>—</Text>
        )}
      </View>
      <View style={styles.errorCol}>
        <Text style={[styles.error, isExact && styles.errorExact]}>
          {errorLabel}
        </Text>
      </View>
      {isCurrentAssignment && (
        <View style={styles.checkmark}>
          <Text style={styles.checkmarkText}>✓</Text>
        </View>
      )}
    </TouchableOpacity>
  )
}

// ─── Main modal ───────────────────────────────────────────────────────────────

export function SwapModal({
  visible,
  recordedTimeMs,
  currentAssignment,
  currentSwimmerName,
  pool,
  statsCache,
  stroke,
  intensity,
  distance,
  gear,
  onSelect,
  onClose,
}: SwapModalProps) {
  const ranked = useMemo(
    () => rankSwimmers(recordedTimeMs, pool, statsCache, stroke, intensity ?? undefined, distance, gear),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [recordedTimeMs, pool, statsCache, stroke, intensity, distance, gear],
  )

  return (
    <Modal visible={visible} animationType="slide" onRequestClose={onClose}>
      <View style={styles.modal}>
        {/* Header */}
        <View style={styles.header}>
          <TouchableOpacity onPress={onClose} style={styles.closeButton}>
            <Text style={styles.closeText}>Cancel</Text>
          </TouchableOpacity>
          <Text style={styles.title}>Reassign Time</Text>
          <View style={styles.closeButton} />
        </View>

        {/* Recorded time card */}
        <View style={styles.timeCard}>
          <Text style={styles.timeCardLabel}>Recorded time</Text>
          <Text style={styles.timeCardValue}>{formatMs(recordedTimeMs)}</Text>
          {currentSwimmerName && (
            <Text style={styles.timeCardCurrent}>
              currently <Text style={styles.timeCardCurrentName}>{currentSwimmerName}</Text>
            </Text>
          )}
        </View>

        {/* Instructions */}
        <Text style={styles.hint}>
          Tap a swimmer to reassign. Shows their typical pace for this set.
        </Text>

        {/* Ranked swimmer list */}
        <ScrollView style={styles.list} contentContainerStyle={styles.listContent}>
          {ranked.map(item => (
            <SwimmerRow
              key={item.swimmerId}
              swimmerId={item.swimmerId}
              swimmerName={item.swimmerName}
              expectedTimeMs={item.expectedTimeMs}
              errorMs={item.errorMs}
              source={item.source}
              sampleCount={item.sampleCount}
              isCurrentAssignment={currentAssignment?.swimmerId === item.swimmerId}
              onPress={() => { onSelect(item.swimmerId); onClose() }}
            />
          ))}
        </ScrollView>
      </View>
    </Modal>
  )
}

// ─── Styles ──────────────────────────────────────────────────────────────────

const styles = StyleSheet.create({
  modal: { flex: 1, backgroundColor: Colors.base },

  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: Space[4],
    paddingTop: 44 + Space[4],
    paddingBottom: Space[4],
    borderBottomWidth: 1,
    borderBottomColor: Colors.border,
  },
  closeButton: { width: 70 },
  closeText: {
    fontFamily: FontFamily.uiMedium,
    fontSize: FontSize.base,
    color: Colors.cyan,
  },
  title: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.base,
    color: Colors.text,
  },

  timeCard: {
    margin: Space[4],
    padding: Space[4],
    backgroundColor: Colors.surface,
    borderRadius: Radius.md,
    borderWidth: 1,
    borderColor: Colors.border,
    alignItems: 'center',
  },
  timeCardLabel: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.sm,
    color: Colors.dim,
    marginBottom: Space[1],
  },
  timeCardValue: {
    fontFamily: FontFamily.mono,
    fontSize: FontSize.xl,
    color: Colors.text,
    marginBottom: Space[1],
  },
  timeCardCurrent: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.sm,
    color: Colors.muted,
  },
  timeCardCurrentName: {
    color: Colors.cyan,
    fontFamily: FontFamily.uiMedium,
  },

  hint: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.sm,
    color: Colors.dim,
    paddingHorizontal: Space[4],
    marginBottom: Space[3],
  },

  list: { flex: 1 },
  listContent: { paddingBottom: Space[8] },

  row: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingVertical: Space[3],
    paddingHorizontal: Space[4],
    borderBottomWidth: 1,
    borderBottomColor: Colors.border,
    minHeight: TouchTarget.min,
  },
  rowSelected: {
    backgroundColor: Colors.cyanDim,
    borderLeftWidth: 3,
    borderLeftColor: Colors.cyan,
  },

  nameCol: {
    flex: 1,
    flexDirection: 'row',
    alignItems: 'center',
    gap: Space[2],
    flexWrap: 'wrap',
  },
  currentDot: {
    width: 6, height: 6, borderRadius: 3,
    backgroundColor: Colors.cyan,
  },
  name: {
    fontFamily: FontFamily.uiMedium,
    fontSize: FontSize.base,
    color: Colors.muted,
  },
  nameSelected: { color: Colors.cyan },

  sourceLabel: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.xs - 1,
    color: Colors.dim,
  },
  sampleLabel: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.xs - 1,
    color: Colors.dim,
  },

  expectedCol: { width: 80, alignItems: 'flex-end' },
  expected: {
    fontFamily: FontFamily.mono,
    fontSize: FontSize.base,
    color: Colors.muted,
  },
  expectedNoData: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.base,
    color: Colors.dim,
  },

  errorCol: { width: 72, alignItems: 'flex-end' },
  error: {
    fontFamily: FontFamily.uiMedium,
    fontSize: FontSize.sm,
    color: Colors.dim,
  },
  errorExact: { color: Colors.optimal },

  checkmark: { width: 32, alignItems: 'center' },
  checkmarkText: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.lg,
    color: Colors.cyan,
  },
})