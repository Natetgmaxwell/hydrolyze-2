/**
 * React Native Web Fetch Polyfill
 * 
 * Fixes 406 "Not Acceptable" errors from Supabase by ensuring
 * fetch requests include the proper Accept header.
 * 
 * Import this early in the app lifecycle (e.g., in _layout.tsx).
 */

// Only apply in web environment
if (typeof window !== 'undefined' && 'fetch' in window) {
  const originalFetch = window.fetch

  // @ts-ignore - extending global fetch
  window.fetch = function(input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
    const headers = new Headers(init?.headers)
    
    // Ensure Accept header is set for Supabase API calls
    if (!headers.has('Accept')) {
      headers.set('Accept', 'application/json')
    }
    
    // Ensure Content-Type is set for POST/PUT/PATCH requests
    if (['POST', 'PUT', 'PATCH'].includes((init?.method || '').toUpperCase()) && !headers.has('Content-Type')) {
      headers.set('Content-Type', 'application/json')
    }

    return originalFetch(input, {
      ...init,
      headers,
    })
  }
}

export {}
