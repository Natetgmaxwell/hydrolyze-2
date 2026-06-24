import { useState, useCallback } from 'react'
import {
  View, Text, FlatList, TouchableOpacity, StyleSheet,
  Modal, TextInput, Alert, useWindowDimensions,
} from 'react-native'
import { useLocalSearchParams, useNavigation, useFocusEffect } from 'expo-router'
import { supabase } from '../../lib/supabase'
import { Colors, FontFamily, FontSize, Space, Radius, TouchTarget } from '../../lib/theme'
import { SpeedCurveChart } from '../../components/SpeedCurveChart'
import type { Stroke } from '../../lib/ml-pairing'

const STROKES: Stroke[] = ['Free', 'Back', 'Breast', 'Fly', 'IM']
const DISTANCES = [25, 50, 100, 200, 400, 800, 1500]

interface PbRow {
  stroke: Stroke
  distance: number
  pb_ms: number
}

function parseTime(raw: string): number | null {
  const trimmed = raw.trim()
  const withMinutes = trimmed.match(/^(\d+):(\d{1,2})(?:\.(\d+))?$/)
  if (withMinutes) {
    const mins = parseInt(withMinutes[1], 10)
    const secs = parseInt(withMinutes[2], 10)
    const frac = withMinutes[3] ? parseFloat(`0.${withMinutes[3]}`) : 0
    if (secs >= 60) return null
    return Math.round((mins * 60 + secs + frac) * 1000)
  }
  const secsOnly = trimmed.match(/^(\d+)(?:\.(\d+))?$/)
  if (secsOnly) {
    const secs = parseInt(secsOnly[1], 10)
    const frac = secsOnly[2] ? parseFloat(`0.${secsOnly[2]}`) : 0
    return Math.round((secs + frac) * 1000)
  }
  return null
}

function formatMs(ms: number): string {
  const totalSecs = ms / 1000
  const mins = Math.floor(totalSecs / 60)
  const secs = (totalSecs % 60).toFixed(2).padStart(5, '0')
  return mins > 0 ? `${mins}:${secs}` : `${totalSecs.toFixed(2)}`
}

