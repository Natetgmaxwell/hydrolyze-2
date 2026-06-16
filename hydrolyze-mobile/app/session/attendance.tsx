import { useState, useEffect } from 'react'
import { View, Text, FlatList, TouchableOpacity, StyleSheet, Alert, Platform, ActivityIndicator } from 'react-native'
import { useRouter, useLocalSearchParams } from 'expo-router'
import { supabase } from '../../lib/supabase'
import { useWorkout } from '../../context/WorkoutContext'
import type { Workout, WorkoutSetDefinition } from '../../context/WorkoutContext'
import { useAuth } from '../../context/AuthContext'
import { Colors, FontFamily, FontSize, Space, Radius, TouchTarget } from '../../lib/theme'
import type { Swimmer, StatsCache, Stroke, AssignmentSource } from '../../lib/ml-pairing'
import { predictFromPBs } from '../../lib/speed-curve'
import type { CurveSource } from '../../lib/speed-curve'
import type { IntensityLevel } from '../../lib/set-parser'
import type { GearType } from '../../lib/workout-parser'

// The database may store full stroke names from older schema versions.
const STROKE_ALIAS: Record<string, Stroke> = {
  Freestyle:          'Free',
  Backstroke:         'Back',
  Breaststroke:       'Breast',
  Butterfly:          'Fly',
  'Individual Medley':'IM',
  Free: 'Free', Back: 'Back', Breast: 'Breast',
  Fly: 'Fly', IM: 'IM', Form: 'Form',
}

function normalizeStroke(raw: string): Stroke {
  return STROKE_ALIAS[raw] ?? (raw as Stroke)
}

function curveSourceToAssignment(cs: CurveSource): AssignmentSource {
  // Map CurveSource (curve fitting classification) → new AssignmentSource
  // 'exact' = PB at this exact distance → layer 2 curve (source='curve')
  // 'interpolated' = between two PBs → layer 2 curve
  // 'extrapolated' = extrapolated from one PB → layer 2 curve (less reliable but still computed)
  if (cs === 'exact') return 'curve'
  if (cs === 'interpolated') return 'curve'
  return 'curve' // extrapolated → still curve, not seed
}

const TRAINING_STDDEV_FACTOR = 0.10

/**
 * Fetch stats cache for a list of swimmers.
 * Returns a StatsCache with 5D keys: `${swimmerId}:${stroke}:${distance}:${intensity}:${gear}`
 */
