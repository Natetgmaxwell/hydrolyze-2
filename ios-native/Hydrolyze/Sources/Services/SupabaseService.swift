import Foundation
import Supabase

/// Supabase client singleton — initialized once at app launch.
/// Credentials are hardcoded (see constants below). PKCE auth callback
/// URL: hydrolyze://login-callback
final class SupabaseService {
    static let shared = SupabaseService()

    // Copy of RN app credentials — REPLACE with real keys before shipping.
    private let supabaseURL = URL(string: "https://flidjtldfvrrntzwtnsq.supabase.co/")!
    private let anonKey = "eyJhbG...RldE"

    /// Supabase client — thread-safe singleton.
    /// Auth uses PKCE flow (same as RN app). Sessions persist in the iOS Keychain by default.
    let client: SupabaseClient

    private init() {
        let authOptions = SupabaseClientOptions.AuthOptions(
            flowType: .pkce,
            // ponytail: opt-in to the new session behavior (supabase-swift PR #822/#844).
            // The locally stored session is always emitted, even if expired.
            // AuthManager.checkSession() handles the expiry check.
            emitLocalSessionAsInitialSession: true
        )

        let clientOptions = SupabaseClientOptions(
            auth: authOptions,
            // V0.54 S3.3d (2026-09-10): inject a custom URLSession so the
            // PostgREST/Auth/Storage/Functions requests don't fall back to
            // URLSession.shared (which on iOS 15+ uses HTTP/3 QUIC when the
            // server advertises it). On the S3.3c build, every coaches-select
            // call stacked ~121s of iOS-native URLSession timeouts ending in
            // cancel — connection never completed against
            // flidjtldfvrrntzwtnsq.supabase.co even though the same payload
            // returned in 0.4–0.8s from curl. The wedged QUIC path made
            // `ensureCoach()` (which sits inside the save path) hang for
            // minutes per attempt, surfacing in-app as a banner that masked
            // the real failure ("Cannot coerce the result to a single JSON
            // object" from the .single() decode on a request that never
            // returned).
            //
            // Fix: URLSessionConfiguration with tight timeouts so a single
            // wedged connection fails fast and the caller can retry. We
            // also bump per-host concurrency down to 4 so a hung request
            // can't pin all 6 URLSession.shared slots (which is what
            // produced the 18 stacked ~121s GETs observed in os_log).
            //
            // `waitsForConnectivity = false` keeps requests from being
            // parked on the "waiting for network" queue (we surface an
            // immediate error instead). Note: iOS URLSession does not
            // expose a direct HTTP/3 disable knob; this configures HTTP/1.1
            // + HTTP/2 with bounded timeouts so a wedged HTTP/3 attempt
            // cannot dominate the request budget.
            global: SupabaseClientOptions.GlobalOptions(
                headers: [:],
                session: Self.makeBoundedSession()
            )
        )

        client = SupabaseClient(
            supabaseURL: supabaseURL,
            supabaseKey: anonKey,
            options: clientOptions
        )
    }

    /// URLSession used by every supabase-swift request. Short timeouts
    /// (12s request / 25s resource / no connectivity wait) so a wedged
    /// connection surfaces as a URLError within seconds instead of the
    /// default 60s+60s stack.
    private static func makeBoundedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 25
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 4
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }
}
