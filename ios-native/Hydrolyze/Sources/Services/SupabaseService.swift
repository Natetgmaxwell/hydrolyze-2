import Foundation
import Supabase

/// Supabase client singleton — initialized once at app launch.
/// Uses credentials from the RN app (hydrolyze-mobile/.env.local).
/// PKCE auth callback URL: hydrolyze://login-callback
final class SupabaseService {
    static let shared = SupabaseService()

    // Copy of RN app credentials — REPLACE with real keys before shipping.
    private let supabaseURL = URL(string: "https://flidjtldfvrrntzwtnsq.supabase.co/")!
    private let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZsaWRqdGxkZnZycm50end0bnNxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjE1MjcyODMsImV4cCI6MjA3NzEwMzI4M30.kRhOyhPLVmVww6W03wMrlZnX0yeD6F73_cUpaOaRldE"

    /// Supabase client — thread-safe singleton.
    /// Auth uses PKCE flow (same as RN app). Sessions persist in the iOS Keychain by default.
    let client: SupabaseClient

    private init() {
        let authOptions = SupabaseClientOptions.AuthOptions(
            flowType: .pkce
        )

        let clientOptions = SupabaseClientOptions(
            auth: authOptions
        )

        client = SupabaseClient(
            supabaseURL: supabaseURL,
            supabaseKey: anonKey,
            options: clientOptions
        )
    }
}