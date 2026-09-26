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

    /// V0.55 (2026-09-12): login-path coach resolution with bounded
    /// retry. Mirrors `ensureCoachWithRetry` (which only guarded the
    /// save path). One transient failure at sign-in used to leave
    /// `coachId = nil` for the whole session; now we make up to two
    /// attempts, each bounded to 10s, before giving up — and even on
    /// final failure we keep `isLoading = false` so the UI is
    /// reachable (the empty-state surface takes over with a retry).
    func resolveCoach(user: User) async {
        var lastError: (any Error)?
        let perAttempt: TimeInterval = 10
        for attempt in 1...2 {
            do {
                let coach = try await withTimeout(perAttempt) {
                    try await self.authService.getOrCreateCoach(
                        userId: user.id.uuidString,
                        name: user.userMetadata["name"]?.stringValue
                    )
                }
                print("[AuthManager] resolveCoach success: coach.id=\(coach.id), name=\(String(describing: coach.name))")
                self.coachId = coach.id
                self.coachName = coach.name
                self.needsOnboarding = coach.onboardingCompletedAt == nil
                self.isLoading = false
                await loadCoachPreferences(coachId: coach.id)
                return
            } catch is TimeoutError {
                lastError = TimeoutError(interval: perAttempt)
                print("[AuthManager] resolveCoach attempt \(attempt) timed out after \(perAttempt)s")
                continue
            } catch {
                lastError = error
                print("[AuthManager] resolveCoach error: \(error)")
                break
            }
        }
        self.isLoading = false
        _ = lastError
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

    /// V0.52.6 (2026-09-27): App Store 5.1.1(v) account deletion. The
    /// RPC `delete_coach_account` (defined in migration
    /// 20260927000000_account_deletion.sql) wipes every coach-owned
    /// row in one CASCADE chain and removes the auth.users row in the
    /// same transaction. We then sign out locally so the UI clears
    /// even if the auth event propagation lags. Errors are swallowed
    /// for sign-out (matches the existing signOut() pattern) but the
    /// RPC error is surfaced to the caller so the view can show a
    /// banner — the user MUST know if their data wasn't actually
    /// deleted.
    func deleteAccount() async throws {
        try await supabase.rpc("delete_coach_account").execute()
        await signOut()
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

    /// V0.54 S3.3d (2026-09-10): bounded-retry wrapper around
    /// `ensureCoach()`. The save path runs this on every tap, and on
    /// the S3.3c build a wedged iOS URLSession connection (HTTP/3
    /// QUIC against flidjtldfvrrntzwtnsq.supabase.co) stacked 18
    /// ~121s GETs to /rest/v1/coaches that all cancelled without
    /// surfacing an error — the user saw the .single() decode error
    /// instead. This wrapper:
    ///   1. Caches the result so the second save tap is instant.
    ///   2. Bounds each attempt to 10s via Task group cancellation
    ///      so a wedged connection surfaces as URLError(.timedOut)
    ///      within seconds, not minutes.
    ///   3. Retries once on timeout/transport errors with a fresh
    ///      attempt (often enough to escape a sticky QUIC state).
    ///   4. Surfaces the original error after the budget is exhausted
    ///      so the caller's error formatter can print the real cause.
    func ensureCoachWithRetry(maxAttempts: Int = 2, perAttemptTimeout: TimeInterval = 10) async throws -> String {
        if let existing = coachId {
            return existing
        }
        var lastError: (any Error)?
        for attempt in 1...maxAttempts {
            do {
                return try await withTimeout(perAttemptTimeout) {
                    try await self.ensureCoach()
                }
            } catch is TimeoutError {
                lastError = TimeoutError(interval: perAttemptTimeout)
                print("[AuthManager] ensureCoachWithRetry attempt \(attempt) timed out after \(perAttemptTimeout)s")
                continue
            } catch {
                lastError = error
                throw error
            }
        }
        throw lastError ?? AuthServiceError.coachResolutionFailed
    }

    /// V0.54 S3.3d (2026-09-10): local `withTimeout` (supabase-swift's
    /// `withTimeout` is `package`-scoped, not public). Cancels the
    /// inner task group when the deadline elapses so URLSession tasks
    /// get a `Task.checkCancellation()` propagated into the URLSession
    /// async-await bridge, which terminates the in-flight request.
    /// Operation is `@MainActor`-isolated because the only caller
    /// (`ensureCoachWithRetry`) is itself MainActor — AuthManager is a
    /// `@MainActor` class.
    private func withTimeout<T: Sendable>(
        _ interval: TimeInterval,
        operation: @escaping @MainActor @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            defer { group.cancelAll() }
            let deadline = Date(timeIntervalSinceNow: interval)
            group.addTask { try await operation() }
            group.addTask {
                let remaining = deadline.timeIntervalSinceNow
                if remaining > 0 {
                    try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
                try Task.checkCancellation()
                throw TimeoutError(interval: interval)
            }
            // Race to the first result — the winner's value wins, the
            // loser is cancelled by `defer { group.cancelAll() }`.
            guard let result = try await group.next() else {
                throw TimeoutError(interval: interval)
            }
            try Task.checkCancellation()
            return result
        }
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

    /// V0.55 (2026-09-12): public retry hook for the unresolved-coach
    /// UI state. Called from `UnresolvedCoachState` when the coach is
    /// signed in but `coachId` is still nil. We clear the cache and
    /// re-run `resolveCoach` with the same bounded-retry shape as the
    /// login path, so a wedged connection at sign-in can be un-wedged
    /// without forcing a sign-out + sign-in cycle.
    func retryResolveCoach() async {
        guard let user = currentUser else { return }
        print("[AuthManager] retryResolveCoach invoked")
        self.coachId = nil
        self.coachName = nil
        await resolveCoach(user: user)
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

/// V0.54 S3.3d (2026-09-10): thrown by AuthManager.withTimeout when an
/// attempt exceeds its budget. The save path surfaces this in the
/// banner so the user can tell the failure is a transport timeout, not
/// an RLS / payload / PostgREST error.
struct TimeoutError: Error, LocalizedError {
    let interval: TimeInterval
    var errorDescription: String? { "Request timed out after \(Int(interval))s" }
}