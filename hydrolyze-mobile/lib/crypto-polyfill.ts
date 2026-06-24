import * as Crypto from 'expo-crypto'

/**
 * Robust WebCrypto Polyfill for Supabase PKCE.
 * 
 * Uses the most compatible Expo Crypto methods to provide 
 * global.crypto.subtle.digest and global.crypto.getRandomValues.
 */

if (typeof global.crypto === 'undefined') {
  // @ts-ignore
  global.crypto = {}
}

if (!global.crypto.getRandomValues) {
  // @ts-ignore
  global.crypto.getRandomValues = (array: Uint8Array) => {
    return Crypto.getRandomValues(array)
  }
}

if (!global.crypto.subtle) {
  // @ts-ignore
  global.crypto.subtle = {
    digest: async (algorithm: string, data: Uint8Array) => {
      if (algorithm !== 'SHA-256') throw new Error('Only SHA-256 supported')
      
      // Use digestAsync as it has the widest compatibility across Expo versions.
      // We explicitly request ArrayBuffer to match the WebCrypto spec.
      const result = await Crypto.digestAsync(
        Crypto.CryptoDigestAlgorithm.SHA256, 
        data
      )
      
      // Some versions of Expo return a hex string, others an ArrayBuffer.
      // We ensure we return an ArrayBuffer.
      if (typeof result === 'string') {
        const bytes = new Uint8Array(result.match(/.{1,2}/g)!.map(byte => parseInt(byte, 16)))
        return bytes.buffer
      }
      
      return result as ArrayBuffer
    },
  }
}