async function fetchStatsCache(
  swimmerIds: string[],
  setDistance: number,
  stroke: Stroke,
  gear: GearType | null,
): Promise<StatsCache> {
  const gearKey = gear && gear.length > 0 ? [...gear].sort().join(',') : 'none'

  const [statsResult, pbResult, calibResult] = await Promise.all([
    supabase
      .from('swimmer_stats')
      .select('swimmer_id, stroke, mean_time_ms, stddev_time_ms, sample_count, set_id')
      .in('swimmer_id', swimmerIds),
    supabase
      .from('swimmer_pbs')
      .select('swimmer_id, stroke, distance, time_ms')
      .in('swimmer_id', swimmerIds),
    supabase
      .from('swimmer_intensity_calibrations')
      .select('swimmer_id, stroke, intensity, gear, multiplier_mean, sample_count')
      .in('swimmer_id', swimmerIds),
  ])

  // Per-swimmer intensity calibrations: key = swimmerId:stroke:intensity:gear
  const intensityCalibs = new Map<string, number>()
  for (const row of calibResult.data ?? []) {
    if (row.sample_count < 3) continue
    // Normalize gear string from DB (ensure sorting if multiple)
    const dbGearStr = row.gear && row.gear !== 'none' 
      ? row.gear.split(',').sort().join(',') 
      : 'none'
    const key = `${row.swimmer_id}:${normalizeStroke(row.stroke)}:${row.intensity}:${dbGearStr}`
    intensityCalibs.set(key, row.multiplier_mean)
  }

  const cache: StatsCache = {}

  // Priority 1: real recorded training stats
  for (const row of statsResult.data ?? []) {
    const strokeKey = normalizeStroke(row.stroke)
    // For now, recorded training stats in swimmer_stats don't have multi-gear support in schema,
    // so we just match against 'none' or the primary gear.
    // TODO: Phase 3 swimmer_stats gear column.
    const key = statsCacheKey(row.swimmer_id, strokeKey, row.set_id ?? setDistance, 'moderate', gear)
    const calibKey = `${row.swimmer_id}:${strokeKey}:moderate:${gearKey}`
    
    cache[key] = {
      mean_time_ms: row.mean_time_ms,
      stddev_time_ms: row.stddev_time_ms,
      sample_count: row.sample_count,
      is_estimated: false,
      assignmentSource: 'recorded',
      intensityMultipliers: intensityCalibs.has(calibKey)
        ? { moderate: intensityCalibs.get(calibKey)! }
        : undefined,
    }
  }

  // Priority 2: speed-curve prediction for gaps
  const pbGroups = new Map<string, { distance: number; pb_ms: number }[]>()
  for (const pb of pbResult.data ?? []) {
    const strokeKey = normalizeStroke(pb.stroke)
    const key = `${pb.swimmer_id}:${strokeKey}`
    if (!pbGroups.has(key)) pbGroups.set(key, [])
    pbGroups.get(key)!.push({ distance: pb.distance, pb_ms: pb.time_ms })
  }

  for (const [swimmerStrokeKey, pbs] of pbGroups) {
    const fullKey = statsCacheKey(
      swimmerStrokeKey.split(':')[0],
      swimmerStrokeKey.split(':')[1] as Stroke,
      setDistance,
      'moderate',
      gear
    )
    
    const existing = cache[fullKey]
    if (existing && existing.sample_count >= 5) continue

    const prediction = predictFromPBs(pbs, setDistance)
    if (!prediction) continue

    const { predicted_time_ms, curveSource } = prediction
    const mean = Math.round(predicted_time_ms * 1.10)
    const stddev = Math.round(predicted_time_ms * TRAINING_STDDEV_FACTOR)
    const calibKey = `${swimmerStrokeKey}:moderate:${gearKey}`

    cache[fullKey] = {
      mean_time_ms: mean,
      stddev_time_ms: stddev,
      sample_count: existing?.sample_count ?? 0,
      is_estimated: true,
      assignmentSource: curveSourceToAssignment(curveSource),
      pb_predicted_ms: Math.round(predicted_time_ms),
      intensityMultipliers: intensityCalibs.has(calibKey)
        ? { moderate: intensityCalibs.get(calibKey)! }
        : undefined,
    }
  }

  return cache
}

import { statsCacheKey } from '../../lib/workout-parser'