export default function SwimmerPBScreen() {
  const { id } = useLocalSearchParams<{ id: string }>()
  const navigation = useNavigation()
  const { width: screenWidth } = useWindowDimensions()

  const [name, setName] = useState('')
  const [pbs, setPbs] = useState<PbRow[]>([])
  const [selectedStroke, setSelectedStroke] = useState<Stroke>('Free')
  const [showModal, setShowModal] = useState(false)

  // Modal state
  const [modalStroke, setModalStroke] = useState<Stroke | null>(null)
  const [modalDistance, setModalDistance] = useState<number | null>(null)
  const [timeInput, setTimeInput] = useState('')
  const [saving, setSaving] = useState(false)

  async function load() {
    const [swimmerResult, pbResult] = await Promise.all([
      supabase.from('swimmers').select('name').eq('id', id).single(),
      supabase
        .from('swimmer_pbs')
        .select('stroke, distance, pb_ms')
        .eq('swimmer_id', id)
        .order('stroke')
        .order('distance'),
    ])

    if (swimmerResult.data) {
      setName(swimmerResult.data.name)
      navigation.setOptions({ title: swimmerResult.data.name })
    }

    const loaded = (pbResult.data ?? []) as PbRow[]
    setPbs(loaded)

    // Auto-select the stroke with the most PBs
    if (loaded.length > 0) {
      const counts: Record<string, number> = {}
      for (const p of loaded) counts[p.stroke] = (counts[p.stroke] ?? 0) + 1
      const best = Object.entries(counts).sort((a, b) => b[1] - a[1])[0][0] as Stroke
      setSelectedStroke(best)
    }
  }

  useFocusEffect(useCallback(() => { load() }, [id]))

  async function handleSave() {
    if (!modalStroke || !modalDistance || !timeInput.trim()) return
    const ms = parseTime(timeInput)
    if (!ms || ms <= 0) {
      Alert.alert('Invalid time', 'Enter a time like 25.4 or 1:03.5')
      return
    }

    setSaving(true)
    const { error } = await supabase
      .from('swimmer_pbs')
      .upsert({
        swimmer_id: id,
        stroke: modalStroke,
        distance: modalDistance,
        pb_ms: ms,
        updated_at: new Date().toISOString(),
      }, { onConflict: 'swimmer_id,stroke,distance' })

    setSaving(false)
    if (error) { Alert.alert('Error', error.message); return }

    setShowModal(false)
    setModalStroke(null)
    setModalDistance(null)
    setTimeInput('')
    load()
  }

  async function handleDelete(stroke: Stroke, distance: number) {
    Alert.alert(
      'Delete PB',
      `Remove ${stroke} ${distance}m PB for ${name}?`,
      [
        { text: 'Cancel', style: 'cancel' },
        {
          text: 'Delete', style: 'destructive',
          onPress: async () => {
            await supabase
              .from('swimmer_pbs')
              .delete()
              .eq('swimmer_id', id)
              .eq('stroke', stroke)
              .eq('distance', distance)
            load()
          },
        },
      ]
    )
  }

  function openAddModal() {
    setModalStroke(selectedStroke)
    setModalDistance(null)
    setTimeInput('')
    setShowModal(true)
  }

  const canSave = modalStroke !== null && modalDistance !== null && timeInput.trim().length > 0
  const strokePBs = pbs.filter(p => p.stroke === selectedStroke)
  const chartWidth = screenWidth - Space[6] * 2

  // Only show strokes that have at least one PB, plus any stroke with no PBs is addable
  const strokesWithPBs = new Set(pbs.map(p => p.stroke))

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <Text style={styles.screenLabel}>PERSONAL BESTS</Text>
        <Text style={styles.hint}>
          Used by the algorithm to predict which time belongs to {name}.
        </Text>
      </View>

      {/* Stroke selector */}
      <View style={styles.strokeSelector}>
        {STROKES.map(s => (
          <TouchableOpacity
            key={s}
            style={[styles.strokeChip, selectedStroke === s && styles.strokeChipActive]}
            onPress={() => setSelectedStroke(s)}
            activeOpacity={0.7}
          >
            <Text style={[styles.strokeChipText, selectedStroke === s && styles.strokeChipTextActive]}>
              {s}
              {strokesWithPBs.has(s) ? ` (${pbs.filter(p => p.stroke === s).length})` : ''}
            </Text>
          </TouchableOpacity>
        ))}
      </View>

      {/* Speed-distance chart */}
      <View style={styles.chartContainer}>
        <Text style={styles.chartLabel}>SPEED — DISTANCE CURVE</Text>
        <SpeedCurveChart pbs={pbs} stroke={selectedStroke} width={chartWidth} />
        {pbs.filter(p => p.stroke === selectedStroke).length === 1 && (
          <Text style={styles.chartHint}>
            Dashed line = extrapolated from 1 PB using typical speed decay.
            Add more PBs to improve accuracy.
          </Text>
        )}
      </View>

      {/* PB list for selected stroke */}
      <FlatList
        data={strokePBs}
        keyExtractor={p => `${p.stroke}:${p.distance}`}
        style={styles.list}
        ListEmptyComponent={
          <View style={styles.empty}>
            <Text style={styles.emptyText}>No {selectedStroke} PBs yet.</Text>
            <Text style={styles.emptyHint}>Tap "+ Add PB" to add one.</Text>
          </View>
        }
        renderItem={({ item }) => (
          <TouchableOpacity
            style={styles.pbRow}
            onLongPress={() => handleDelete(item.stroke, item.distance)}
            activeOpacity={0.7}
          >
            <Text style={styles.pbEvent}>{item.distance}m {item.stroke}</Text>
            <Text style={styles.pbTime}>{formatMs(item.pb_ms)}</Text>
          </TouchableOpacity>
        )}
        ItemSeparatorComponent={() => <View style={styles.separator} />}
      />

      <View style={styles.footer}>
        <Text style={styles.deleteHint}>Long-press a PB to delete it</Text>
        <TouchableOpacity style={styles.addButton} onPress={openAddModal} activeOpacity={0.85}>
          <Text style={styles.addButtonText}>+ Add PB</Text>
        </TouchableOpacity>
      </View>

      <Modal visible={showModal} transparent animationType="slide" onRequestClose={() => setShowModal(false)}>
        <TouchableOpacity style={styles.backdrop} activeOpacity={1} onPress={() => setShowModal(false)} />
        <View style={styles.sheet}>
          <View style={styles.handle} />
          <Text style={styles.modalTitle}>Add Personal Best</Text>

          <Text style={styles.sectionLabel}>STROKE</Text>
          <View style={styles.optionRow}>
            {STROKES.map(s => (
              <TouchableOpacity
                key={s}
                style={[styles.optionChip, modalStroke === s && styles.optionChipActive]}
                onPress={() => setModalStroke(s)}
              >
                <Text style={[styles.optionChipText, modalStroke === s && styles.optionChipTextActive]}>{s}</Text>
              </TouchableOpacity>
            ))}
          </View>

          <Text style={styles.sectionLabel}>DISTANCE</Text>
          <View style={styles.optionRow}>
            {DISTANCES.map(d => (
              <TouchableOpacity
                key={d}
                style={[styles.optionChip, modalDistance === d && styles.optionChipActive]}
                onPress={() => setModalDistance(d)}
              >
                <Text style={[styles.optionChipText, modalDistance === d && styles.optionChipTextActive]}>{d}m</Text>
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
            style={[styles.saveButton, (!canSave || saving) && styles.saveButtonDisabled]}
            onPress={handleSave}
            disabled={!canSave || saving}
            activeOpacity={0.85}
          >
            <Text style={styles.saveButtonText}>{saving ? 'Saving...' : 'Save PB'}</Text>
          </TouchableOpacity>
        </View>
      </Modal>
    </View>
  )
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: Colors.base },

  header: {
    paddingHorizontal: Space[6],
    paddingTop: Space[6],
    paddingBottom: Space[4],
    borderBottomWidth: 1,
    borderBottomColor: Colors.border,
  },
  screenLabel: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.xs,
    color: Colors.dim,
    letterSpacing: 1.2,
    marginBottom: Space[1],
  },
  hint: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.sm,
    color: Colors.muted,
    lineHeight: 18,
  },

  strokeSelector: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: Space[2],
    paddingHorizontal: Space[6],
    paddingVertical: Space[3],
    borderBottomWidth: 1,
    borderBottomColor: Colors.border,
  },
  strokeChip: {
    paddingHorizontal: Space[3],
    paddingVertical: Space[2],
    borderRadius: Radius.md,
    backgroundColor: Colors.elevated,
    borderWidth: 1,
    borderColor: Colors.border,
  },
  strokeChipActive: { backgroundColor: Colors.cyanDim, borderColor: Colors.cyan },
  strokeChipText: {
    fontFamily: FontFamily.uiMedium,
    fontSize: FontSize.sm,
    color: Colors.muted,
  },
  strokeChipTextActive: { color: Colors.cyan },

  chartContainer: {
    paddingHorizontal: Space[6],
    paddingTop: Space[4],
    paddingBottom: Space[3],
    borderBottomWidth: 1,
    borderBottomColor: Colors.border,
  },
  chartLabel: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.xs,
    color: Colors.dim,
    letterSpacing: 1.2,
    marginBottom: Space[2],
  },
  chartHint: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.xs,
    color: Colors.dim,
    marginTop: Space[2],
    lineHeight: 16,
  },

  list: { flex: 1 },

  pbRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    height: TouchTarget.swimRow,
    paddingHorizontal: Space[6],
  },
  pbEvent: {
    fontFamily: FontFamily.uiMedium,
    fontSize: FontSize.base,
    color: Colors.text,
  },
  pbTime: {
    fontFamily: FontFamily.mono,
    fontSize: FontSize.lg,
    color: Colors.cyan,
  },

  separator: { height: 1, backgroundColor: Colors.border, marginHorizontal: Space[6] },

  empty: {
    paddingTop: Space[8],
    alignItems: 'center',
    gap: Space[2],
  },
  emptyText: {
    fontFamily: FontFamily.uiMedium,
    fontSize: FontSize.base,
    color: Colors.muted,
  },
  emptyHint: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.sm,
    color: Colors.dim,
  },

  footer: {
    padding: Space[4],
    paddingTop: Space[3],
    borderTopWidth: 1,
    borderTopColor: Colors.border,
    gap: Space[2],
  },
  deleteHint: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.xs,
    color: Colors.dim,
    textAlign: 'center',
  },
  saveButton: {
    backgroundColor: Colors.cyan,
    borderRadius: Radius.lg,
    height: TouchTarget.min,
    alignItems: 'center',
    justifyContent: 'center',
    boxShadow: `0 0 12px ${Colors.cyanGlow}`,
    elevation: 4,
    elevation: 4,
  },

  addButtonText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.lg,
    color: '#000',
    fontWeight: '600',
  },

  backdrop: { flex: 1, backgroundColor: 'rgba(0,0,0,0.6)' },
  sheet: {
    backgroundColor: Colors.surface,
    borderTopLeftRadius: 20,
    borderTopRightRadius: 20,
    borderTopWidth: 1,
    borderColor: Colors.border,
    padding: Space[6],
    paddingBottom: Space[12],
  },
  handle: {
    width: 36, height: 4, borderRadius: 2,
    backgroundColor: Colors.border,
    alignSelf: 'center',
    marginBottom: Space[4],
  },
  modalTitle: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.lg,
    color: Colors.text,
    marginBottom: Space[4],
  },
  sectionLabel: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.xs,
    color: Colors.dim,
    letterSpacing: 1.2,
    marginBottom: Space[2],
  },
  optionRow: {
    flexDirection: 'row',
    flexWrap: 'wrap',
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
  optionChipTextActive: { color: '#000', fontFamily: FontFamily.uiSemiBold },
  timeInput: {
    backgroundColor: Colors.elevated,
    borderWidth: 1,
    borderColor: Colors.border,
    borderRadius: Radius.md,
    padding: Space[4],
    fontFamily: FontFamily.mono,
    fontSize: 28,
    color: Colors.text,
    textAlign: 'center',
    marginBottom: Space[4],
  },
  saveButton: {
    backgroundColor: Colors.cyan,
    borderRadius: Radius.lg,
    height: TouchTarget.min,
    alignItems: 'center',
    justifyContent: 'center',
  },
  saveButtonDisabled: { opacity: 0.25 },
  saveButtonText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.base,
    color: '#000',
    fontWeight: '600',
  },
})
