import Foundation
import Supabase

@Observable
@MainActor
final class AuthManager {
    var currentUser: User?
    var session: Session?

    // Coach state (the coach is the owner of the squad)
    var coachId: String?
    var coachName: String?
    var needsOnboarding: Bool = false

    // PHASE 2.2: Swimmer state (a swimmer who signs in sees their
    // own data, scoped by auth_id). The swimmer's auth_id is the
    // canonical lifelong identifier — when they switch coaches,
    // only coach_id changes; auth_id (and swimmer_id) stay the
    // same. The data follows the swimmer.
    var swimmerId: String?
    var currentSwimmer: Swimmer?

    var isLoading: Bool = true

    /// What role the current signed-in user plays. Used by
    /// ContentView to route to the right home view.
    /// - `.unauthenticated`: no session
    /// - `.swimmer`: signed in as a swimmer (auth_id matches
    ///               swimmers.auth_id)
    /// - `.coach`: signed in as a coach (auth_id matches coaches.auth_id
    ///             OR no swimmers.auth_id match)
    enum Role {
        case unauthenticated
        case swimmer
        case coach
    }

    var role: Role {
        if currentUser == nil { return .unauthenticated }
        if swimmerId != nil { return .swimmer }
        return .coach
    }

    /// Per-coach preferences (prediction algorithm + confidence display toggle).
    /// Sourced from `coaches.preferences` JSONB column on sign-in.
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