export default function AttendanceScreen() {
  const router = useRouter()
  const { state, dispatch } = useWorkout()
  const { coachId } = useAuth()
  const { workoutId, setId, auto } = useLocalSearchParams<{ workoutId?: string; setId?: string; auto?: string }>()
  const currentSet = state.currentSet

  const [swimmers, setSwimmers] = useState<Swimmer[]>([])
  const [selected, setSelected] = useState<Set<string>>(new Set())
  const [loading, setLoading] = useState(false)
  const [swimmersLoading, setSwimmersLoading] = useState(true)
  const [bootstrapping, setBootstrapping] = useState(false)
  const [initializedAttendance, setInitializedAttendance] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [statusMsg, setStatusMsg] = useState('Initializing...')

  // Pre-populate selection from existing attendance
  useEffect(() => {
    if (!initializedAttendance && state.attendanceList.length > 0) {
      console.log('[Attendance] Initializing from existing attendance list:', state.attendanceList.length)
      setSelected(new Set(state.attendanceList.map(s => s.id)))
      setInitializedAttendance(true)
    }
  }, [state.attendanceList, initializedAttendance])

  // Handle auto-start if requested and attendance is known
  useEffect(() => {
    if (auto === 'true' && !bootstrapping && currentSet && state.attendanceList.length > 0 && !loading) {
      console.log('[Attendance] Auto-starting timing for next set...')
      handleStartTiming(new Set(state.attendanceList.map(s => s.id)))
    }
  }, [auto, bootstrapping, !!currentSet])

  useEffect(() => {
    if (!coachId) {
      console.log('[Attendance] coachId missing')
      setStatusMsg('Waiting for auth...')
      const timer = setTimeout(() => {
        if (!coachId) setError('Authentication timeout. Are you signed in?')
      }, 5000)
      return () => clearTimeout(timer)
    }

    console.log('[Attendance] Fetching swimmers for coachId:', coachId)
    setStatusMsg('Loading swimmers...')
    setSwimmersLoading(true)
    supabase
      .from('swimmers')
      .select('id, name, form_stroke')
      .order('name')
      .then(({ data, error: swimmersErr }) => {
        if (swimmersErr) {
          console.error('[Attendance] Swimmers fetch error:', swimmersErr)
          setError(`Database error: ${swimmersErr.message}`)
        } else {
          console.log('[Attendance] Swimmers fetched:', data?.length ?? 0)
          setSwimmers(data ?? [])
        }
        setSwimmersLoading(false)
      })
      .catch(err => {
        console.error('[Attendance] Swimmers catch error:', err)
        setError(`Unexpected error fetching swimmers: ${String(err)}`)
        setSwimmersLoading(false)
      })
  }, [coachId])

  // Bootstrap workout context from URL params when entered from set-picker / workout detail.
  // Without this, currentSet stays null and the start button is disabled.
  useEffect(() => {
    if (!workoutId || !coachId) {
      console.log('[Attendance] Skipping bootstrap: workoutId or coachId missing', { workoutId, coachId })
      return
    }
    
    // If already bootstrapped to this workout and set, stop.
    // If setId is missing, we're happy if any set from this workout is selected.
    const isAlreadyMatched = state.workout?.id === workoutId && (
      setId ? state.currentSet?.id === setId : state.currentSet !== null
    )

    if (isAlreadyMatched) {
      console.log('[Attendance] Already bootstrapped to this workout/set')
      setBootstrapping(false)
      return
    }

    // Optimization: If the workout is already loaded but we just need to select a different set,
    // don't do a full bootstrap (which is destructive to attendance list).
    if (state.workout?.id === workoutId) {
      const sets = state.workout.sets
      const targetIndex = setId
        ? sets.findIndex(s => s.id === setId)
        : sets.findIndex(s => !s.isCompleted)

      if (targetIndex >= 0) {
        console.log('[Attendance] Workout matched, just selecting set index:', targetIndex)
        dispatch({ type: 'SELECT_SET', payload: { setIndex: targetIndex } })
        setBootstrapping(false)
        return
      }
    }

    console.log('[Attendance] Bootstrapping workout:', workoutId, 'setId:', setId)
    let cancelled = false
    setBootstrapping(true)
    setStatusMsg('Loading workout data...')

    ;(async () => {
      try {
        console.log('[Attendance] Running bootstrap queries...')
        const [{ data: w, error: wErr }, { data: setRows, error: sErr }, { data: timesData }] = await Promise.all([
          supabase.from('workouts').select('id, title').eq('id', workoutId).single(),
          supabase
            .from('workout_sets')
            .select('id, order_index, reps, distance, stroke, interval_text, intensity_label, gear, pace_target_distance')
            .eq('workout_id', workoutId)
            .order('order_index'),
          supabase
            .from('recorded_times')
            .select('workout_set_id')
            .eq('workout_id', workoutId),
        ])
        
        if (cancelled) return

        if (wErr || sErr) {
          console.error('[Attendance] Bootstrap query error:', wErr || sErr)
          setError(`Failed to load workout: ${(wErr || sErr)?.message}`)
          return
        }

        if (!w) {
          setError('Workout not found in database.')
          return
        }

        const completedSetIds = new Set((timesData ?? []).map(t => t.workout_set_id))

        const sets: WorkoutSetDefinition[] = (setRows ?? []).map(r => ({
          id: r.id,
          orderIndex: r.order_index,
          reps: r.reps ?? null,
          distance: r.distance ?? null,
          stroke: (r.stroke ?? 'Free') as Stroke,
          interval: r.interval_text ?? null,
          intensityLabel: r.intensity_label ?? null,
          gear: (r.gear ?? null) as GearType,
          paceTargetDistance: r.pace_target_distance ?? null,
          isCompleted: completedSetIds.has(r.id),
        }))

        const workout: Workout = {
          id: w.id,
          coachId,
          title: w.title,
          sets,
          currentSetIndex: null,
          isComplete: false,
        }
        
        console.log('[Attendance] Dispatching START_WORKOUT')
        dispatch({ type: 'START_WORKOUT', payload: workout })

        const targetIndex = setId
          ? sets.findIndex(s => s.id === setId)
          : sets.findIndex(s => !s.isCompleted)
        
        if (targetIndex >= 0) {
          console.log('[Attendance] Dispatching SELECT_SET for index:', targetIndex)
          dispatch({ type: 'SELECT_SET', payload: { setIndex: targetIndex } })
        } else if (setId) {
          setError(`Set ${setId} not found in this workout.`)
        }
      } catch (err) {
        console.error('[Attendance] Bootstrap catch error:', err)
        if (!cancelled) setError(`Critical bootstrap error: ${String(err)}`)
      } finally {
        if (!cancelled) {
          console.log('[Attendance] Bootstrap finished')
          setBootstrapping(false)
        }
      }
    })()

    return () => { cancelled = true }
  }, [workoutId, setId, coachId, state.workout?.id, state.currentSet?.id, dispatch])

  function toggleSwimmer(id: string) {
    setSelected(prev => {
      const next = new Set(prev)
      next.has(id) ? next.delete(id) : next.add(id)
      return next
    })
  }

  async function handleStartTiming(overrideSelected?: Set<string>) {
    const selection = overrideSelected || selected
    if (selection.size === 0 || !currentSet) return
    
    setLoading(true)
    setStatusMsg('Fetching set stats...')
    try {
      // Use override selection or state selection
      const swimmersToUse = swimmers.length > 0 
        ? swimmers.filter(s => selection.has(s.id))
        : state.attendanceList.filter(s => selection.has(s.id))

      if (swimmersToUse.length === 0) {
        throw new Error('No swimmers selected.')
      }

      console.log('[Attendance] Fetching stats for', swimmersToUse.length, 'swimmers')
      const statsCache = await fetchStatsCache(
        swimmersToUse.map(s => s.id),
        currentSet.paceTargetDistance ?? currentSet.distance,
        currentSet.stroke,
        currentSet.gear,
      )
      
      dispatch({ type: 'SET_ATTENDANCE', payload: { swimmers: swimmersToUse, statsCache } })
      
      console.log('[Attendance] Stats ready, navigating to timing')
      router.push('/session/timing')
    } catch (err) {
      const msg = err instanceof Error ? err.message : JSON.stringify(err)
      if (Platform.OS === 'web') {
        window.alert(`Error starting session: ${msg}`)
      } else {
        Alert.alert('Error starting session', msg)
      }
    } finally {
      setLoading(false)
    }
  }

  const setDesc = currentSet
    ? `${currentSet.reps} × ${currentSet.distance}m ${currentSet.stroke}${currentSet.gear ? ' · ' + currentSet.gear : ''}`
    : bootstrapping ? 'Loading set…' : 'Select a set to start timing'

  if (error) {
    return (
      <View style={[styles.container, styles.center]}>
        <Text style={styles.errorText}>Error: {error}</Text>
        <TouchableOpacity style={styles.backButton} onPress={() => router.back()}>
          <Text style={styles.backButtonText}>Go Back</Text>
        </TouchableOpacity>
      </View>
    )
  }

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <Text style={styles.screenLabel}>ATTENDANCE</Text>
        <Text style={styles.setDesc}>{setDesc}</Text>
      </View>

      {swimmersLoading || bootstrapping ? (
        <View style={styles.center}>
          <ActivityIndicator color={Colors.cyan} />
          <Text style={styles.loadingText}>{statusMsg}</Text>
        </View>
      ) : (
        <FlatList
          data={swimmers}
          keyExtractor={s => s.id}
          style={styles.list}
          ListEmptyComponent={
            <View style={styles.center}>
              <Text style={styles.emptyText}>No swimmers found.</Text>
            </View>
          }
          renderItem={({ item }) => {
            const active = selected.has(item.id)
            return (
              <TouchableOpacity
                style={[styles.swimmerRow, active && styles.swimmerRowSelected]}
                onPress={() => toggleSwimmer(item.id)}
                activeOpacity={0.7}
              >
                <Text style={[styles.swimmerName, active && styles.swimmerNameActive]}>
                  {item.name}
                </Text>
                {active && <View style={styles.selectedDot} />}
              </TouchableOpacity>
            )
          }}
          ItemSeparatorComponent={() => <View style={styles.separator} />}
        />
      )}

      <View style={styles.footer}>
        <TouchableOpacity
          style={[styles.startButton, (selected.size === 0 || loading || !currentSet) && styles.startButtonDisabled]}
          onPress={() => handleStartTiming()}
          disabled={selected.size === 0 || loading || !currentSet}
          activeOpacity={0.85}
        >
          <Text style={styles.startButtonText}>
            {loading ? 'Loading...' : `Start Timing  ${selected.size > 0 ? `(${selected.size})` : ''}`}
          </Text>
        </TouchableOpacity>
      </View>
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
  setDesc: {
    fontFamily: FontFamily.monoMedium,
    fontSize: FontSize.base,
    color: Colors.muted,
  },

  list: { flex: 1 },

  swimmerRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    height: TouchTarget.swimRow,
    paddingHorizontal: Space[6],
    backgroundColor: Colors.base,
  },
  swimmerRowSelected: {
    backgroundColor: Colors.cyanDim,
  },
  swimmerName: {
    fontFamily: FontFamily.uiMedium,
    fontSize: FontSize.base,
    color: Colors.muted,
  },
  swimmerNameActive: {
    color: Colors.text,
  },
  selectedDot: {
    width: 8, height: 8,
    borderRadius: 4,
    backgroundColor: Colors.cyan,
  },
  separator: {
    height: 1,
    backgroundColor: Colors.border,
    marginHorizontal: Space[6],
  },

  footer: {
    padding: Space[4],
    borderTopWidth: 1,
    borderTopColor: Colors.border,
  },
  startButton: {
    backgroundColor: Colors.cyan,
    borderRadius: Radius.lg,
    height: TouchTarget.lap,
    alignItems: 'center',
    justifyContent: 'center',
    boxShadow: `0 0 12px ${Colors.cyanGlow}`,
    elevation: 4,
    elevation: 4,
  },
  startButtonDisabled: { opacity: 0.25 },
  startButtonText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.lg,
    color: '#000',
    fontWeight: '600',
  },
  loadingText: { marginTop: Space[4], color: Colors.muted, fontFamily: FontFamily.ui },
  emptyText: { color: Colors.dim, fontFamily: FontFamily.ui },
  errorText: { color: Colors.danger, fontFamily: FontFamily.ui, marginBottom: Space[4], paddingHorizontal: Space[6], textAlign: 'center' },
  backButton: { backgroundColor: Colors.elevated, paddingHorizontal: Space[6], paddingVertical: Space[3], borderRadius: Radius.md, borderWidth: 1, borderColor: Colors.border },
  backButtonText: { color: Colors.text, fontFamily: FontFamily.uiSemiBold },
})