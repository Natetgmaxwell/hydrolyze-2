import Foundation
import Supabase

/// SwimmerService — query layer for swimmers, groups, swimmer_groups, swimmer_pbs.
final class SwimmerService {
    let supabase = SupabaseService.shared.client

    /// Fetch all active (non-archived) swimmers for the coach.
    func fetchSwimmers(coachId: String) async throws -> [Swimmer] {
        let response = try await supabase.from("swimmers")
            .select()
            .eq("coach_id", value: coachId)
            .filter("archived_at", operator: "is", value: "null")
            .order("first_name", ascending: true)
            .execute()
        return try JSONDecoder().decode([Swimmer].self, from: response.data)
    }

    /// Fetch a single swimmer by ID.
    func fetchSwimmer(swimmerId: String) async throws -> Swimmer {
        let response = try await supabase.from("swimmers")
            .select()
            .eq("id", value: swimmerId)
            .single()
            .execute()
        return try JSONDecoder().decode(Swimmer.self, from: response.data)
    }

    /// Create a new swimmer.
    func createSwimmer(coachId: String, firstName: String, lastName: String? = nil, birthdate: String? = nil, gender: String? = nil) async throws -> Swimmer {
        struct CreatePayload: Encodable {
            let coachId: String
            let firstName: String
            let lastName: String?
            let birthdate: String?
            let gender: String?
            // The legacy `name` column is still NOT NULL on the swimmers
            // table (it was never dropped after the split_swimmer_name
            // migration). Supabase rejects inserts that omit it. Build the
            // combined name from first_name [+ last_name] so callers don't
            // have to remember.
            let name: String
            enum CodingKeys: String, CodingKey {
                case coachId = "coach_id"
                case firstName = "first_name"
                case lastName = "last_name"
                case birthdate
                case gender
                case name
            }
        }
        let trimmedLast = lastName?.trimmingCharacters(in: .whitespaces)
        let combinedName: String
        if let l = trimmedLast, !l.isEmpty {
            combinedName = "\(firstName.trimmingCharacters(in: .whitespaces)) \(l)"
        } else {
            combinedName = firstName.trimmingCharacters(in: .whitespaces)
        }
        let payload = CreatePayload(
            coachId: coachId,
            firstName: firstName,
            lastName: lastName,
            birthdate: birthdate,
            gender: gender,
            name: combinedName
        )
        let response = try await supabase.from("swimmers")
            .insert(payload)
            .select()
            .single()
            .execute()
        return try JSONDecoder().decode(Swimmer.self, from: response.data)
    }

    /// Transfer a swimmer to a different coach. Calls the
    /// transfer_swimmer SECURITY DEFINER RPC, which validates the
    /// caller is the current coach, removes squad membership (the old
    /// squad belongs to the old coach), and updates coach_id. The
    /// swimmer's PBs and profile follow automatically via RLS.
    /// Historical recorded_times stay with the old coach's sessions.
    func transferSwimmer(swimmerId: String, toCoachId: String) async throws -> Swimmer {
        struct Params: Encodable {
            let pSwimmerId: String
            let pNewCoachId: String
            enum CodingKeys: String, CodingKey {
                case pSwimmerId = "p_swimmer_id"
                case pNewCoachId = "p_new_coach_id"
            }
        }
        let response = try await supabase.rpc("transfer_swimmer", params: Params(pSwimmerId: swimmerId, pNewCoachId: toCoachId))
            .execute()
        return try JSONDecoder().decode(Swimmer.self, from: response.data)
    }

    /// Update an existing swimmer.
    func updateSwimmer(swimmerId: String, updates: [String: String]) async throws -> Swimmer {
        var combined: [String: String] = updates
        combined["id"] = swimmerId

        let response = try await supabase.from("swimmers")
            .update(combined)
            .eq("id", value: swimmerId)
            .select()
            .single()
            .execute()
        return try JSONDecoder().decode(Swimmer.self, from: response.data)
    }

    /// Archive (soft-delete) a swimmer.
    func archiveSwimmer(swimmerId: String) async throws -> Swimmer {
        let response = try await supabase.from("swimmers")
            .update(["archived_at": ISO8601DateFormatter().string(from: Date())])
            .eq("id", value: swimmerId)
            .select()
            .single()
            .execute()
        return try JSONDecoder().decode(Swimmer.self, from: response.data)
    }

