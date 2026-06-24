/**
 * OAuth callback handler.
 * Route: /login-callback
 *
 * On iOS/Android: openAuthSessionAsync captures the redirect URL, but the
 * PKCE code (?code=...) in that URL still needs to be exchanged for a session.
 * This screen reads the initial deep link URL (via Linking.getInitialURL())
 * on mount, calls exchangeCodeForSession, then redirects to the app.
 *
 * On web: detectSessionInUrl: true (set in lib/supabase.ts) handles this
 * automatically when the page loads with ?code=... via the PKCE redirect.
 */
import { useEffect, useRef, useState } from 'react'
import { View, Text, StyleSheet, ActivityIndicator, Platform } from 'react-native'
import { useRouter } from 'expo-router'
import * as Linking from 'expo-linking'
import { supabase } from '../lib/supabase'
import { Colors, FontFamily, FontSize, Space } from '../lib/theme'

export default function LoginCallbackScreen() {
  const router = useRouter()
  const [status, setStatus] = useState<'loading' | 'success' | 'error'>('loading')
  const [errorMsg, setErrorMsg] = useState('')
  const processed = useRef(false)

  useEffect(() => {
    if (processed.current) return
    processed.current = true

    async function handleOAuthCallback() {
      // 1. Get the deep link URL that launched (or resumed) the app.
      // On iOS/Android, this is how we receive the ?code=... from the
      // PKCE redirect after the WebBrowser closes.
      let redirectUrl = ''
      if (Platform.OS === 'web') {
        redirectUrl = window.location.href
      } else {
        redirectUrl = (await Linking.getInitialURL()) ?? ''
      }

      console.log('[login-callback] URL:', redirectUrl.slice(0, 120))

      // 2. Check for PKCE code in the URL
      const hasCode = redirectUrl.includes('?code=') || redirectUrl.includes('&code=')
      const hasError = redirectUrl.includes('error=')

      if (hasError) {
        setStatus('error')
        setErrorMsg('Sign-in was cancelled or failed.\n\nPlease try again.')
        setTimeout(() => router.replace('/login'), 3000)
        return
      }

      if (!hasCode) {
        // No code in URL — check if we already have a session.
        // This handles the case where detectSessionInUrl already ran.
        const { data } = await supabase.auth.getSession()
        if (data.session) {
          setStatus('success')
          console.log('[login-callback] Session found — redirecting to /(tabs)/today')
          setTimeout(() => router.replace('/(tabs)/today'), 300)
          return
        }

        // No code, no session — wait and poll for session.
        // This can happen on slow networks or if the WebBrowser URL
        // wasn't captured correctly.
        let attempts = 0
        const maxAttempts = 5
        const poll = async () => {
          attempts++
          const { data: d } = await supabase.auth.getSession()
          if (d.session) {
            setStatus('success')
            setTimeout(() => router.replace('/(tabs)/today'), 300)
            return
          }
          if (attempts < maxAttempts) {
            console.log(`[login-callback] Polling... (${attempts}/${maxAttempts})`)
            setTimeout(poll, 800)
          } else {
            setStatus('error')
            setErrorMsg(
              'Session not found. This may be a PKCE exchange failure.\n\nTry signing in again.'
            )
            setTimeout(() => router.replace('/login'), 3000)
          }
        }
        poll()
        return
      }

      // 3. Exchange PKCE code for session
      console.log('[login-callback] Exchanging PKCE code for session...')
      const { error } = await supabase.auth.exchangeCodeForSession(redirectUrl)

      if (error) {
        console.error('[login-callback] exchangeCodeForSession error:', error)
        setStatus('error')
        setErrorMsg(`Exchange failed: ${error.message}\n\nTry signing in again.`)
        setTimeout(() => router.replace('/login'), 3000)
        return
      }

      const { data } = await supabase.auth.getSession()
      if (data.session) {
        setStatus('success')
        console.log('[login-callback] Session established — redirecting to /(tabs)/today')
        setTimeout(() => router.replace('/(tabs)/today'), 300)
      } else {
        setStatus('error')
        setErrorMsg('Session not created after exchange.\n\nTry signing in again.')
        setTimeout(() => router.replace('/login'), 3000)
      }
    }

    handleOAuthCallback()
  }, [])

  return (
    <View style={styles.container}>
      <ActivityIndicator color={Colors.cyan} size="large" />
      <Text style={styles.text}>
        {status === 'loading' && 'Signing you in...'}
        {status === 'success' && 'Signed in! Redirecting...'}
        {status === 'error' && errorMsg}
      </Text>
    </View>
  )
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: Colors.base,
    alignItems: 'center',
    justifyContent: 'center',
    gap: Space[4],
    padding: Space[6],
  },
  text: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.base,
    color: Colors.muted,
    textAlign: 'center',
    lineHeight: 22,
  },
})
