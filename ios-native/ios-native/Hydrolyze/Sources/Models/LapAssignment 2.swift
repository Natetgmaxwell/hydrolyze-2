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
    /// PHASE 2.6 v1.17.0 (S4): the raw pairing probability as a
    /// Double in [0.0, 1.0], derived from the z-score via the
    /// standard Gaussian: `exp(-z²/2)`. Finer precision than the
    /// existing `confidence: Int` (which is bucketed 0-99 via
    /// `99 - z*15` and underlies the v1.14 review UI's 80/50
    /// thresholds).
    ///
    /// The two values are different views of the same z-score:
    ///   - confidence: Int       — bucketed, used by the review UI
    ///                            (the 80/50 auto/likelyCorrect/likelyWrong
    ///                            bands). Stable contract.
    ///   - assignmentConfidence: Double — Gaussian, for future
    ///                            work: analytics, calibration, or
    ///                            a future v1.18+ review UI that
    ///                            wants finer-grained bands.
    ///
    /// The Hungarian cost matrix is unchanged. The engine still
    /// picks the same assignments; we just emit a more precise
    /// confidence alongside the integer for downstream consumers.
    var assignmentConfidence: Double
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

    init(id: String, lap: Lap, swimmerId: UUID, confidence: Int,
         assignmentConfidence: Double, workoutSetId: String?, waveNumber: Int) {
        self.id = id
        self.lap = lap
        self.swimmerId = swimmerId
        self.confidence = confidence
        self.assignmentConfidence = assignmentConfidence
        self.confidenceLevel = ConfidenceLevel(from: confidence)
        self.workoutSetId = workoutSetId
        self.waveNumber = waveNumber
    }

    /// PHASE 2.6 v1.17.0 (S4): backward-compat init for callers
    /// that don't yet supply assignmentConfidence. Defaults to 0.0
    /// (the most conservative Gaussian value). The engine itself
    /// always supplies the computed Gaussian; this init exists
    /// for the missed-tap imputation path and any test code.
    init(id: String, lap: Lap, swimmerId: UUID, confidence: Int,
         workoutSetId: String?, waveNumber: Int) {
        self.init(id: id, lap: lap, swimmerId: swimmerId,
                  confidence: confidence, assignmentConfidence: 0.0,
                  workoutSetId: workoutSetId, waveNumber: waveNumber)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: LapAssignment, rhs: LapAssignment) -> Bool {
        lhs.id == rhs.id
    }
}