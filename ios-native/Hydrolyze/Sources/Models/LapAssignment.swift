import Foundation

/// LapAssignment — in-memory pairing algorithm output, not persisted directly.
/// Produced by PairingEngine.pair(...) and consumed by TimingService during
/// the save flow (which writes the pairings to recorded_times).
///
/// PHASE 2.6 v1.17.0: clarification on the data flow vs. the review flow.
///
/// Two paths exist for getting pairings from the engine into the DB:
///
/// 1. **Timing flow (real-time, during a swim session):**
///    PairingEngine.pair() → [LapAssignment] → TimingService.save() →
///    INSERT into recorded_times (with paired_swimmer_id, confidence).
///    LapAssignment is the wire format between the engine and the
///    save path. The review flow does NOT see LapAssignment; by the
///    time the user opens the review screen, the pairings are
///    already persisted in recorded_times.
///
/// 2. **Review flow (post-session, this is the SessionReviewView path):**
///    SessionReviewViewModel.load() → SELECT FROM recorded_times →
///    decode to [RecordedTime] → build [ReviewRow] (joins wave_assignments
///    for lane/wave, joins workout_sets for distance, fetches
///    swimmers for names). The engine is NOT in this path; the
///    review flow trusts the persisted pairings.
///
/// So LapAssignment is the engine's output type for the timing
/// flow. It's not vestigial — removing it would require
/// rewriting the TimingService save path. The review flow's
/// decision to read from the DB instead of from the engine
/// is the design choice that makes LapAssignment invisible to
/// the review UI. Keep it.
struct LapAssignment: Identifiable, Hashable {
    let id: String
    let lap: Lap
    var swimmerId: UUID
    var confidence: Int
    var confidenceLevel: ConfidenceLevel
    var workoutSetId: String?
    var waveNumber: Int

    enum ConfidenceLevel: String, CaseIterable {
        case green
        case amber
        case red

        init(from confidence: Int) {
            if confidence >= 80 {
                self = .green
            } else if confidence >= 50 {
                self = .amber
            } else {
                self = .red
            }
        }
    }

    init(id: String, lap: Lap, swimmerId: UUID, confidence: Int, workoutSetId: String?, waveNumber: Int) {
        self.id = id
        self.lap = lap
        self.swimmerId = swimmerId
        self.confidence = confidence
        self.confidenceLevel = ConfidenceLevel(from: confidence)
        self.workoutSetId = workoutSetId
        self.waveNumber = waveNumber
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: LapAssignment, rhs: LapAssignment) -> Bool {
        lhs.id == rhs.id
    }
}