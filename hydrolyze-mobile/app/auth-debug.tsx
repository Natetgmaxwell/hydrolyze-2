/**
 * Auth debug screen — shows exactly what auth state exists after login.
 *
 * Navigate to /auth-debug in the browser after signing in.
 * All diagnostics are printed BOTH to screen (no console needed) and to console.
 */
import React, { useEffect, useState } from 'react'
import { Text, View, StyleSheet, ScrollView, TouchableOpacity } from 'react-native'
import { supabase } from '../lib/supabase'
import { getOrCreateCoach } from '../lib/auth'
import type { User } from '@supabase/supabase-js'

export default function AuthDebug() {
  const [lines, setLines] = useState<string[]>(['Loading...'])

  useEffect(() => {
    async function run() {
      const out: string[] = []

      function log(msg: string) {
        out.push(msg)
        console.log('[auth-debug]', msg)
      }

      // 1. localStorage keys
      log('=== Step 1: localStorage keys ===')
      if (typeof window !== 'undefined') {
        const keys = (Object.keys(localStorage) || []).filter(
          k => k.includes('supabase') || k.includes('SB')
        )
        log(`Found ${keys.length} supabase-related keys:`)
        for (const k of keys) {
          try {
            const v = localStorage.getItem(k) ?? 'null'
            log(`  ${k}: ${v.slice(0, 150)}`)
          } catch {
            log(`  ${k}: (error reading)`)
          }
        }
      } else {
        log('  window not available')
      }

      // 2. Supabase getSession
      log('\n=== Step 2: getSession() ===')
      const { data: sessionData, error: sessionErr } = await supabase.auth.getSession()
      if (sessionErr) {
        log(`ERROR: ${sessionErr.message}`)
      } else if (sessionData?.session) {
        log(`SESSION EXISTS ✓`)
        log(`  user.id: ${sessionData.session.user?.id}`)
        log(`  user.email: ${sessionData.session.user?.email}`)
        log(`  access_token: ${sessionData.session.access_token?.slice(0, 30)}...`)
      } else {
        log(`SESSION IS NULL ✗ — PKCE exchange likely failed`)
      }

      // 3. Try getOrCreateCoach
      log('\n=== Step 3: getOrCreateCoach() ===')
      if (sessionData?.session?.user) {
        const coach = await getOrCreateCoach(sessionData.session.user as User)
        if (coach) {
          log(`COACH RECORD: id=${coach.id}, name=${coach.name}`)
        } else {
          log(`COACH RECORD: NOT CREATED ✗`)
          log(`  This means the swimmers INSERT will fail with 403!`)
        }
      } else {
        log(`SKIPPED — no user in session`)
      }

      // 4. Try swimmers INSERT
      log('\n=== Step 4: swimmers INSERT ===')
      const insertRes = await supabase
        .from('swimmers')
        .insert({ name: 'DEBUG swimmer' })
        .select('id')
        .single()
      if (insertRes.error) {
        log(`ERROR ✗: ${insertRes.error.code} — ${insertRes.error.message}`)
        if (insertRes.error.code === '42501') {
          log(`  → RLS policy denied. auth.uid() is likely NULL in Supabase.`)
          log(`  → The coach record (coaches.auth_id = auth.uid()) may not exist.`)
        }
      } else {
        log(`SUCCESS ✓ — swimmer id=${insertRes.data?.id}`)
        log(`Cleaning up test swimmer...`)
        if (insertRes.data?.id) {
          await supabase.from('swimmers').delete().eq('id', insertRes.data.id)
          log(`  Deleted.`)
        }
      }

      setLines(out)
    }

    run()
  }, [])

  return (
    <ScrollView style={styles.container} contentContainerStyle={styles.content}>
      <Text style={styles.title}>Auth Debug</Text>
      <Text style={styles.subtitle}>After signing in, visit this page.</Text>

      <View style={styles.output}>
        {lines.map((line, i) => (
          <Text key={i} style={line.startsWith('===') ? styles.section : line.startsWith('  ') ? styles.sub : styles.line}>
            {line}
          </Text>
        ))}
      </View>

      <TouchableOpacity
        style={styles.retry}
        onPress={() => typeof location !== 'undefined' && location.reload()}
      >
        <Text style={styles.retryText}>Retry</Text>
      </TouchableOpacity>
    </ScrollView>
  )
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#060e18' },
  content: { padding: 16, paddingBottom: 48 },
  title: { color: '#00e5c8', fontFamily: 'monospace', fontSize: 20, fontWeight: '700', marginBottom: 4 },
  subtitle: { color: '#4a6572', fontFamily: 'monospace', fontSize: 12, marginBottom: 16 },
  output: { backgroundColor: '#0d1a26', borderRadius: 8, padding: 12, borderWidth: 1, borderColor: '#1a2d3d' },
  section: { color: '#00e5c8', fontFamily: 'monospace', fontSize: 11, fontWeight: '600', marginTop: 12, marginBottom: 4 },
  line: { color: '#e0e0e0', fontFamily: 'monospace', fontSize: 11, marginBottom: 2 },
  sub: { color: '#7fbfff', fontFamily: 'monospace', fontSize: 10, marginLeft: 12, marginBottom: 1 },
  retry: { marginTop: 20, backgroundColor: '#00e5c8', borderRadius: 8, padding: 14, alignItems: 'center' },
  retryText: { color: '#000', fontFamily: 'monospace', fontSize: 14, fontWeight: '700' },
})