    #if DEBUG
    /// V0.46 Slice 5: screenshot harness — the swimmer home surface
    /// gates on `currentSwimmer`; the harness can't sign in, so this
    /// seeds the swimmer identity the view needs. DEBUG-only; the
    /// launch arg is only passed by the capture harness.
    func seedV46DemoStateIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("-v46-demo-swimmer"),
              currentSwimmer == nil else { return }
        var demo = Swimmer(
            id: "v46-swimmer-1",
            coachId: "v46-demo-coach",
            firstName: "Mia",
            lastName: "Thompson",
            birthdate: nil,
            gender: nil,
            notes: nil,
            preferredGear: nil,
            formStroke: nil,
            mainStroke: "Free",
            archivedAt: nil,
            createdAt: nil
        )
        demo.groups = []
        currentSwimmer = demo
        swimmerId = demo.id
        isLoading = false
    }
    #endif

    private func checkExistingSession() async {
        do {
            let currentSession = try await supabase.auth.session
            let user = currentSession.user
            print("[AuthManager] checkExistingSession: user.id=\(user.id.uuidString), email=\(String(describing: user.email)), session.expiresAt=\(currentSession.expiresAt)")
            await MainActor.run {
                self.currentUser = user
                self.isLoading = false
            }
            // Resolve BOTH coach and swimmer roles in parallel —
            // the role enum picks which one is used for routing.
            // A user can in theory be both (e.g. a coach who is
            // also a swimmer themselves); we pick swimmer-first
            // so the swimmer view shows their own data.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { @MainActor in await self.resolveCoach(user: user) }
                group.addTask { @MainActor in await self.resolveSwimmer(user: user) }
            }
        } catch {
            print("[AuthManager] session check error: \(error)")
            await MainActor.run { self.isLoading = false }
        }
    }

    private func handleAuthEvent(_ event: AuthChangeEvent, session: Session?) async {
        print("[AuthManager] auth event: \(event), session=\(String(describing: session?.user.id.uuidString)), expiresAt=\(String(describing: session?.expiresAt.description))")
        switch event {
        case .signedIn:
            await MainActor.run {
                self.session = session
                self.currentUser = session?.user
            }
            if let user = session?.user {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { @MainActor in await self.resolveCoach(user: user) }
                    group.addTask { @MainActor in await self.resolveSwimmer(user: user) }
                }
            }
        case .signedOut:
            await MainActor.run {
                self.session = nil
                self.currentUser = nil
                self.coachId = nil
                self.coachName = nil
                self.swimmerId = nil
                self.currentSwimmer = nil
                self.needsOnboarding = false
                self.isLoading = false
            }
        case .userUpdated:
            await MainActor.run {
                self.session = session
                self.currentUser = session?.user
            }
            if let user = session?.user {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { @MainActor in await self.resolveCoach(user: user) }
                    group.addTask { @MainActor in await self.resolveSwimmer(user: user) }
                }
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
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { @MainActor in await self.resolveCoach(user: user) }
                    group.addTask { @MainActor in await self.resolveSwimmer(user: user) }
                }
            }
        default:
            break
        }
    }

    private func resolveCoach(user: User) async {
        print("[AuthManager] resolveCoach start: user.id=\(user.id.uuidString), email=\(String(describing: user.email))")
        do {
            let coach = try await authService.getOrCreateCoach(
                userId: user.id.uuidString,
                name: user.userMetadata["name"]?.stringValue
            )
            print("[AuthManager] resolveCoach success: coach.id=\(coach.id), name=\(String(describing: coach.name))")
            self.coachId = coach.id
            self.coachName = coach.name
            self.needsOnboarding = coach.onboardingCompletedAt == nil
            self.isLoading = false
            // Load preferences in parallel with the rest of the post-signin
            // work. Failure is non-fatal — we fall back to defaults.
            await loadCoachPreferences(coachId: coach.id)
        } catch {
            print("[AuthManager] resolveCoach error: \(error)")
            self.isLoading = false
        }
    }

    /// PHASE 2.2: Resolve the swimmer for the current auth user.
    /// Looks up swimmers.auth_id = auth.uid(). If found, populates
    /// swimmerId + currentSwimmer. If not, leaves them nil — the
    /// user is a coach (or has no swimmer role yet).
    private func resolveSwimmer(user: User) async {
        do {
            // The new schema's swimmer_own_* policies grant SELECT
            // on the swimmer's own row. So a signed-in swimmer can
            // read themselves; a coach can read all their swimmers
            // via the coach policies.
            //
            // We decode via the model's Codable conformance (uses
            // CodingKeys for the snake_case → camelCase mapping).
            // The `email` column was added in Phase 2.1; for
            // existing swimmers (no email yet), the field stays
            // nil.
            let response = try await supabase.from("swimmers")
                .select("id, auth_id, email, first_name, last_name, coach_id, main_stroke, form_stroke, archived_at, created_at")
                .eq("auth_id", value: user.id.uuidString)
                .limit(1)
                .execute()
            let rows = try JSONDecoder().decode([Swimmer].self, from: response.data)
            if let swimmer = rows.first {
                self.swimmerId = swimmer.id
                self.currentSwimmer = swimmer
            } else {
                self.swimmerId = nil
                self.currentSwimmer = nil
            }
        } catch {
            print("[AuthManager] resolveSwimmer error: \(error)")
            self.swimmerId = nil
            self.currentSwimmer = nil
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
                self.coachPreferences = prefs
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
        self.coachPreferences = prefs
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
        // Clear state immediately so the UI doesn't show stale data
        // while the auth event propagates.
        self.coachId = nil
        self.coachName = nil
        self.swimmerId = nil
        self.currentSwimmer = nil
        self.needsOnboarding = false
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
        self.coachId = coach.id
        self.coachName = coach.name
        self.needsOnboarding = coach.onboardingCompletedAt == nil
        self.isLoading = false
    }
}

enum AuthServiceError: LocalizedError {
    case signInFailed
    case signUpFailed
    case notAuthenticated
    case coachResolutionFailed
    case swimmerResolutionFailed
    case swimmerNotLinked

    var errorDescription: String? {
        switch self {
        case .signInFailed: return "Sign-in failed. Check your email and password."
        case .signUpFailed: return "Sign-up failed. Please try again."
        case .notAuthenticated: return "Not signed in. Please sign in first."
        case .coachResolutionFailed: return "Couldn't load your account. Try again."
        case .swimmerResolutionFailed: return "Couldn't load your swimmer profile. Try again."
        case .swimmerNotLinked: return "No swimmer account linked to your sign-in. Ask your coach to invite you."
        }
    }
}