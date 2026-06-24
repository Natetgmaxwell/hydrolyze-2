import { useState, useEffect, useCallback } from 'react'
import { View, Text, FlatList, TouchableOpacity, StyleSheet } from 'react-native'
import { useRouter, useFocusEffect } from 'expo-router'
import { supabase } from '../../lib/supabase'
import { Colors, FontFamily, FontSize, Space, Radius, TouchTarget } from '../../lib/theme'

interface SwimmerRow {
  id: string
  name: string
  pb_count: number
}

export default function RosterScreen() {
  const router = useRouter()
  const [swimmers, setSwimmers] = useState<SwimmerRow[]>([])
  const [loading, setLoading] = useState(true)

  async function load() {
    setLoading(true)
    const { data: swimmerData } = await supabase
      .from('swimmers')
      .select('id, name')
      .order('name')

    const { data: pbData } = await supabase
      .from('swimmer_pbs')
      .select('swimmer_id')

    const pbCounts: Record<string, number> = {}
    for (const row of pbData ?? []) {
      pbCounts[row.swimmer_id] = (pbCounts[row.swimmer_id] ?? 0) + 1
    }

    setSwimmers(
      (swimmerData ?? []).map(s => ({
        id: s.id,
        name: s.name,
        pb_count: pbCounts[s.id] ?? 0,
      }))
    )
    setLoading(false)
  }

  // Reload every time we return to this screen (after editing a swimmer's PBs)
  useFocusEffect(useCallback(() => { load() }, []))

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <Text style={styles.screenLabel}>ROSTER</Text>
        <Text style={styles.hint}>Tap a swimmer to manage their personal bests</Text>
      </View>

      {!loading && swimmers.length === 0 && (
        <View style={styles.empty}>
          <Text style={styles.emptyText}>No swimmers found.</Text>
          <Text style={styles.emptyHint}>Add swimmers in your Supabase dashboard.</Text>
        </View>
      )}

      <FlatList
        data={swimmers}
        keyExtractor={s => s.id}
        style={styles.list}
        renderItem={({ item }) => (
          <TouchableOpacity
            style={styles.row}
            onPress={() => router.push(`/roster/${item.id}`)}
            activeOpacity={0.7}
          >
            <Text style={styles.name}>{item.name}</Text>
            <View style={styles.right}>
              <Text style={styles.pbCount}>
                {item.pb_count > 0 ? `${item.pb_count} PB${item.pb_count > 1 ? 's' : ''}` : 'No PBs'}
              </Text>
              <Text style={styles.chevron}>›</Text>
            </View>
          </TouchableOpacity>
        )}
        ItemSeparatorComponent={() => <View style={styles.separator} />}
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
    marginBottom: Space[1],
  },
  hint: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.sm,
    color: Colors.muted,
  },

  list: { flex: 1 },

  row: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    height: TouchTarget.swimRow,
    paddingHorizontal: Space[6],
  },
  name: {
    fontFamily: FontFamily.uiMedium,
    fontSize: FontSize.base,
    color: Colors.text,
  },
  right: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: Space[3],
  },
  pbCount: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.sm,
    color: Colors.dim,
  },
  chevron: {
    fontFamily: FontFamily.ui,
    fontSize: 20,
    color: Colors.border,
  },

  separator: {
    height: 1,
    backgroundColor: Colors.border,
    marginHorizontal: Space[6],
  },

  empty: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
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
})
