import Foundation

// v1.17 Slice 2 — the standing-schedule layer.
//
// Two tables, one concept: the coach declares which sessions the squad
// OFFERS (`squad_session_slot`), and each swimmer declares which of those
// they NORMALLY attend (`swimmer_training_schedule`). The swimmer's pattern
// is a subset of the squad's — never free-form — so nobody can mark
// themselves in for a Sunday PM the squad has never trained.
//
// This is what makes attendance zero-tap in steady state. The swimmer says
// "Mon/Wed/Fri AM" once at signup and only opens the app to deviate.
//
// See plans/attendance-intent-loop-design-spec.md §4.2a / §4.2b.

/// Day of the week, 0 = Sunday.
///
/// Chosen to match Foundation's `Calendar.component(.weekday,...)` minus 1,
/// so converting a workout's `scheduled_at` DATE to a slot is one
/// subtraction with no lookup table and no locale surprises. Postgres
/// `EXTRACT(DOW FROM date)` uses the same 0=Sunday convention, so the value
/// means the same thing on both sides of the wire.
enum Weekday: Int, CaseIterable, Codable, Hashable, Sendable {
    case sunday = 0, monday, tuesday, wednesday, thursday, friday, saturday

    /// Derive the weekday of a date in the current calendar.
    init(date: Date, calendar: Calendar = .current) {
        let raw = calendar.component(.weekday, from: date) - 1
        self = Weekday(rawValue: raw) ?? .sunday
    }

    /// Three-letter label for the schedule grid ("Mon", "Tue", ...).
    var shortLabel: String {
        switch self {
        case .sunday:    return "Sun"
        case .monday:    return "Mon"
        case .tuesday:   return "Tue"
        case .wednesday: return "Wed"
        case .thursday:  return "Thu"
        case .friday:    return "Fri"
        case .saturday:  return "Sat"
        }
    }

    /// Monday-first position (Mon = 0 … Sun = 6). Coaches read a week as
    /// Mon→Sun; 0=Sunday stays the storage convention. Arithmetic, not an
    /// array lookup, so it's usable inside a sort comparator.
    var displayIndex: Int { (rawValue + 6) % 7 }

    /// Monday-first ordering for UI grids.
    static var displayOrder: [Weekday] {
        allCases.sorted { $0.displayIndex < $1.displayIndex }
    }
}

/// AM or PM. Mirrors `workouts.am_pm`, which is the existing (and only)
/// time-of-day granularity in the schema. Deliberately NOT a clock time —
/// a squad trains "Tuesday morning", not "Tuesday 05:30", and the actual
/// workout row carries the real date anyway.
enum SessionSlot: String, CaseIterable, Codable, Hashable, Sendable {
    case am = "AM"
    case pm = "PM"

    var label: String { self == .am ? "AM" : "PM" }
}

/// A session the squad offers — the coach's weekly template.
///
/// Distinct from `workouts`, which are the actual dated instances the coach
/// schedules and parses. This is "we train Mon/Wed/Fri mornings"; a workout
/// is "here is Wednesday the 29th's set".
struct SquadSessionSlot: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let groupId: String
    let weekday: Int
    let amPm: String
    let label: String?
    let active: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case groupId = "group_id"
        case weekday
        case amPm = "am_pm"
        case label
        case active
    }

    var day: Weekday { Weekday(rawValue: weekday) ?? .sunday }
    var slot: SessionSlot { SessionSlot(rawValue: amPm) ?? .am }

    /// "Mon AM" — or the coach's own label when they've named the session
    /// ("Distance", "Sprint"). Used as the grid cell caption.
    var displayName: String {
        if let label, !label.isEmpty { return label }
        return "\(day.shortLabel) \(slot.label)"
    }
}

/// One slot the swimmer normally attends. Mon/Wed/Fri AM = three rows.
///
/// `active` allows a soft pause (injury, off-season) without destroying the
/// pattern — the swimmer flips it back on when they return rather than
/// re-entering their whole week.
struct SwimmerTrainingSchedule: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let swimmerId: String
    let weekday: Int
    let amPm: String
    let active: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case swimmerId = "swimmer_id"
        case weekday
        case amPm = "am_pm"
        case active
    }

    var day: Weekday { Weekday(rawValue: weekday) ?? .sunday }
    var slot: SessionSlot { SessionSlot(rawValue: amPm) ?? .am }

    /// Does this standing slot cover the given (weekday, am_pm) pair?
    ///
    /// A nil `amPm` on the workout matches ANY slot for that weekday: the
    /// coach didn't specify a session, so we don't hold the swimmer to one.
    /// Inactive rows never match.
    func matches(weekday: Weekday, amPm: SessionSlot?) -> Bool {
        guard active, day == weekday else { return false }
        guard let amPm else { return true }
        return slot == amPm
    }
}
