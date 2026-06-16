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
        }
        let payload = CreatePayload(
            coachId: coachId,
            firstName: firstName,
            lastName: lastName,
            birthdate: birthdate,
            gender: gender
        )
        let response = try await supabase.from("swimmers")
            .insert(payload)
            .select()
            .single()
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

    /// Create a new group.
    func createGroup(coachId: String, name: String) async throws -> CoachGroup {
        struct CreateGroupPayload: Encodable {
            let coachId: String
            let name: String
        }
        let payload = CreateGroupPayload(coachId: coachId, name: name)
        let response = try await supabase.from("groups")
            .insert(payload)
            .select()
            .single()
            .execute()
        return try JSONDecoder().decode(CoachGroup.self, from: response.data)
    }

    /// Assign a swimmer to a group.
    func assignSwimmerToGroup(swimmerId: String, groupId: String) async throws {
        struct AssignPayload: Encodable {
            let swimmerId: String
            let groupId: String
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

    /// Upsert a personal best (insert or update if already exists for distance+stroke+gear).
    func upsertPersonalBest(swimmerId: String, distance: Int, stroke: String, timeMs: Int, gear: String?) async throws -> SwimmerPB {
        struct UpsertPayload: Encodable {
            let swimmerId: String
            let distance: Int
            let stroke: String
            let timeMs: Int
            let gear: String?
            let recordedAt: String
        }
        let payload = UpsertPayload(
            swimmerId: swimmerId,
            distance: distance,
            stroke: stroke,
            timeMs: timeMs,
            gear: gear,
            recordedAt: ISO8601DateFormatter().string(from: Date())
        )
        let response = try await supabase.from("swimmer_pbs")
            .upsert(payload)
            .select()
            .single()
            .execute()
        return try JSONDecoder().decode(SwimmerPB.self, from: response.data)
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