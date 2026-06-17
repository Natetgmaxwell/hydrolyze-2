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
        /// PHASE 2.6 v1.13.0: the predictor's predicted time for this
        /// swimmer + set, in wave-relative ms. Used by the row UI
        /// to show a "variance hint" when confidence is low —
        /// "predicted X, actual Y, Zσ off" — so the coach can see
        /// WHY the pairing is flagged.
        var predictedTimeMs: Int?

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

            // PHASE 2.6 v1.15.1: BUGFIX. The v1.6 code keyed
            // swimmerWaveInfo by swimmerId only, which OVERWROTE the
            // entry for each swimmer as we iterated through all
            // wave_assignments. When a workout has multiple sets
            // (e.g., 50m @ T2 warmup + 100m @ T4 main), the last
            // set's prediction would win, not the one the
            // recorded_time actually belongs to. Result: the
            // variance hint in SessionReviewView showed wildly
            // wrong predictions (e.g., 64.5s for a 50m swim).
            //
            // Fix: key by (swimmerId, workoutSetId) so the
            // recorded_time can look up its OWN set's prediction.
            // When building the row, look up by both the swimmer
            // AND the recorded_time's workoutSetId.
            var swimmerWaveInfo: [String: (lane: Int, wave: Int, predicted: Int, sendOff: Int)] = [:]
            var waveInfoBySet: [String: [String: (lane: Int, wave: Int, predicted: Int, sendOff: Int)]] = [:]
            for wa in waveAssignments {
                let info = (wa.lane, wa.waveNumber, wa.predictedTouchMs, wa.sendOffOffsetMs)
                swimmerWaveInfo[wa.swimmerId] = info
                if let wid = wa.workoutSetId {
                    waveInfoBySet[wid, default: [:]][wa.swimmerId] = info
                }
            }

            rows = times.map { rt in
                let targetId = rt.pairedSwimmerId ?? rt.swimmerId ?? ""
                let conf = rt.confidence ?? 0

                // PHASE 2.6 v1.15.1: BUGFIX. Look up wave_assignment by
                // (workoutSetId, swimmerId) FIRST, fall back to
                // swimmerId-only lookup. The swimmerId-only lookup
                // was wrong for workouts with multiple sets (it
                // returned the LAST set's prediction regardless of
                // which set the recorded_time belonged to).
                //
                // PHASE 2.6 v1.15.2: use nested `if let` instead of
                // comma-separated `if !setId.isEmpty, let setInfo = ...`
                // — Swift's parser was binding `setId` (String, not
                // Optional) instead of `setInfo`, causing a build
                // error: "Initializer for conditional binding must
                // have Optional type, not 'String'".
                let setId = rt.workoutSetId ?? ""
                let info: (lane: Int, wave: Int, predicted: Int, sendOff: Int)?
                if !setId.isEmpty {
                    if let setInfo = waveInfoBySet[setId]?[targetId] {
                        info = setInfo
                    } else {
                        info = swimmerWaveInfo[targetId]
                    }
                } else {
                    info = swimmerWaveInfo[targetId]
                }
                // is the absolute touch time (sendOff + swim); subtract
                // sendOff to get the wave-relative swim time, which
                // matches rt.timeMs (also wave-relative).
                let predicted: Int? = info.map { i in
                    max(0, i.predicted - i.sendOff)
                }

                print("[Review] Processing row \(rt.id), swimmer \(targetId), confidence \(conf), predicted=\(predicted ?? -1)")

                return ReviewRow(
                    id: rt.id,
                    recordedTime: rt,
                    swimmerName: swimmerNames[targetId] ?? "Unknown",
                    lane: info?.lane,
                    wave: info?.wave,
                    confidence: conf,
                    predictedTimeMs: predicted
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

    /// PHASE 2.6 v1.13.1: coach entrypoint for "this swim was actually
    /// at a different intensity". Per the user's principle: each
    /// swimmer may have unofficial PB at specific combos of
    /// (stroke, distance, intensity, gear). The coach can now
    /// teach the engine about a new PB: when a row's confidence
    /// is low, the coach can mark the actual intensity and the
    /// lap time becomes a coach-confirmed PB at that intensity.
    ///
    /// Example: Fiona's row comes back at 0% confidence with
    /// actual time 39.6s. The coach knows Fiona was swimming at
    /// "easy" intensity (not "moderate" as the set said). They
    /// mark the row as easy, and the engine writes a new PB:
    /// Fiona 50 Free @ easy = 39.6s. The next session uses
    /// THIS PB for Fiona's easy predictions instead of the
    /// generic 1.20x race PB.
    ///
    /// This closes the data flywheel loop: the coach's manual
    /// judgment feeds back into the predictor, which reduces
    /// future "needs review" rows.
    ///
    /// For v1.13.1, the workoutSet is passed in by the caller
    /// (the SessionReviewView loads it from the row's
    /// workoutSetId). Hardcoded 50m Free support: this function
    /// is built for the current 50m Free test scenario. v1.14
    /// will generalize to arbitrary stroke/distance.
    func markRowIntensity(
        timeId: UUID,
        swimmerId: String,
        intensity: String,
        lapTimeMs: Int,
        gear: String?,
        workoutSet: WorkoutSet
    ) async {
        do {
            let swimmerService = SwimmerService()
            let pb = try await swimmerService.upsertPersonalBest(
                swimmerId: swimmerId,
                distance: workoutSet.distance ?? 0,
                stroke: workoutSet.stroke ?? "Free",
                timeMs: lapTimeMs,
                gear: gear,
                intensity: intensity
            )
            print("[Review] markRowIntensity: wrote coach-confirmed PB — \(swimmerId.prefix(8))… 50 Free @ \(intensity) @ \(gear ?? "none") = \(lapTimeMs)ms (PB id=\(pb.id.prefix(8))…)")
            // Mark the row as coach-accepted. The confidence
            // still shows the original low value (so the coach
            // remembers this was uncertain), but the row gets
            // the cyan thumbs-up icon to indicate "I've reviewed this."
            // PHASE 2.6 v1.15.2: replaced `if let idx = rows.firstIndex(...)`
            // with a `contains` check — the `idx` was never used inside
            // the block. Simpler and silences the "idx defined but
            // never used" warning.
            if rows.contains(where: { $0.id == timeId.uuidString }) {
                coachConfirmedRowIds.insert(timeId.uuidString)
            }
        } catch {
            errorMessage = "Couldn't save coach-confirmed PB: \(error.localizedDescription)"
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