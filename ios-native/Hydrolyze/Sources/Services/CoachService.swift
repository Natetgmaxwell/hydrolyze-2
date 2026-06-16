import Foundation
import Supabase

/// CoachService — query layer for coaches table.
final class CoachService {
    private let supabase = SupabaseService.shared.client

    /// Fetch the current coach's profile from the coaches table.
    func fetchCoach(coachId: String) async throws -> Coach {
        let response = try await supabase.from("coaches")
            .select()
            .eq("id", value: coachId)
            .single()
            .execute()
        return try JSONDecoder().decode(Coach.self, from: response.data)
    }

    /// Update the coach's name and/or pool_units.
    func updateCoach(coachId: String, name: String?, poolUnits: String?) async throws -> Coach {
        struct UpdatePayload: Encodable {
            let name: String?
            let poolUnits: String?
        }
        let payload = UpdatePayload(name: name, poolUnits: poolUnits)
        let response = try await supabase.from("coaches")
            .update(payload)
            .eq("id", value: coachId)
            .select()
            .single()
            .execute()
        return try JSONDecoder().decode(Coach.self, from: response.data)
    }

    /// Mark onboarding as complete for this coach.
    func completeOnboarding(coachId: String) async throws -> Coach {
        let response = try await supabase.from("coaches")
            .update(["onboarding_completed_at": ISO8601DateFormatter().string(from: Date())])
            .eq("id", value: coachId)
            .select()
            .single()
            .execute()
        return try JSONDecoder().decode(Coach.self, from: response.data)
    }
}