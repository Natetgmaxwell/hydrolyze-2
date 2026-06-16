import Foundation
import Supabase

/// AuthService — wraps Supabase Auth with app-specific coach resolution.
/// Mirrors the logic from the RN app's lib/auth.ts.
final class AuthService {
    private let supabase = SupabaseService.shared.client

    /// Fetches the coach record for a given auth user ID.
    /// Creates the coach row if it doesn't exist yet (getOrCreateCoach pattern).
    func getOrCreateCoach(userId: String, name: String?) async throws -> Coach {
        let response = try await supabase.from("coaches")
            .select()
            .eq("auth_id", value: userId)
            .single()
            .execute()

        if let existing = try? JSONDecoder().decode(Coach.self, from: response.data) {
            return existing
        }

        struct InsertPayload: Encodable {
            let authId: String
            let name: String?

            enum CodingKeys: String, CodingKey {
                case authId = "auth_id"
                case name
            }
        }
        let payload = InsertPayload(authId: userId, name: name)
        let insertResponse = try await supabase.from("coaches")
            .insert(payload)
            .select()
            .single()
            .execute()

        return try JSONDecoder().decode(Coach.self, from: insertResponse.data)
    }

    /// Sign up a new coach.
    func signUp(email: String, password: String, name: String?) async throws -> Session {
        let response = try await supabase.auth.signUp(email: email, password: password)
        guard let currentSession = supabase.auth.currentSession else {
            throw AuthError.noSession
        }
        _ = try await getOrCreateCoach(userId: currentSession.user.id.uuidString, name: name)
        return response.session ?? currentSession
    }

    /// Sign in an existing coach.
    func signIn(email: String, password: String) async throws -> Session {
        return try await supabase.auth.signIn(email: email, password: password)
    }

    /// Sign out the current coach.
    func signOut() async throws {
        try await supabase.auth.signOut()
    }

    /// Send a password reset email.
    func resetPassword(email: String) async throws {
        try await supabase.auth.resetPasswordForEmail(email)
    }
}

enum AuthError: Error, LocalizedError {
    case noSession

    var errorDescription: String? {
        switch self {
        case .noSession: return "No auth session found"
        }
    }
}