import Foundation
import Supabase

@Observable
final class AuthManager {
    var currentUser: User?
    var session: Session?
    var coachId: String?
    var coachName: String?
    var needsOnboarding: Bool = false
    var isLoading: Bool = true

    /// Per-coach preferences (prediction algorithm + confidence display toggle).
    /// Sourced from `coaches.preferences` JSONB column on sign-in.
    ///
    /// SCHEMA MIGRATION REQUIRED (Phase 2.6):
    ///   ALTER TABLE coaches ADD COLUMN preferences jsonb DEFAULT '{}'::jsonb;
    ///
    /// If the column doesn't exist yet, `loadCoachPreferences` falls back
    /// to `.default` and logs. The app still builds and runs — the user
    /// just can't persist preferences until the migration is applied.
    var coachPreferences: CoachPreferences = .default

    private let supabase = SupabaseService.shared.client
    private let authService = AuthService()

    init() {
        Task {
            for await (event, session) in supabase.auth.authStateChanges {
                await handleAuthEvent(event, session: session)
            }
        }

        Task {
            await checkExistingSession()
        }
    }

    private func checkExistingSession() async {
        do {
            let currentSession = try await supabase.auth.session
            let user = currentSession.user
            await MainActor.run {
                self.currentUser = user
                self.isLoading = false
            }
            await resolveCoach(user: user)
        } catch {
            print("[AuthManager] session check error: \(error)")
            await MainActor.run { self.isLoading = false }
        }
    }

    private func handleAuthEvent(_ event: AuthChangeEvent, session: Session?) async {
        switch event {
        case .signedIn:
            await MainActor.run {
                self.session = session
                self.currentUser = session?.user
            }
            if let user = session?.user {
                await resolveCoach(user: user)
            }
        case .signedOut:
            await MainActor.run {
                self.session = nil
                self.currentUser = nil
                self.coachId = nil
                self.coachName = nil
                self.needsOnboarding = false
                self.isLoading = false
            }
        case .userUpdated:
            await MainActor.run {
                self.session = session
                self.currentUser = session?.user
            }
            if let user = session?.user {
                await resolveCoach(user: user)
            }
        case .tokenRefreshed:
            await MainActor.run {
                self.session = session
            }
        case .initialSession:
            await MainActor.run {
                self.session = session
                self.currentUser = session?.user
            }
            if let user = session?.user {
                await resolveCoach(user: user)
            }
        default:
            break
        }
    }

    private func resolveCoach(user: User) async {
        do {
            let coach = try await authService.getOrCreateCoach(
                userId: user.id.uuidString,
                name: user.userMetadata["name"]?.stringValue
            )
            await MainActor.run {
                self.coachId = coach.id
                self.coachName = coach.name
                self.needsOnboarding = coach.onboardingCompletedAt == nil
                self.isLoading = false
            }
            // Load preferences in parallel with the rest of the post-signin
            // work. Failure is non-fatal — we fall back to defaults.
            await loadCoachPreferences(coachId: coach.id)
        } catch {
            print("[AuthManager] resolveCoach error: \(error)")
            await MainActor.run { self.isLoading = false }
        }
    }

    /// Read the coach's `preferences` JSONB column. Defensive on
    /// schema mismatch: any decode error (column missing, JSON
    /// malformed, type mismatch) falls back to `.default`.
    private func loadCoachPreferences(coachId: String) async {
        struct Row: Decodable {
            let preferences: CoachPreferences?
        }
        do {
            let response = try await supabase.from("coaches")
                .select("preferences")
                .eq("id", value: coachId)
                .single()
                .execute()
            let row = try JSONDecoder().decode(Row.self, from: response.data)
            if let prefs = row.preferences {
                await MainActor.run { self.coachPreferences = prefs }
            }
        } catch {
            // Non-fatal. The column may not exist yet (migration not applied),
            // or the JSON may be malformed. Default prefs persist.
            print("[AuthManager] loadCoachPreferences fallback to default: \(error)")
        }
    }

    /// Persist preferences to the `coaches.preferences` JSONB column.
    /// Best-effort: failure is logged but not surfaced to the UI
    /// (the in-memory `coachPreferences` is already updated, so the
    /// user sees their change immediately).
    func saveCoachPreferences(_ prefs: CoachPreferences) async {
        await MainActor.run { self.coachPreferences = prefs }
        guard let coachId = coachId else { return }
        struct Update: Encodable {
            let preferences: CoachPreferences
        }
        do {
            try await supabase.from("coaches")
                .update(Update(preferences: prefs))
                .eq("id", value: coachId)
                .execute()
        } catch {
            print("[AuthManager] saveCoachPreferences failed: \(error)")
        }
    }

    func signOut() async {
        do {
            try await supabase.auth.signOut()
        } catch {
            print("[AuthManager] signOut error: \(error)")
        }
    }

    func signIn(email: String, password: String) async throws {
        _ = try await supabase.auth.signIn(
            email: email,
            password: password
        )
        guard supabase.auth.currentSession != nil else {
            throw AuthServiceError.signInFailed
        }
    }

    func signUp(email: String, password: String) async throws {
        _ = try await supabase.auth.signUp(
            email: email,
            password: password
        )
        guard supabase.auth.currentSession != nil else {
            throw AuthServiceError.signUpFailed
        }
    }

    func resetPassword(email: String) async throws {
        try await supabase.auth.resetPasswordForEmail(email)
    }

    /// Ensures coachId is resolved — waits for in-flight resolution or re-resolves if nil.
    /// Use at save-time instead of reading coachId directly to avoid the startup race.
    func ensureCoach() async throws -> String {
        if let existing = coachId {
            return existing
        }
        guard let user = currentUser else {
            throw AuthServiceError.notAuthenticated
        }
        try await resolveCoachAndReturn(user: user)
        guard let result = coachId else {
            throw AuthServiceError.coachResolutionFailed
        }
        return result
    }

    private func resolveCoachAndReturn(user: User) async throws {
        let coach = try await authService.getOrCreateCoach(
            userId: user.id.uuidString,
            name: user.userMetadata["name"]?.stringValue
        )
        await MainActor.run {
            self.coachId = coach.id
            self.coachName = coach.name
            self.needsOnboarding = coach.onboardingCompletedAt == nil
            self.isLoading = false
        }
    }
}

enum AuthServiceError: LocalizedError {
    case signInFailed
    case signUpFailed
    case notAuthenticated
    case coachResolutionFailed

    var errorDescription: String? {
        switch self {
        case .signInFailed: return "Sign-in failed. Check your email and password."
        case .signUpFailed: return "Sign-up failed. Please try again."
        case .notAuthenticated: return "Not signed in. Please sign in first."
        case .coachResolutionFailed: return "Couldn't load your account. Try again."
        }
    }
}