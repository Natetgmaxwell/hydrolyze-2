import Foundation
import Supabase

/// Supabase client singleton — initialized once at app launch.
/// Credentials are hardcoded (see constants below). PKCE auth callback
/// URL: hydrolyze://login-callback
final class SupabaseService {
    static let shared = SupabaseService()

    // Copy of RN app credentials — REPLACE with real keys before shipping.
    private let supabaseURL = URL(string: "https://flidjtldfvrrntzwtnsq.supabase.co/")!
    private let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZsaWRqdGxkZnZycm50end0bnNxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjE1MjcyODMsImV4cCI6MjA3NzEwMzI4M30.kRhOyhPLVmVww6W03wMrlZnX0yeD6F73_cUpaOaRldE"

    /// V0.55 (2026-09-12): cached access token for PostgREST queries.
    /// supabase-swift 2.47.0's SupabaseClient.handleTokenChanged()
    /// listener sets functions/realtime/realtimeV2 auth tokens on
    /// signedIn but SKIPS the PostgREST client (see Sources/Supabase/
    /// SupabaseClient.swift L401-405 — only `functions.setAuth`,
    /// `realtime.setAuth`, `realtimeV2.setAuth` — no `rest.setAuth`).
    /// Without an explicit token closure, PostgREST GETs go out with
    /// the anon key (RLS denies → empty `[]`). The fix is to provide
    /// an `accessToken` closure to SupabaseClient that reads from
    /// this cached token. We maintain it by subscribing to
    /// `authStateChanges` in init() and updating on every signedIn /
    /// tokenRefreshed / signedOut event.
    private let cachedAccessToken = TokenCache()

    /// Supabase client — thread-safe singleton.
    /// Auth uses PKCE flow (same as RN app). Sessions persist in the iOS Keychain by default.
    let client: SupabaseClient

    private init() {
        let tokenBox = cachedAccessToken
        let anonKeyCopy = anonKey
        let authOptions = SupabaseClientOptions.AuthOptions(
            flowType: .pkce,
            // ponytail: opt-in to the new session behavior (supabase-swift PR #822/#844).
            // The locally stored session is always emitted, even if expired.
            // AuthManager.checkSession() handles the expiry check.
            emitLocalSessionAsInitialSession: true,
            // V0.55 (2026-09-12): WORKAROUND for supabase-swift 2.47.0
            // PostgREST-not-receiving-auth-token bug (see cachedAccessToken
            // doc-comment above). This closure is called by PostgREST on
            // every request to read the current bearer token. Reading
            // from our cached atomic avoids the SessionManager.session()
            // path that throws sessionMissing when called before the
            // signedIn event has propagated to the auth client's storage.
            accessToken: {
                let tok = tokenBox.value
                return tok.isEmpty ? anonKeyCopy : tok
            }
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

        // V0.55 (2026-09-12): start the auth-state listener that keeps
        // cachedAccessToken up-to-date. We capture the auth client from
        // the freshly-initialized SupabaseClient and listen for
        // signedIn / tokenRefreshed / signedOut to mirror the current
        // access token into our LockIsolated cache. The PostgREST
        // client reads from this cache on every request via the
        // accessToken closure set above — see the cachedAccessToken
        // doc-comment for the underlying bug this works around.
        Task { [client] in
            for await (event, session) in client.auth.authStateChanges {
                let newToken: String
                switch event {
                case .signedIn, .tokenRefreshed, .initialSession:
                    newToken = session?.accessToken ?? ""
                case .signedOut:
                    newToken = ""
                default:
                    continue
                }
                tokenBox.setValue(newToken)
            }
        }
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

/// V0.55 (2026-09-12): thread-safe bearer-token cache. We use an
/// NSLock-protected class instead of `swift-atomics`' `Atomic` or
/// `swift-concurrency-extras`' `LockIsolated` because those are not
/// exported into the Supabase module's public interface (and adding
/// a new dependency for one type isn't worth the project.yml churn).
/// The PostgREST accessToken closure reads from here on every
/// request; the authStateChanges listener writes to it on every
/// signedIn / tokenRefreshed / signedOut event.
private final class TokenCache: @unchecked Sendable {
    private var token: String = ""
    private let lock = NSLock()

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    func setValue(_ newValue: String) {
        lock.lock()
        defer { lock.unlock() }
        token = newValue
    }
}
