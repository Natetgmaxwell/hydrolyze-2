import { useState, useEffect } from 'react'
import { View, Text, TouchableOpacity, StyleSheet, FlatList } from 'react-native'
import { useRouter } from 'expo-router'
import { supabase } from '../../lib/supabase'
import { Colors, FontFamily, FontSize, Space, Radius, TouchTarget } from '../../lib/theme'

interface WorkoutDay {
  date: string
  workouts: { id: string; title: string | null; am_pm: string | null }[]
}

function formatDate(dateStr: string): { day: string; month: string; weekday: string } {
  const d = new Date(dateStr + 'T00:00:00')
  return {
    day: d.toLocaleDateString('en-US', { day: 'numeric' }),
    month: d.toLocaleDateString('en-US', { month: 'short' }).toUpperCase(),
    weekday: d.toLocaleDateString('en-US', { weekday: 'short' }).toUpperCase(),
  }
}

function weekStart(date: Date): Date {
  const d = new Date(date)
  d.setDate(d.getDate() - d.getDay())
  d.setHours(0, 0, 0, 0)
  return d
}

function addDays(date: Date, n: number): Date {
  const d = new Date(date)
  d.setDate(d.getDate() + n)
  return d
}

function dateStr(date: Date): string {
  return date.toISOString().slice(0, 10)
}

function isSameDay(a: Date, b: Date): boolean {
  return a.getFullYear() === b.getFullYear() &&
    a.getMonth() === b.getMonth() &&
    a.getDate() === b.getDate()
}

