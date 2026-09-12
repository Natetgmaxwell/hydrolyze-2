import Foundation

/// PBService — the SINGLE function for "what's this swimmer's predicted
/// time for this set?"
///
/// Phase 1 (T3.5, 2026-06-20): this is now a thin wrapper around
/// `HistoricalTimePredictor.predict()`. The predictor covers all
/// 3 layers (recorded stats, PB curve, population seed) and applies
/// the suit + start calibration (T3/T4). PBService is kept as the
/// public API surface for the callers (`SessionStartViewModel`,
/// `TimingViewModel`) — they invoke it the same way they did in
/// v1.13.0, with the addition of a `calibration: CalibrationFactors`
/// parameter.
///
/// The historical `intensity` and `gear` parameters are preserved
/// for API stability with v1.13.0 callers but are now ignored — the
/// predictor reads `intensity` and `gear` from the set's
/// `intensityLabel` and `gear` fields. Callers should pass `nil`
/// for both and let the predictor read from the set.
///
/// Replaces 4 separate code paths (same as before):
///   - SwimmerService.fetchPersonalBests (for the profile screen)
///   - SessionStartViewModel.lockRoster (for the wave preview)
///   - TimingViewModel.save (v1.12, for the live predictor)
///   - coarsePredictions derived from wa.predictedTouchMs (fallback)
///
/// All four now call PBService.fetchPrediction(...) and get the same
/// `Prediction` for the same (swimmer, set) input. The coach can
/// trust that what the profile screen shows is what the engine uses.
struct PBService {
    /// The single function. Returns nil for IM (always manual).
    ///
    /// The caller is responsible for:
    ///   - Constructing a `CalibrationFactors` and calling
    ///     `prefetch(forSwimmerIds:)` on it before invoking this method
    ///   - Fetching all `recordedTimes` for the relevant swimmers
    ///     (filtered internally to the per-(swimmer, set) match)
    ///   - Fetching all `swimmer_pbs` for the relevant swimmers
    ///
    /// `intensity` and `gear` are deprecated. The predictor reads
    /// these from the set's `intensityLabel` and `gear` fields.
    /// Pass `nil` for both.
    func fetchPrediction(
        swimmer: Swimmer,
        set: WorkoutSet,
        intensity: String? = nil,      // deprecated; predictor reads from set.intensityLabel
        gear: String? = nil,           // deprecated; predictor reads from set.gear
        prefs: CoachPreferences,
        recordedTimes: [RecordedTime],
        pbs: [SwimmerPB],
        calibration: CalibrationFactors
    ) -> Prediction? {
        return HistoricalTimePredictor().predict(
            swimmer: swimmer,
            set: set,
            recordedTimes: recordedTimes,
            pbs: pbs,
            calibration: calibration,
            prefs: prefs
        )
    }
}