    /// Fetch all groups for this coach.
    func fetchGroups(coachId: String) async throws -> [CoachGroup] {
        let response = try await supabase.from("groups")
            .select()
            .eq("coach_id", value: coachId)
            .order("name", ascending: true)
            .execute()
        return try JSONDecoder().decode([CoachGroup].self, from: response.data)
    }

    /// Squad alias for fetching groups. Same query as `fetchGroups` but
    /// named for the new squad-management feature surface.
    func fetchSquadsForCoach(coachId: String) async throws -> [CoachGroup] {
        return try await fetchGroups(coachId: coachId)
    }

    /// Create a new squad. Calls the create_squad RPC (SECURITY DEFINER)
    /// to bypass the RLS WITH CHECK on groups — the same pattern as
    /// create_swimmer_account and redeem_invite_code.
    func createSquad(coachId: String, name: String) async throws -> CoachGroup {
        struct Params: Encodable {
            let pName: String
            enum CodingKeys: String, CodingKey {
                case pName = "p_name"
            }
        }
        let response = try await supabase.rpc("create_squad", params: Params(pName: name))
            .execute()
        return try JSONDecoder().decode(CoachGroup.self, from: response.data)
    }

    /// Rename a squad by updating the `groups.name` column.
    func renameSquad(groupId: String, name: String) async throws -> CoachGroup {
        struct RenamePayload: Encodable {
            let name: String
        }
        let response = try await supabase.from("groups")
            .update(RenamePayload(name: name))
            .eq("id", value: groupId)
            .select()
            .single()
            .execute()
        return try JSONDecoder().decode(CoachGroup.self, from: response.data)
    }

    /// Create a new group.
    func createGroup(coachId: String, name: String) async throws -> CoachGroup {
        struct CreateGroupPayload: Encodable {
            let coachId: String
            let name: String
            enum CodingKeys: String, CodingKey {
                case coachId = "coach_id"
                case name
            }
        }
        let payload = CreateGroupPayload(coachId: coachId, name: name)
        let response = try await supabase.from("groups")
            .insert(payload)
            .select()
            .single()
            .execute()
        return try JSONDecoder().decode(CoachGroup.self, from: response.data)
    }

    /// Fetch swimmers assigned to a specific group/squad.
    func fetchSwimmersInGroup(groupId: String) async throws -> [Swimmer] {
        let response = try await supabase.from("swimmer_groups")
            .select("""
                swimmer_id,
                swimmers!inner(
                    id, coach_id, first_name, last_name, birthdate,
                    gender, notes, preferred_gear, form_stroke,
                    main_stroke, archived_at, created_at
                )
                """)
            .eq("group_id", value: groupId)
            .execute()

        struct Row: Decodable {
            let swimmer: Swimmer
            enum CodingKeys: String, CodingKey {
                case swimmer = "swimmers"
            }
        }
        let rows = try JSONDecoder().decode([Row].self, from: response.data)
        return rows.map { $0.swimmer }
    }

    /// Fetch coaches eligible for squad assignment. The owning coach plus
    /// any other coaches already linked to this account.
    func fetchCoachesForSquadManagement(coachId: String) async throws -> [Coach] {
        let response = try await supabase.from("coaches")
            .select()
            .execute()
        return try JSONDecoder().decode([Coach].self, from: response.data)
    }

    /// Fetch coaches currently assigned to a squad via the `coach_squads`
    /// join table. Fails at runtime until the schema migration is applied.
    func fetchCoachesForSquad(groupId: String) async throws -> [CoachSquadAssignment] {
        let response = try await supabase.from("coach_squads")
            .select()
            .eq("group_id", value: groupId)
            .execute()
        return try JSONDecoder().decode([CoachSquadAssignment].self, from: response.data)
    }

