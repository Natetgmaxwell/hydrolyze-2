import { useState, useMemo } from 'react'
import {
  View, Text, TextInput, TouchableOpacity,
  StyleSheet, ScrollView, Alert, Modal, FlatList,
} from 'react-native'
import { useRouter } from 'expo-router'
import { supabase } from '../../lib/supabase'
import { useWorkout } from '../../context/WorkoutContext'
import { parseSet, isSetReadyToSubmit, intensityColor, buildIntensityPattern, summarisePattern } from '../../lib/set-parser'
import { Colors, FontFamily, FontSize, Space, Radius, TouchTarget } from '../../lib/theme'
import type { Stroke } from '../../lib/ml-pairing'

const STROKES: Stroke[] = ['Free', 'Back', 'Breast', 'Fly', 'IM', 'Form']

type PickerField = 'reps' | 'distance' | 'stroke' | 'interval'

export default function SetDefinitionScreen() {
  const router = useRouter()
  const { dispatch } = useWorkout()

  const [input, setInput] = useState('')
  const [loading, setLoading] = useState(false)
  const [overrides, setOverrides] = useState<Partial<{
    reps: number; distance: number; stroke: Stroke; interval: string
  }>>({})
  const [pickerField, setPickerField] = useState<PickerField | null>(null)
  const [intervalDraft, setIntervalDraft] = useState('')

  const parsed = useMemo(() => parseSet(input), [input])

  const reps     = overrides.reps     ?? parsed.reps
  const distance = overrides.distance ?? parsed.distance
  const stroke   = overrides.stroke   ?? parsed.stroke
  const interval = overrides.interval ?? parsed.interval
  const ready    = reps !== null && distance !== null

  // Re-derive pattern at the final reps count — reps override may differ from parsed.reps
  const intensityPattern = useMemo(() => {
    if (reps == null) return []
    if (reps === parsed.reps) return parsed.intensityPattern
    return buildIntensityPattern(reps, parsed.intensity, null)
  }, [reps, parsed.reps, parsed.intensityPattern, parsed.intensity])

  function openPicker(field: PickerField) {
    if (field === 'interval') setIntervalDraft(interval ?? '')
    setPickerField(field)
  }

  function applyOverride(field: PickerField, value: unknown) {
    setOverrides(prev => ({ ...prev, [field]: value }))
    setPickerField(null)
  }

  async function handleNext() {
    if (!ready) return
    setLoading(true)
    try {
      const { data: session, error: sessionError } = await supabase
        .from('sessions')
        .insert({
          name: `Practice ${new Date().toLocaleDateString()}`,
          date: new Date().toISOString().split('T')[0],
        })
        .select()
        .single()
      if (sessionError) throw sessionError

      const { data: swimSet, error: setError } = await supabase
        .from('swim_sets')
        .insert({
          session_id: session.id,
          description: input.trim() || `${reps}×${distance} ${stroke ?? 'Free'}`,
          reps,
          distance,
          stroke: stroke ?? 'Free',
          interval: interval ?? null,
          intensity_type: parsed.intensity?.type ?? null,
          intensity_pace_distance: parsed.intensity?.paceDistance ?? null,
          intensity_label: parsed.intensity?.label ?? null,
        })
        .select()
        .single()
      if (setError) throw setError

      dispatch({
        type: 'START_SET',
        payload: {
          id: swimSet.id,
          workoutId: session.id,
          setIndex: 0,
          distance: distance!,
          stroke: (stroke ?? 'Free') as Stroke,
          reps: reps!,
          interval: interval ?? null,
          intensityPattern,
          gear: null,
          paceTargetDistance: parsed.intensity?.paceDistance ?? null,
        },
      })
      router.push('/session/attendance')
    } catch (err) {
      const msg = err instanceof Error ? err.message : JSON.stringify(err)
      Alert.alert('Error', msg)
    } finally {
      setLoading(false)
    }
  }

  return (
    <ScrollView
      style={styles.scroll}
      contentContainerStyle={styles.container}
      keyboardShouldPersistTaps="handled"
    >
      <Text style={styles.screenLabel}>DEFINE SET</Text>

      {/* Natural language input */}
      <TextInput
        style={styles.nlInput}
        value={input}
        onChangeText={setInput}
        placeholder="4 x 50 free on 1:30"
        placeholderTextColor={Colors.dim}
        multiline
        autoFocus
        autoCapitalize="none"
        autoCorrect={false}
      />
      <Text style={styles.inputHint}>Type or tap mic on keyboard to speak</Text>

      {/* Parsed chips */}
      <Text style={styles.sectionLabel}>PARSED</Text>
      <View style={styles.chipRow}>
        <Chip label="REPS"     value={reps     !== null ? String(reps)     : null} onPress={() => openPicker('reps')}     />
        <Chip label="DIST"     value={distance !== null ? `${distance}m`   : null} onPress={() => openPicker('distance')} />
        <Chip label="STROKE"   value={stroke   ?? null}                            onPress={() => openPicker('stroke')}   optional />
        <Chip label="INTERVAL" value={interval ?? null}                            onPress={() => openPicker('interval')} optional />
        {parsed.intensity && (
          <View style={[styles.chip, { borderColor: intensityColor(parsed.intensity.type) }]}>
            <Text style={styles.chipLabel}>EFFORT</Text>
            <Text style={[styles.chipValue, { color: intensityColor(parsed.intensity.type) }]}>
              {parsed.intensity.label}
            </Text>
          </View>
        )}
        {intensityPattern.length > 0 && (
          <View style={[styles.chip, { borderColor: Colors.cyan }]}>
            <Text style={styles.chipLabel}>PATTERN</Text>
            <Text style={[styles.chipValue, { color: Colors.cyan }]}>
              {summarisePattern(intensityPattern)}
            </Text>
          </View>
        )}
      </View>

      {input.length > 0 && !ready && (
        <Text style={styles.warningText}>
          Couldn't detect reps or distance — tap a chip to set manually.
        </Text>
      )}

      <TouchableOpacity
        style={[styles.nextButton, !ready && styles.nextButtonDisabled]}
        onPress={handleNext}
        disabled={!ready || loading}
        activeOpacity={0.85}
      >
        <Text style={styles.nextButtonText}>
          {loading ? 'Saving...' : 'Set Attendance'}
        </Text>
      </TouchableOpacity>

      <PickerModal
        field={pickerField}
        reps={reps}
        distance={distance}
        stroke={stroke}
        intervalDraft={intervalDraft}
        setIntervalDraft={setIntervalDraft}
        onSelect={applyOverride}
        onClose={() => setPickerField(null)}
      />
    </ScrollView>
  )
}