export default function CalendarScreen() {
  const router = useRouter()
  const [weekStartDate, setWeekStartDate] = useState(() => weekStart(new Date()))
  const [workoutDays, setWorkoutDays] = useState<Record<string, { id: string; title: string | null; am_pm: string | null }[]>>({})
  const [loading, setLoading] = useState(false)

  const weekDays = Array.from({ length: 7 }, (_, i) => addDays(weekStartDate, i))

  useEffect(() => {
    setLoading(true)
    const start = dateStr(weekStartDate)
    const end = dateStr(addDays(weekStartDate, 6))
    supabase
      .from('workouts')
      .select('id, title, scheduled_at, am_pm')
      .gte('scheduled_at', start)
      .lte('scheduled_at', end)
      .order('scheduled_at')
      .then(({ data }) => {
        const by: Record<string, { id: string; title: string | null; am_pm: string | null }[]> = {}
        for (const w of data ?? []) {
          const d = (w.scheduled_at as string).slice(0, 10)
          if (!by[d]) by[d] = []
          by[d].push({ id: w.id, title: w.title, am_pm: w.am_pm })
        }
        setWorkoutDays(by)
        setLoading(false)
      })
  }, [weekStartDate])

  function prevWeek() {
    setWeekStartDate(addDays(weekStartDate, -7))
  }

  function nextWeek() {
    setWeekStartDate(addDays(weekStartDate, 7))
  }

  function goToday() {
    setWeekStartDate(weekStart(new Date()))
  }

  const today = new Date()

  return (
    <View style={styles.container}>
      {/* Header */}
      <View style={styles.header}>
        <Text style={styles.screenLabel}>CALENDAR</Text>
        <View style={styles.weekNav}>
          <TouchableOpacity onPress={prevWeek}>
            <Text style={styles.navArrow}>‹</Text>
          </TouchableOpacity>
          <TouchableOpacity onPress={goToday}>
            <Text style={styles.weekLabel}>
              {weekDays[0].toLocaleDateString('en-US', { month: 'short', day: 'numeric' })}
              {' — '}
              {weekDays[6].toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' })}
            </Text>
          </TouchableOpacity>
          <TouchableOpacity onPress={nextWeek}>
            <Text style={styles.navArrow}>›</Text>
          </TouchableOpacity>
        </View>
      </View>

      {/* Week grid */}
      <View style={styles.weekGrid}>
        {weekDays.map(day => {
          const ds = dateStr(day)
          const isToday = isSameDay(day, today)
          const workouts = workoutDays[ds] ?? []
          return (
            <TouchableOpacity
              key={ds}
              style={[styles.dayCol, isToday && styles.dayColToday]}
              activeOpacity={workouts.length === 1 ? 0.7 : 1}
              onPress={() => {
                if (workouts.length === 1) {
                  router.push(`/session/set-picker?workoutId=${workouts[0].id}`)
                }
              }}
            >
              <Text style={[styles.weekday, isToday && styles.weekdayToday]}>
                {day.toLocaleDateString('en-US', { weekday: 'short' }).toUpperCase()}
              </Text>
              <Text style={[styles.dayNum, isToday && styles.dayNumToday]}>
                {day.getDate()}
              </Text>
              {workouts.length > 0 ? (
                <View style={styles.dots}>
                  {workouts.map(w => (
                    <View key={w.id} style={[styles.dot, w.am_pm === 'PM' ? styles.dotPm : styles.dotAm]} />
                  ))}
                </View>
              ) : (
                <View style={styles.dots} />
              )}
            </TouchableOpacity>
          )
        })}
      </View>

      {/* Workout list for this week */}
      <FlatList
        data={weekDays}
        keyExtractor={d => dateStr(d)}
        style={styles.list}
        contentContainerStyle={styles.listContent}
        renderItem={({ item: day }) => {
          const ds = dateStr(day)
          const workouts = workoutDays[ds] ?? []
          if (workouts.length === 0) return null
          return (
            <View style={styles.daySection}>
              <Text style={styles.dayLabel}>
                {day.toLocaleDateString('en-US', { weekday: 'long', month: 'long', day: 'numeric' })}
              </Text>
              {workouts.map(w => (
                <TouchableOpacity
                  key={w.id}
                  style={styles.workoutCard}
                  activeOpacity={0.7}
                  onPress={() => router.push(`/session/set-picker?workoutId=${w.id}`)}
                >
                  <View style={styles.cardLeft}>
                    <Text style={styles.cardTime}>{w.am_pm ?? 'AM'}</Text>
                  </View>
                  <View style={styles.cardBody}>
                    <Text style={styles.cardTitle}>{w.title ?? 'Workout'}</Text>
                    <Text style={styles.cardSub}>{w.am_pm === 'PM' ? 'Afternoon' : 'Morning'} session</Text>
                  </View>
                  <Text style={styles.cardChevron}>›</Text>
                </TouchableOpacity>
              ))}
            </View>
          )
        }}
        ListEmptyComponent={
          <View style={styles.empty}>
            <Text style={styles.emptyText}>No workouts this week</Text>
            <TouchableOpacity
              style={styles.createButton}
              onPress={() => router.push('/workout/new')}
              activeOpacity={0.85}
            >
              <Text style={styles.createButtonText}>Create a workout</Text>
            </TouchableOpacity>
          </View>
        }
      />
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
    marginBottom: Space[2],
  },
  weekNav: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  navArrow: {
    fontFamily: FontFamily.ui,
    fontSize: 24,
    color: Colors.cyan,
    width: 44,
  },
  weekLabel: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.base,
    color: Colors.text,
  },

  weekGrid: {
    flexDirection: 'row',
    borderBottomWidth: 1,
    borderBottomColor: Colors.border,
  },
  dayCol: {
    flex: 1,
    alignItems: 'center',
    paddingVertical: Space[3],
    borderRightWidth: 1,
    borderRightColor: Colors.border,
  },
  dayColToday: { backgroundColor: Colors.cyanDim },
  weekday: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.xs,
    color: Colors.dim,
    marginBottom: 2,
  },
  weekdayToday: { color: Colors.cyan },
  dayNum: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.lg,
    color: Colors.muted,
    marginBottom: 4,
  },
  dayNumToday: { color: Colors.cyan },
  dots: {
    flexDirection: 'row',
    gap: 3,
    alignItems: 'center',
    height: 8,
  },
  dot: { width: 6, height: 6, borderRadius: 3 },
  dotAm: { backgroundColor: Colors.cyan },
  dotPm: { backgroundColor: Colors.amber },

  list: { flex: 1 },
  listContent: { paddingBottom: Space[8] },

  daySection: { paddingTop: Space[4] },
  dayLabel: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.sm,
    color: Colors.muted,
    paddingHorizontal: Space[6],
    marginBottom: Space[2],
  },

  workoutCard: {
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: Colors.surface,
    marginHorizontal: Space[4],
    marginBottom: Space[2],
    borderRadius: Radius.md,
    borderWidth: 1,
    borderColor: Colors.border,
    overflow: 'hidden',
  },
  cardLeft: {
    backgroundColor: Colors.elevated,
    paddingHorizontal: Space[3],
    paddingVertical: Space[4],
    borderRightWidth: 1,
    borderRightColor: Colors.border,
  },
  cardTime: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.xs,
    color: Colors.amber,
  },
  cardBody: { flex: 1, paddingHorizontal: Space[4], paddingVertical: Space[3] },
  cardTitle: { fontFamily: FontFamily.uiMedium, fontSize: FontSize.base, color: Colors.text },
  cardSub: { fontFamily: FontFamily.ui, fontSize: FontSize.xs, color: Colors.dim, marginTop: 2 },
  cardChevron: { fontFamily: FontFamily.ui, fontSize: 20, color: Colors.border, paddingRight: Space[4] },

  empty: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    gap: Space[3],
    paddingTop: Space[12],
  },
  emptyText: { fontFamily: FontFamily.ui, fontSize: FontSize.base, color: Colors.dim },
  createButton: {
    backgroundColor: Colors.cyan,
    borderRadius: Radius.lg,
    paddingHorizontal: Space[6],
    paddingVertical: Space[3],
  },
  createButtonText: { fontFamily: FontFamily.uiSemiBold, fontSize: FontSize.base, color: '#000' },
})