    /// Add a coach to a squad. Fails at runtime until the `coach_squads`
    /// schema migration is applied.
    func addCoachToSquad(coachId: String, groupId: String, role: String = "assistant") async throws {
        struct AddPayload: Encodable {
            let coachId: String
            let groupId: String
            let role: String
            enum CodingKeys: String, CodingKey {
                case coachId = "coach_id"
                case groupId = "group_id"
                case role
            }
        }
        try await supabase.from("coach_squads")
            .insert(AddPayload(coachId: coachId, groupId: groupId, role: role))
            .execute()
    }

    /// Remove a coach from a squad. Fails at runtime until the `coach_squads`
    /// schema migration is applied.
    func removeCoachFromSquad(coachId: String, groupId: String) async throws {
        try await supabase.from("coach_squads")
            .delete()
            .eq("coach_id", value: coachId)
            .eq("group_id", value: groupId)
            .execute()
    }

    /// Assign a swimmer to a group.
    func assignSwimmerToGroup(swimmerId: String, groupId: String) async throws {
        struct AssignPayload: Encodable {
            let swimmerId: String
            let groupId: String
            enum CodingKeys: String, CodingKey {
                case swimmerId = "swimmer_id"
                case groupId = "group_id"
            }
        }
        try await supabase.from("swimmer_groups")
            .insert(AssignPayload(swimmerId: swimmerId, groupId: groupId))
            .execute()
    }

    /// Remove a swimmer from a group.
    func removeSwimmerFromGroup(swimmerId: String, groupId: String) async throws {
        try await supabase.from("swimmer_groups")
            .delete()
            .eq("swimmer_id", value: swimmerId)
            .eq("group_id", value: groupId)
            .execute()
    }

    /// Fetch PBs for a swimmer (optionally filtered by distance and stroke).
    func fetchPersonalBests(swimmerId: String, distance: Int? = nil, stroke: String? = nil) async throws -> [SwimmerPB] {
        var query = supabase.from("swimmer_pbs")
            .select()
            .eq("swimmer_id", value: swimmerId)
        if let d = distance { query = query.eq("distance", value: d) }
        if let s = stroke { query = query.eq("stroke", value: s) }
        let response = try await query.execute()
        return try JSONDecoder().decode([SwimmerPB].self, from: response.data)
    }

    /// Upsert a personal best (insert or update if already exists for
    /// distance+stroke+intensity+gear).
    /// PHASE 2.6 v1.13.0: `intensity` parameter added. The 5-way match
    /// (swimmer, stroke, distance, intensity, gear) is the canonical
    /// lookup key. `intensity` defaults to 'max' for callers that
    /// haven't been updated to specify it.
    func upsertPersonalBest(
        swimmerId: String,
        distance: Int,
        stroke: String,
        timeMs: Int,
        gear: String?,
        intensity: String = "max"
    ) async throws -> SwimmerPB {
        struct UpsertPayload: Encodable {
            let swimmerId: String
            let distance: Int
            let stroke: String
            let timeMs: Int
            let gear: String?
            let intensity: String
            let recordedAt: String
        }
        let payload = UpsertPayload(
            swimmerId: swimmerId,
            distance: distance,
            stroke: stroke,
            timeMs: timeMs,
            gear: gear,
            intensity: intensity,
            recordedAt: ISO8601DateFormatter().string(from: Date())
        )
        let response = try await supabase.from("swimmer_pbs")
            .upsert(payload)
            .select()
            .single()
            .execute()
        return try JSONDecoder().decode(SwimmerPB.self, from: response.data)
    }

    /// PHASE 2.6 v1.13.0: convenience upsert that takes a `Prediction`
    /// (from PBService) and writes a coach-confirmed PB. Used by
    /// SessionReviewView when the coach manually confirms a
    /// low-confidence pairing. Writes the lap time as a `source =
    /// coachConfirmed` PB, which the predictor can use as
    /// highest-weight training data in v2.
    func upsertCoachConfirmedPB(
        swimmerId: String,
        set: WorkoutSet,
        gear: String?,
        intensity: String,
        timeMs: Int
    ) async throws -> SwimmerPB {
        return try await upsertPersonalBest(
            swimmerId: swimmerId,
            distance: set.distance ?? 0,
            stroke: set.stroke ?? "Free",
            timeMs: timeMs,
            gear: gear,
            intensity: intensity
        )
    }