// ─── Chip ─────────────────────────────────────────────────────────────────────

function Chip({ label, value, onPress, optional }: {
  label: string; value: string | null; onPress: () => void; optional?: boolean
}) {
  const detected = value !== null
  return (
    <TouchableOpacity
      style={[styles.chip, detected ? styles.chipDetected : styles.chipMissing]}
      onPress={onPress}
      activeOpacity={0.7}
    >
      <Text style={styles.chipLabel}>{label}</Text>
      <Text style={[styles.chipValue, !detected && styles.chipValueMissing]}>
        {detected ? value : optional ? '—' : '?'}
      </Text>
    </TouchableOpacity>
  )
}

// ─── PickerModal ───────────────────────────────────────────────────────────────

function PickerModal({
  field, reps, distance, stroke,
  intervalDraft, setIntervalDraft, onSelect, onClose,
}: {
  field: PickerField | null; reps: number | null; distance: number | null
  stroke: Stroke | null; intervalDraft: string
  setIntervalDraft: (v: string) => void
  onSelect: (f: PickerField, v: unknown) => void
  onClose: () => void
}) {
  if (!field) return null
  const repOptions = Array.from({ length: 20 }, (_, i) => i + 1)
  const distanceOptions = [15, 25, 50, 75, 100, 150, 200, 300, 400, 500, 800, 1000, 1500]

  return (
    <Modal visible transparent animationType="slide" onRequestClose={onClose}>
      <TouchableOpacity style={styles.modalBackdrop} activeOpacity={1} onPress={onClose} />
      <View style={styles.modalSheet}>
        <View style={styles.modalHandle} />

        {field === 'reps' && (
          <>
            <Text style={styles.modalTitle}>Reps</Text>
            <FlatList
              data={repOptions} keyExtractor={String} numColumns={5}
              renderItem={({ item }) => (
                <TouchableOpacity
                  style={[styles.optionCell, reps === item && styles.optionCellActive]}
                  onPress={() => onSelect('reps', item)}
                >
                  <Text style={[styles.optionText, reps === item && styles.optionTextActive]}>{item}</Text>
                </TouchableOpacity>
              )}
            />
          </>
        )}

        {field === 'distance' && (
          <>
            <Text style={styles.modalTitle}>Distance (m)</Text>
            <FlatList
              data={distanceOptions} keyExtractor={String} numColumns={4}
              renderItem={({ item }) => (
                <TouchableOpacity
                  style={[styles.optionCell, distance === item && styles.optionCellActive]}
                  onPress={() => onSelect('distance', item)}
                >
                  <Text style={[styles.optionText, distance === item && styles.optionTextActive]}>{item}</Text>
                </TouchableOpacity>
              )}
            />
          </>
        )}

        {field === 'stroke' && (
          <>
            <Text style={styles.modalTitle}>Stroke</Text>
            {STROKES.map(s => (
              <TouchableOpacity
                key={s}
                style={[styles.strokeRow, stroke === s && styles.strokeRowActive]}
                onPress={() => onSelect('stroke', s)}
              >
                <Text style={[styles.strokeRowText, stroke === s && styles.strokeRowTextActive]}>{s}</Text>
              </TouchableOpacity>
            ))}
          </>
        )}

        {field === 'interval' && (
          <>
            <Text style={styles.modalTitle}>Interval</Text>
            <Text style={styles.modalHint}>e.g. 1:30</Text>
            <TextInput
              style={styles.intervalInput}
              value={intervalDraft}
              onChangeText={setIntervalDraft}
              placeholder="1:30"
              placeholderTextColor={Colors.dim}
              keyboardType="numbers-and-punctuation"
              autoFocus
            />
            <TouchableOpacity
              style={styles.modalConfirm}
              onPress={() => onSelect('interval', intervalDraft.trim() || null)}
            >
              <Text style={styles.modalConfirmText}>Set Interval</Text>
            </TouchableOpacity>
          </>
        )}
      </View>
    </Modal>
  )
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

  nlInput: {
    backgroundColor: Colors.elevated,
    borderWidth: 1,
    borderColor: Colors.cyan,
    borderRadius: Radius.md,
    padding: Space[4],
    fontSize: FontSize.lg,
    fontFamily: FontFamily.ui,
    color: Colors.text,
    minHeight: 100,
    textAlignVertical: 'top',
    lineHeight: 28,
  },
  inputHint: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.xs,
    color: Colors.dim,
    marginTop: Space[2],
    marginBottom: Space[6],
  },

  sectionLabel: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.xs,
    color: Colors.dim,
    letterSpacing: 1.2,
    marginBottom: Space[3],
  },

  chipRow: { flexDirection: 'row', flexWrap: 'wrap', gap: Space[2] },
  chip: {
    borderRadius: Radius.md,
    paddingHorizontal: Space[3],
    paddingVertical: Space[2],
    minWidth: 72,
    alignItems: 'center',
    borderWidth: 1,
    backgroundColor: Colors.surface,
  },
  chipDetected: { borderColor: Colors.cyan },
  chipMissing:  { borderColor: Colors.border },
  chipLabel: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.xs,
    color: Colors.dim,
    letterSpacing: 0.8,
    marginBottom: 2,
  },
  chipValue: {
    fontFamily: FontFamily.monoMedium,
    fontSize: FontSize.base,
    color: Colors.cyan,
  },
  chipValueMissing: { color: Colors.border },

  warningText: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.sm,
    color: Colors.amber,
    marginTop: Space[3],
    lineHeight: 18,
  },

  nextButton: {
    marginTop: Space[8],
    backgroundColor: Colors.cyan,
    borderRadius: Radius.lg,
    height: TouchTarget.lap,
    alignItems: 'center',
    justifyContent: 'center',
    boxShadow: `0 0 12px ${Colors.cyanGlow}`,
    elevation: 4,
    elevation: 4,
  },
  nextButtonDisabled: { opacity: 0.25 },
  nextButtonText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.lg,
    color: '#000',
    fontWeight: '600',
  },

  // Modal
  modalBackdrop: { flex: 1, backgroundColor: 'rgba(0,0,0,0.6)' },
  modalSheet: {
    backgroundColor: Colors.surface,
    borderTopLeftRadius: 20,
    borderTopRightRadius: 20,
    borderTopWidth: 1,
    borderColor: Colors.border,
    padding: Space[6],
    paddingBottom: Space[12],
    maxHeight: '70%',
  },
  modalHandle: {
    width: 36, height: 4, borderRadius: 2,
    backgroundColor: Colors.border, alignSelf: 'center', marginBottom: Space[4],
  },
  modalTitle: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.lg,
    color: Colors.text,
    marginBottom: Space[1],
  },
  modalHint: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.sm,
    color: Colors.muted,
    marginBottom: Space[3],
  },
  optionCell: {
    flex: 1, margin: 3, paddingVertical: Space[3],
    borderRadius: Radius.md, backgroundColor: Colors.elevated,
    alignItems: 'center',
  },
  optionCellActive: { backgroundColor: Colors.cyan },
  optionText: { fontFamily: FontFamily.monoMedium, fontSize: FontSize.base, color: Colors.text },
  optionTextActive: { color: '#000' },
  strokeRow: {
    padding: Space[4], borderRadius: Radius.md,
    marginBottom: Space[2], backgroundColor: Colors.elevated,
  },
  strokeRowActive: { backgroundColor: Colors.cyan },
  strokeRowText: { fontFamily: FontFamily.uiSemiBold, fontSize: FontSize.base, color: Colors.text },
  strokeRowTextActive: { color: '#000' },
  intervalInput: {
    backgroundColor: Colors.elevated,
    borderWidth: 1, borderColor: Colors.border, borderRadius: Radius.md,
    padding: Space[3], fontSize: 28,
    fontFamily: FontFamily.mono, color: Colors.text,
    textAlign: 'center', marginBottom: Space[4],
  },
  modalConfirm: {
    backgroundColor: Colors.cyan,
    padding: Space[3], borderRadius: Radius.md, alignItems: 'center',
  },
  modalConfirmText: { fontFamily: FontFamily.uiSemiBold, fontSize: FontSize.base, color: '#000' },
})
