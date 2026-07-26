import Foundation

/// ScheduleService — reads the squad's offered sessions and reads/writes a
/// swimmer's standing weekly pattern.
///
/// v1.17 Slice 2. Two tables, one service, because they're always used
/// together: the grid the swimmer taps IS the squad's slot list, and what
/// they tap becomes their schedule rows.
///
/// Callers pass IDs explicitly rather than the service reaching into
/// `AuthManager` — AuthManager is `@MainActor`-isolated and this service is
/// not, so touching it here would force every call onto the main actor for
/// no reason. The view model already holds `swimmerId`; it passes it down.
///
/// RLS does the real enforcement (a swimmer can only write their own rows,
/// and only read slots for squads they belong to), so these methods are
/// deliberately thin. See migrations 20260726000001 / 20260726000002.
final class ScheduleService {
    private let client = SupabaseService.shared.client

    // MARK: - Squad slots (coach-defined, swimmer reads)

    /// The sessions a squad offers, in Monday-first display order.
    ///
    /// Inactive slots are filtered server-side: a slot the coach has turned
    /// off should not appear in the swimmer's grid at all.
    func fetchSquadSlots(groupId: String) async throws -> [SquadSessionSlot] {
        let response = try await client
            .from("squad_session_slot")
            .select("id, group_id, weekday, am_pm, label, active")
            .eq("group_id", value: groupId)
            .eq("active", value: true)
            .execute()
        let slots = try JSONDecoder().decode([SquadSessionSlot].self, from: response.data)
        return slots.sorted { $0.sortKey < $1.sortKey }
    }

    /// Every slot across every squad the swimmer belongs to.
    ///
    /// A swimmer in one squad (the common case) gets that squad's slots. A
    /// swimmer in two squads gets the union — they train with both, so both
    /// sets of sessions are legitimately available to them. RLS already
    /// restricts this to squads they're a member of, so no group filter is
    /// needed on the client.
    func fetchSlotsForSwimmer() async throws -> [SquadSessionSlot] {
        let response = try await client
            .from("squad_session_slot")
            .select("id, group_id, weekday, am_pm, label, active")
            .eq("active", value: true)
            .execute()
        let slots = try JSONDecoder().decode([SquadSessionSlot].self, from: response.data)
        return slots.sorted { $0.sortKey < $1.sortKey }
    }

    // MARK: - Swimmer standing schedule

    /// The swimmer's standing weekly pattern.
    ///
    /// Returns inactive rows too — a paused slot is still part of the
    /// pattern, and the grid renders it differently rather than hiding it.
    /// Callers that want only live slots filter on `active`.
    func fetchSchedule(swimmerId: String) async throws -> [SwimmerTrainingSchedule] {
        let response = try await client
            .from("swimmer_training_schedule")
            .select("id, swimmer_id, weekday, am_pm, active")
            .eq("swimmer_id", value: swimmerId)
            .execute()
        let rows = try JSONDecoder().decode([SwimmerTrainingSchedule].self, from: response.data)
        return rows.sorted { $0.sortKey < $1.sortKey }
    }

    /// Add one standing slot. Idempotent via the (swimmer, weekday, am_pm)
    /// unique key — tapping an already-on cell re-activates it rather than
    /// erroring, which is what makes the pause/resume flow work.
    func addSlot(swimmerId: String, weekday: Weekday, amPm: SessionSlot) async throws {
        struct Payload: Encodable {
            let swimmer_id: String
            let weekday: Int
            let am_pm: String
            let active: Bool
        }
        let payload = Payload(
            swimmer_id: swimmerId,
            weekday: weekday.rawValue,
            am_pm: amPm.rawValue,
            active: true
        )
        _ = try await client
            .from("swimmer_training_schedule")
            .upsert(payload, onConflict: "swimmer_id,weekday,am_pm")
            .execute()
    }

    /// Remove one standing slot outright.
    ///
    /// Distinct from `setSlotActive(false)`: removing means "this is not part
    /// of my week", pausing means "it is, but not right now". The grid uses
    /// remove; a future off-season toggle would use pause.
    func removeSlot(swimmerId: String, weekday: Weekday, amPm: SessionSlot) async throws {
        _ = try await client
            .from("swimmer_training_schedule")
            .delete()
            .eq("swimmer_id", value: swimmerId)
            .eq("weekday", value: weekday.rawValue)
            .eq("am_pm", value: amPm.rawValue)
            .execute()
    }

    /// Pause or resume a standing slot without losing it.
    func setSlotActive(
        swimmerId: String,
        weekday: Weekday,
        amPm: SessionSlot,
        active: Bool
    ) async throws {
        struct Patch: Encodable { let active: Bool }
        _ = try await client
            .from("swimmer_training_schedule")
            .update(Patch(active: active))
            .eq("swimmer_id", value: swimmerId)
            .eq("weekday", value: weekday.rawValue)
            .eq("am_pm", value: amPm.rawValue)
            .execute()
    }

