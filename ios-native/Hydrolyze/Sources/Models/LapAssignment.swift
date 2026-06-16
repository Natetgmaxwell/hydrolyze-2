import Foundation

/// LapAssignment — in-memory pairing algorithm output, not persisted directamente.
/// Produced by PairingEngine.pair(...) and consumed by SessionReviewViewModel.
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