    /// Fetch archived swimmers for the coach.
    func fetchArchivedSwimmers(coachId: String) async throws -> [Swimmer] {
        let response = try await supabase.from("swimmers")
            .select()
            .eq("coach_id", value: coachId)
            .filter("archived_at", operator: "neq", value: "null")
            .order("first_name", ascending: true)
            .execute()
        return try JSONDecoder().decode([Swimmer].self, from: response.data)
    }

    /// Permanently delete a swimmer.
    func deleteSwimmer(swimmerId: String) async throws {
        try await supabase.from("swimmers")
            .delete()
            .eq("id", value: swimmerId)
            .execute()
    }

    /// Restore (unarchive) a swimmer.
    func unarchiveSwimmer(swimmerId: String) async throws -> Swimmer {
        struct UnarchivePayload: Encodable {
            let archivedAt: String?
        }
        let response = try await supabase.from("swimmers")
            .update(UnarchivePayload(archivedAt: nil))
            .eq("id", value: swimmerId)
            .select()
            .single()
            .execute()
        return try JSONDecoder().decode(Swimmer.self, from: response.data)
    }

    /// Fetch swimmer group memberships for a batch of swimmers.
    func fetchSwimmerGroupIds(swimmerId: String) async throws -> [String] {
        let response = try await supabase.from("swimmer_groups")
            .select("group_id")
            .eq("swimmer_id", value: swimmerId)
            .execute()
        struct Row: Codable { let groupId: String; enum CodingKeys: String, CodingKey { case groupId = "group_id" } }
        let rows = try JSONDecoder().decode([Row].self, from: response.data)
        return rows.map { $0.groupId }
    }

    /// Fetch swimmer group memberships for a batch of swimmers (batched query).
    func fetchSwimmerGroupMemberships(swimmerIds: [String]) async throws -> [(swimmerId: String, groupId: String)] {
        if swimmerIds.isEmpty { return [] }
        let response = try await supabase.from("swimmer_groups")
            .select("swimmer_id, group_id")
            .in("swimmer_id", values: swimmerIds)
            .execute()
        struct Raw: Codable {
            let swimmerId: String
            let groupId: String
            enum CodingKeys: String, CodingKey {
                case swimmerId = "swimmer_id"
                case groupId = "group_id"
            }
        }
        let rows = try JSONDecoder().decode([Raw].self, from: response.data)
        return rows.map { ($0.swimmerId, $0.groupId) }
    }

    /// Replace a swimmer's group assignments (used after editing group membership).
    func setSwimmerGroups(swimmerId: String, groupIds: [String]) async throws {
        try await supabase.from("swimmer_groups")
            .delete()
            .eq("swimmer_id", value: swimmerId)
            .execute()
        for groupId in groupIds {
            try await supabase.from("swimmer_groups")
                .insert(["swimmer_id": swimmerId, "group_id": groupId])
                .execute()
        }
    }

    /// Delete a group by ID.
    func deleteGroup(groupId: String) async throws {
        try await supabase.from("groups")
            .delete()
            .eq("id", value: groupId)
            .execute()
    }

    /// Delete a personal best record.
    func deletePersonalBest(pbId: String) async throws {
        try await supabase.from("swimmer_pbs")
            .delete()
            .eq("id", value: pbId)
            .execute()
    }

    /// Fetch recorded_times for a list of swimmerIds.
    /// Used by the v2 3-layer HistoricalTimePredictor (Layer 1: recorded stats).
    /// Returns the last 20 entries per swimmer ordered by created_at DESC
    /// — the predictor only needs the last 5 for the mean (with a
    /// 20-row headroom for the stddev sample).
    func fetchRecordedTimes(
        swimmerIds: [String],
        limit: Int = 20
    ) async throws -> [RecordedTime] {
        guard !swimmerIds.isEmpty else { return [] }
        let response = try await supabase.from("recorded_times")
            .select()
            .in("swimmer_id", values: swimmerIds)
            .order("created_at", ascending: false)
            .limit(limit * swimmerIds.count)   // Supabase limit is per-query, not per-id
            .execute()
        return try JSONDecoder().decode([RecordedTime].self, from: response.data)
    }
}