    /// Replace the swimmer's whole pattern in one call.
    ///
    /// Used by the first-run grid (§10), where the swimmer taps several
    /// cells and hits Done once. Delete-then-insert rather than diffing:
    /// the row count is single digits, and a diff would be more code than
    /// it saves. Not wrapped in a transaction — a partial failure leaves
    /// the swimmer with a shorter pattern, which the grid shows them
    /// immediately on reload, so it's self-correcting rather than silent.
    func replaceSchedule(
        swimmerId: String,
        slots: [(weekday: Weekday, amPm: SessionSlot)]
    ) async throws {
        _ = try await client
            .from("swimmer_training_schedule")
            .delete()
            .eq("swimmer_id", value: swimmerId)
            .execute()

        guard !slots.isEmpty else { return }

        struct Payload: Encodable {
            let swimmer_id: String
            let weekday: Int
            let am_pm: String
            let active: Bool
        }
        let payloads = slots.map {
            Payload(
                swimmer_id: swimmerId,
                weekday: $0.weekday.rawValue,
                am_pm: $0.amPm.rawValue,
                active: true
            )
        }
        _ = try await client
            .from("swimmer_training_schedule")
            .insert(payloads)
            .execute()
    }

    /// True when the swimmer has never set a pattern — the first-run trigger.
    func hasSchedule(swimmerId: String) async throws -> Bool {
        try await !fetchSchedule(swimmerId: swimmerId).isEmpty
    }

    // MARK: - Coach-side squad slots (v1.17 Slice 7)

    /// The squad's offered sessions, INCLUDING inactive ones. The coach
    /// editor shows inactive slots (greyed, removable) so the view
    /// matches what's in the DB rather than silently dropping rows.
    func fetchAllSquadSlots(groupId: String) async throws -> [SquadSessionSlot] {
        let response = try await client
            .from("squad_session_slot")
            .select("id, group_id, weekday, am_pm, label, active")
            .eq("group_id", value: groupId)
            .execute()
        let slots = try JSONDecoder().decode([SquadSessionSlot].self, from: response.data)
        return slots.sorted { $0.sortKey < $1.sortKey }
    }

    /// Add or re-activate one squad slot. Idempotent on the unique key.
    func setSquadSlot(groupId: String, weekday: Weekday, amPm: SessionSlot,
                       label: String?, active: Bool) async throws {
        struct Payload: Encodable {
            let group_id: String
            let weekday: Int
            let am_pm: String
            let label: String?
            let active: Bool
        }
        // Empty string label -> nil, so a cleared label acts as a real
        // delete rather than a no-op insert of ''.
        let payload = Payload(
            group_id: groupId,
            weekday: weekday.rawValue,
            am_pm: amPm.rawValue,
            label: label?.isEmpty == true ? nil : label,
            active: active
        )
        _ = try await client
            .from("squad_session_slot")
            .upsert(payload, onConflict: "group_id,weekday,am_pm")
            .execute()
    }

    /// Soft-disable a squad slot. Active=false hides it from swimmer UIs
    /// without losing the row — a coach can reactivate later.
    func setSquadSlotActive(slotId: String, active: Bool) async throws {
        struct Patch: Encodable { let active: Bool }
        _ = try await client
            .from("squad_session_slot")
            .update(Patch(active: active))
            .eq("id", value: slotId)
            .execute()
    }

    /// Permanently remove a squad slot. No undo.
    func deleteSquadSlot(slotId: String) async throws {
        _ = try await client
            .from("squad_session_slot")
            .delete()
            .eq("id", value: slotId)
            .execute()
    }

    /// Patch the squad's settings jsonb. v1.17 Slice 7 key: visibility.
    func updateGroupSettings(groupId: String, settings: CoachGroup.Settings) async throws {
        struct Patch: Encodable { let settings: CoachGroup.Settings }
        _ = try await client
            .from("groups")
            .update(Patch(settings: settings))
            .eq("id", value: groupId)
            .execute()
    }
}

/// Monday-first, AM before PM — the one ordering the grid and the schedule
/// list both use. A protocol rather than a free function so the sort reads
/// as `sorted { $0.sortKey < $1.sortKey }` at every call site.
protocol WeekdaySlotOrderable {
    var day: Weekday { get }
    var slot: SessionSlot { get }
}

extension WeekdaySlotOrderable {
    var sortKey: (Int, Int) { (day.displayIndex, slot == .am ? 0 : 1) }
}

extension SquadSessionSlot: WeekdaySlotOrderable {}
extension SwimmerTrainingSchedule: WeekdaySlotOrderable {}
