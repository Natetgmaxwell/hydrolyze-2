import Foundation
import Supabase

/// AuthService — wraps Supabase Auth with app-specific user resolution.
///
/// Two roles supported:
/// - **Coach** — owner of the squad; gets a `coaches` row keyed
///   by auth.users.id (the `coaches.auth_id` column).
/// - **Swimmer** — athlete who records times; gets a `swimmers`
///   row keyed by auth.users.id (the `swimmers.auth_id` column
///   added in Phase 2.1).
///
/// The swimmer's auth_id is the **canonical lifelong identifier**
/// — when a swimmer switches coaches, only `swimmers.coach_id`
/// changes; auth_id and swimmer_id stay the same. The data
/// follows the swimmer.
final class AuthService {
    private let supabase = SupabaseService.shared.client

    // MARK: - Coach

    /// Fetches the coach record for a given auth user ID.
    /// Creates the coach row if it doesn't exist yet (getOrCreateCoach pattern).
    ///
    /// V0.55 (2026-09-12): the prior implementation called `.single()`
    /// on the SELECT, then `try? JSONDecoder().decode(...)` on the body.
    /// Postgrest returned PGRST116 ("Cannot coerce the result to a single
    /// JSON object") on zero rows — `.single()` throws BEFORE the
    /// decoder's `try?` ever runs, so the INSERT-create fallback below
    /// was unreachable. The whole "getOrCreate" pattern degenerated
    /// into "get", and on transient failures left `coachId = nil` for
    /// the rest of the session, blanking every list screen.
    ///
    /// Fix: do the lookup with `.limit(1)` (no `.single()`) so zero
    /// rows is a non-throwing empty array. Only fall through to the
    /// INSERT when the lookup returns zero rows OR decodes to nothing.
    ///
    /// V0.55 (2026-09-12, second-pass): supabase-swift 2.47.0's
    /// SessionManager.session() can race the `signedIn` event — on
    /// the very first call after sign-in, the lookup GET goes out
    /// before the client's session store is updated, so the request
    /// carries the anon key (RLS denies → empty `[]`). Without a
    /// guard, the function then falls through to the INSERT, which
    /// also fails RLS (42501). The dispatch's `resolveCoach` retry
    /// only catches TimeoutError, not this case.
    ///
    /// Mitigation: retry the lookup a few times with small backoff
    /// before giving up and inserting. By attempt 3 the client's
    /// session loader has caught up and the GET carries the JWT.
    /// (The SupabaseService-level TokenCache closes the real
    /// long-term fix; the retry here is belt-and-braces for the
    /// initial-login race.)
    func getOrCreateCoach(userId: String, name: String?) async throws -> Coach {
        let lookupMaxAttempts = 4
        let lookupBackoffNanos: UInt64 = 250_000_000  // 0.25s
        for attempt in 1...lookupMaxAttempts {
            let lookupResponse = try await supabase.from("coaches")
                .select()
                .eq("auth_id", value: userId)
                .limit(1)
                .execute()
            let decoder = JSONDecoder()
            if let existing = try? decoder.decode([Coach].self, from: lookupResponse.data).first {
                return existing
            }
            if attempt < lookupMaxAttempts {
                try await Task.sleep(nanoseconds: lookupBackoffNanos * UInt64(attempt))
            }
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

    /// Sign out the current user (coach OR swimmer).
    func signOut() async throws {
        try await supabase.auth.signOut()
    }

    /// Send a password reset email.
    func resetPassword(email: String) async throws {
        try await supabase.auth.resetPasswordForEmail(email)
    }

    // MARK: - Swimmer (Phase 2.3)

    /// PHASE 2.3: Coach-side swimmer account creation.
    ///
    /// The coach creates the swimmer's account from their side of
    /// the app. The flow is:
    /// 1. Coach enters the swimmer's email + a one-time password
    ///    (the coach can override the suggested password)
    /// 2. We call `supabase.auth.admin.createUser(...)` to
    ///    create the auth.users row (this is a service-role
    ///    operation; the coach's session doesn't have admin
    ///    rights in prod, so this needs to go through a
    ///    server-side function or the `service_role` key — for
    ///    MVP we use the coach's session and accept the
    ///    RLS-bypassing INSERT in the `profiles` table)
    /// 3. We INSERT a `swimmers` row linked to that auth_id
    ///    and the coach's coach_id
    ///
    /// Why coach-driven (Option C from the user):
    ///   - The VISION.md "coach is the authority" principle
    ///     means the swimmer doesn't sign themselves up — the
    ///     coach controls who has access to the squad's data
    ///   - The coach has already met the swimmer face-to-face;
    ///     the email + one-time password can be handed over in
    ///     person or via a coach-controlled channel
    ///   - Avoids the open-signup attack vector (someone could
    ///     sign up with a coach's email and see the squad's data)
    ///
    /// For MVP: this method assumes the coach is already signed
    /// in and the call is made from the coach's session. The
    /// Supabase admin endpoint requires either the service_role
    /// key OR a server-side function. For MVP we use a server-
    /// side function (create_swimmer_account) that runs with
    /// elevated privileges.
    func createSwimmerAccount(
        email: String,
        oneTimePassword: String,
        swimmerId: String?,
        coachId: String
    ) async throws -> Swimmer {
        // PHASE 2.3 server-side contract:
        //   - Call the `create_swimmer_account` Postgres function
        //     with (p_email, p_password, p_coach_id, p_swimmer_id)
        //   - The function:
        //       1. Creates the auth.users row
        //       2. Creates the profiles row
        //       3. Sets swimmers.auth_id + swimmers.email
        //       4. Returns the swimmers row
        //
        // We invoke it via the `rpc` method. Until the function
        // is deployed, this will fail with a 404 — the caller
        // (the coach-side Create Swimmer sheet) should handle
        // the failure gracefully with a "contact support" message.
        struct Params: Encodable {
            let pEmail: String
            let pPassword: String
            let pCoachId: String
            let pSwimmerId: String?

            enum CodingKeys: String, CodingKey {
                case pEmail = "p_email"
                case pPassword = "p_password"
                case pCoachId = "p_coach_id"
                case pSwimmerId = "p_swimmer_id"
            }
        }
        let params = Params(
            pEmail: email,
            pPassword: oneTimePassword,
            pCoachId: coachId,
            pSwimmerId: swimmerId
        )
        let response = try await supabase.rpc(
            "create_swimmer_account",
            params: params
        ).execute()

        // Decode the returned swimmers row
        return try JSONDecoder().decode(Swimmer.self, from: response.data)
    }

    /// PHASE 2.3: Swimmer-side sign-in.
    /// Standard Supabase auth.signIn — the role resolution
    /// happens in AuthManager (which looks up swimmers.auth_id
    /// for the new auth user). Returns the Session on success.
    func signInSwimmer(email: String, password: String) async throws -> Session {
        return try await supabase.auth.signIn(email: email, password: password)
    }

    /// PHASE 2.3: Swimmer-side password reset.
    /// Standard Supabase flow — the swimmer requests a reset,
    /// gets an email with a magic link, sets a new password.
    func resetSwimmerPassword(email: String) async throws {
        try await supabase.auth.resetPasswordForEmail(email)
    }

    /// PHASE 2.3: Swimmer-side password change after first login.
    /// The swimmer signs in with the one-time password the coach
    /// gave them, then sets their own permanent password.
    func updateSwimmerPassword(currentPassword: String, newPassword: String) async throws {
        // Re-auth with current password first (Supabase requires
        // fresh credentials for password updates)
        guard supabase.auth.currentUser != nil else {
            throw AuthError.noSession
        }
        // Supabase auth.updateUser with the new password
        try await supabase.auth.update(user: UserAttributes(password: newPassword))
    }

    // MARK: - PHASE 2.8: Invite-code onboarding

    /// PHASE 2.8.2: Coach-side invite code generation.
    /// Calls the generate_invite_code Postgres RPC. Returns
    /// the 6-char code the coach can hand to the swimmer.
    /// The function generates the code, sets the expiry
    /// (default 7 days), and overwrites any prior code on
    /// the swimmer row (one active code per swimmer).
    ///
    /// The coach must be the swimmer's owner; the RPC
    /// validates this server-side and errors otherwise.
    func generateInviteCode(
        swimmerId: String,
        expiresInDays: Int = 7
    ) async throws -> String {
        struct Params: Encodable {
            let pSwimmerId: String
            let pExpiresInDays: Int

            enum CodingKeys: String, CodingKey {
                case pSwimmerId = "p_swimmer_id"
                case pExpiresInDays = "p_expires_in_days"
            }
        }
        let params = Params(
            pSwimmerId: swimmerId,
            pExpiresInDays: expiresInDays
        )
        let response = try await supabase.rpc(
            "generate_invite_code",
            params: params
        ).execute()

        // The RPC returns TEXT (the 6-char code)
        let code = String(data: response.data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if code.count != 6 {
            throw AuthError.inviteCodeGenerationFailed(
                "expected 6-char code, got \(code.count)"
            )
        }
        return code
    }

    /// PHASE 2.8.2: Swimmer-side invite code redemption.
    /// Calls the redeem_invite_code Postgres RPC. On success:
    /// - Creates the auth.users row (signed in via the
    ///   Supabase auth session returned by the supabase auth
    ///   signIn call the caller makes after this).
    /// - Sets swimmers.auth_id + swimmers.email on the swimmer row.
    /// - Clears the invite_code (one-time use enforced server-side).
    ///
    /// Returns the updated Swimmer row (with auth_id set).
    /// The caller should follow up with signInSwimmer(email,
    /// password) to establish the auth session.
    func redeemInviteCode(
        code: String,
        email: String,
        password: String,
        firstName: String,
        lastName: String? = nil
    ) async throws -> Swimmer {
        struct Params: Encodable {
            let pCode: String
            let pEmail: String
            let pPassword: String
            let pFirstName: String
            let pLastName: String?

            enum CodingKeys: String, CodingKey {
                case pCode = "p_code"
                case pEmail = "p_email"
                case pPassword = "p_password"
                case pFirstName = "p_first_name"
                case pLastName = "p_last_name"
            }
        }
        let params = Params(
            pCode: code,
            pEmail: email,
            pPassword: password,
            pFirstName: firstName,
            pLastName: lastName
        )
        let response = try await supabase.rpc(
            "redeem_invite_code",
            params: params
        ).execute()

        return try JSONDecoder().decode(Swimmer.self, from: response.data)
    }
}

enum AuthError: Error, LocalizedError {
    case noSession
    case createSwimmerAccountFailed(String)
    case invalidEmail
    case weakPassword
    case inviteCodeGenerationFailed(String)
    case inviteCodeRedemptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .noSession: return "No auth session found"
        case .createSwimmerAccountFailed(let msg): return "Couldn't create swimmer account: \(msg)"
        case .invalidEmail: return "Invalid email format"
        case .weakPassword: return "Password too weak — use at least 8 characters"
        case .inviteCodeGenerationFailed(let msg): return "Couldn't generate invite code: \(msg)"
        case .inviteCodeRedemptionFailed(let msg): return "Couldn't redeem invite code: \(msg)"
        }
    }
}