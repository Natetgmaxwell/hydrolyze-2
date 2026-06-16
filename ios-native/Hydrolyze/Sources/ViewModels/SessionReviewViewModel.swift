import SwiftUI
import Supabase

/// SessionReviewViewModel — drives the post-timing review screen.
/// Loads recorded_times for the session, exposes filter state,
/// and handles coach reassignment + confirm-all.
@MainActor
final class SessionReviewViewModel: ObservableObject {

    enum Filter: String, CaseIterable {
        case all = "All"
        case needsReview = "Needs Review"
    }

    struct ReviewRow: Identifiable {
        let id: String
        let recordedTime: RecordedTime
        var swimmerName: String
        var lane: Int?
        var wave: Int?
        var confidence: Int

        var confidenceLevel: RowConfidence {
            if confidence >= 80 { return .green }
            else if confidence >= 50 { return .amber }
            else { return .red }
        }

        enum RowConfidence {
            case green, amber, red

            var color: Color {
                switch self {
                case .green: return Color.green
                case .amber: return Color.orange
                case .red: return Color.red
                }
            }

            var backgroundColor: Color {
                color.opacity(0.15)
            }
        }
    }

    @Published var filter: Filter = .needsReview
    @Published var rows: [ReviewRow] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var showReassignSheet: Bool = false
    @Published var selectedRow: ReviewRow?
    @Published var showConfirmWarning: Bool = false

    private let supabase = SupabaseService.shared.client
    private var sessionId: String?

    var filteredRows: [ReviewRow] {
        switch filter {
        case .all:
            return rows
        case .needsReview:
            return rows.filter { $0.confidence < 80 }
        }
    }

    var unconfirmedCount: Int {
        rows.filter { $0.confidence < 50 }.count
    }

    var canConfirmAll: Bool {
        unconfirmedCount == 0
    }

    /// Track rows the coach has explicitly accepted despite low confidence.
    /// The pairing engine isn't perfect — sometimes the best assignment is
    /// still 30% confidence, and the coach wants to proceed. Without this,
    /// the user is stuck unable to confirm any session with low-confidence
    /// rows.
    @Published var coachConfirmedRowIds: Set<String> = []

    /// `unconfirmedCount` minus the rows the coach has explicitly accepted.
    /// A row is "effectively confirmed" if either:
    ///   - its confidence is high enough (>= 50), OR
    ///   - the coach has tapped "Accept this pairing" on it.
    var effectiveUnconfirmedCount: Int {
        rows.filter { row in
            row.confidence < 50 && !coachConfirmedRowIds.contains(row.id)
        }.count
    }

    /// Mark a row as coach-confirmed despite low confidence. Removes it
    /// from `effectiveUnconfirmedCount` so the Confirm All button enables.
    func acceptLowConfidenceRow(_ rowId: String) {
        coachConfirmedRowIds.insert(rowId)
    }

    func load(sessionId: String) async {
        self.sessionId = sessionId
        isLoading = true
        errorMessage = nil

        do {
            // PARALLEL FETCH (Phase 2.5-c performance): recorded_times and
            // wave_assignments are both filtered by sessionId and don't depend
            // on each other. Firing both concurrently cuts the review-page
            // load from sum(t_times + t_waves) to max(t_times, t_waves).
            // The swimmers lookup is done after we know which ids we need.
            //
            // We need `try await` on the .data access (not just on the
            // call) — an `async let` doesn't make the resulting value's
            // properties implicitly awaitable. Awaiting the async let
            // unwraps the PostgrestResponse; the .data property is then
            // safe to read synchronously.
            async let timesResponseTask = supabase.from("recorded_times")
                .select()
                .eq("session_id", value: sessionId)
                .order("lap_order", ascending: true)
                .execute()
            async let waveResponseTask = supabase.from("wave_assignments")
                .select()
                .eq("session_id", value: sessionId)
                .execute()

            let timesResponse = try await timesResponseTask
            let waveResponse = try await waveResponseTask
            let rawTimes = try JSONDecoder().decode([RecordedTime].self, from: timesResponse.data)

            // Dedupe by id — same defensive pattern as the wave-preview fix (commit a322a73).
            // If a session was timed twice through the stopwatch, or test data was seeded
            // redundantly, the same `recorded_times.id` can appear more than once. First
            // occurrence wins so the review list shows one row per lap, not duplicates.
            var seen = Set<String>()
            let times = rawTimes.filter { rt in
                let (inserted, _) = seen.insert(rt.id)
                return inserted
            }

            let waveAssignments = try JSONDecoder().decode([WaveAssignment].self, from: waveResponse.data)

            let swimmerIds = Array(Set(times.compactMap { $0.pairedSwimmerId ?? $0.swimmerId }))
            var swimmerNames: [String: String] = [:]
            if !swimmerIds.isEmpty {
                let swimmersResponse = try await supabase.from("swimmers")
                    .select("id, first_name, last_name")
                    .in("id", values: swimmerIds)
                    .execute()

                struct RawSwimmer: Codable {
                    let id: String
                    let firstName: String
                    let lastName: String?
                    enum CodingKeys: String, CodingKey {
                        case id
                        case firstName = "first_name"
                        case lastName = "last_name"
                    }
                }
                let swimmerRows = try JSONDecoder().decode([RawSwimmer].self, from: swimmersResponse.data)
                for sr in swimmerRows {
                    let full = sr.lastName?.isEmpty == false ? "\(sr.firstName) \(sr.lastName!)" : sr.firstName
                    swimmerNames[sr.id] = full
                }
            }

            var swimmerWaveInfo: [String: (lane: Int, wave: Int)] = [:]
            for wa in waveAssignments {
                swimmerWaveInfo[wa.swimmerId] = (wa.lane, wa.waveNumber)
            }

            rows = times.map { rt in
                let targetId = rt.pairedSwimmerId ?? rt.swimmerId ?? ""
                let info = swimmerWaveInfo[targetId]
                let conf = rt.confidence ?? 0
                
                print("[Review] Processing row \(rt.id), swimmer \(targetId), confidence \(conf)")
                
                return ReviewRow(
                    id: rt.id,
                    recordedTime: rt,
                    swimmerName: swimmerNames[targetId] ?? "Unknown",
                    lane: info?.lane,
                    wave: info?.wave,
                    confidence: conf
                )
            }

        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func reassign(timeId: UUID, toSwimmerId: UUID) async {
        do {
            struct Update: Encodable {
                let pairedSwimmerId: String
                let confidence: Double
            }
            let payload = Update(
                pairedSwimmerId: toSwimmerId.uuidString,
                confidence: 1.0
            )

            try await supabase.from("recorded_times")
                .update(payload)
                .eq("id", value: timeId.uuidString)
                .execute()

            if let idx = rows.firstIndex(where: { $0.id == timeId.uuidString }) {
                rows[idx].confidence = 100
                rows[idx].swimmerName = toSwimmerId.uuidString
            }

        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func confirmAll(force: Bool = false) async {
        let unresolved = effectiveUnconfirmedCount
        if unresolved > 0 && !force {
            // Show the warning. The user can either:
            //   - Go back and reassign the low-confidence rows
            //   - Tap "Confirm Anyway" to force through (sets force=true)
            showConfirmWarning = true
            return
        }
        guard let sessionId = sessionId else { return }

        do {
            struct SessionUpdate: Encodable {
                let reviewedAt: String
            }
            try await supabase.from("sessions")
                .update(SessionUpdate(reviewedAt: ISO8601DateFormatter().string(from: Date())))
                .eq("id", value: sessionId)
                .execute()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}