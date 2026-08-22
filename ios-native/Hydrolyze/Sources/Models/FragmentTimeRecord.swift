import Foundation

/// V0.48 Slice 1 (2026-08-22) — fragment-time record with owner attribution.
///
/// One element per (swimmer, fragment, pass) tuple. A 2×-through set with
/// two swimmers yields up to four records per fragment. The record carries
/// the swimmer name only when one is known: rows persisted before the
/// pairing engine resolves a tentative owner — or rows the engine
/// explicitly leaves unattributed (solo runs) — render with `swimmerName:
/// nil` and the chip falls back to the unowned "Saved M:SS.HH" form.
///
/// `capturedAt` orders the bucket oldest→newest when the load path needs
/// to sort, and lets the sheet (Slice 2) render chronological groupings
/// without re-querying the DB.
struct FragmentTimeRecord: Codable, Sendable, Hashable, Identifiable {
    /// nil = unattributed (solo, pre-pair, or engine-declined). Renderer
    /// falls back to "Saved M:SS.HH" with no name prefix.
    let swimmerName: String?
    let timeMs: Int
    let capturedAt: Date

    /// Stable identity for `ForEach` — the timestamp + millisecond is
    /// unique within a fragment bucket (the stopwatch never emits two
    /// captures in the same centisecond).
    var id: String { "\(Int(capturedAt.timeIntervalSince1970 * 1000))-\(timeMs)" }

    /// Owned vs. unowned. Cheap inline check used by the chip renderer
    /// to decide whether to prefix the name.
    var hasOwner: Bool {
        guard let name = swimmerName else { return false }
        return !name.isEmpty
    }
}