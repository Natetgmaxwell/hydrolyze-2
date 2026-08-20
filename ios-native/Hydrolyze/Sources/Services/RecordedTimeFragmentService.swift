// Hydrolyze — RecordedTimeFragmentService + PairingHandoff
// (t_be09a643, 2026-08-05)
//
// Per-fragment persistence + the pairing-engine handoff that the spec
// asks for. Three responsibilities:
//
//  1. Save the stopwatch's recorded-time-with-fragment-metadata row
//     to `recorded_times`. All spec-required fields are populated:
//     set_id (workout_set_id), fragment_id, swimmer_id (nullable;
//     set by pairing), recorded_ms (time_ms), distance_meters,
//     intensity, start_type, pace_target_sec, raw_text, created_at.
//     The migration `extend_recorded_times_with_fragment_metadata`
//     added the new columns; this is the first writer that fills them.
//
//  2. PairingHandoff — the function the spec asks for: "takes a
//     recorded_times row (or fragment metadata + time) and returns
//     { swimmerId, context } matched to the correct swimmer with
//     full context (distance, intensity, start type, pace target).
//     If no swimmer matches, return an explicit 'unmatched' result
//     with the context preserved so the coach can resolve manually."
//
//     The handoff is a single-row velocity-space Gaussian cost
//     against the supplied swimmer roster + their per-(distance,
//     intensity, start) predictions. Same formula as
//     PairingEngine.velocitySpaceCost (V10 pattern). The handoff is
//     deliberately a thin wrapper: the multi-row Hungarian lives in
//     PairingEngine for live session-save; the handoff is the
//     standalone "resolve this one row" surface that doesn't need a
//     full wave setup.
//
//  3. After the handoff resolves, write the swimmer_id back to the
//     row in `recorded_times`. Unmatched rows are written as
//     swimmer_id = NULL so the coach can resolve manually in the
//     review UI.
//
// Why this isn't in PairingEngine itself: the engine is multi-row
// Hungarian with wave setup. The handoff is a single-row decision
// surface — a different shape, different inputs, different output
// schema ({swimmerId, context} vs [LapAssignment]). Keeping them
// separate lets the iOS save flow evolve independently (e.g. add
// explicit fallback tiers per spec) without touching the production
// pairing engine.

import Foundation
import Supabase

// ─── Pairing handoff types ───────────────────────────────────────────────────

/// The full fragment context the handoff returns alongside the
/// resolved swimmer. Mirrors the spec's "context preserved" claim —
/// every fragment field survives the round-trip even on unmatched.
public struct PairingHandoffContext: Codable, Sendable, Hashable {
    public let fragmentId: String
    public let setId: String?
    public let distanceMeters: Int?
    public let intensity: String?
    public let startType: String?
    public let paceTargetSec: Int?
    public let rawText: String?
    public let recordedMs: Int

    public init(
        fragmentId: String,
        setId: String?,
        distanceMeters: Int?,
        intensity: String?,
        startType: String?,
        paceTargetSec: Int?,
        rawText: String?,
        recordedMs: Int
    ) {
        self.fragmentId = fragmentId
        self.setId = setId
        self.distanceMeters = distanceMeters
        self.intensity = intensity
        self.startType = startType
        self.paceTargetSec = paceTargetSec
        self.rawText = rawText
        self.recordedMs = recordedMs
    }
}

/// The pairing handoff result. Two cases:
///   - matched: the engine resolved to a specific swimmer + the
///     full fragment context the coach needs to confirm/audit.
///   - unmatched: no swimmer was within the cost threshold (the row
///     is unmatchable, e.g. tap time wildly out of distribution,
///     or roster is empty). The context is preserved verbatim so
///     the coach can resolve manually.
/// Concrete Encodable for the recorded_times write-back. The SDK's
/// update(_:) takes  — a heterogeneous dictionary
/// literal can't satisfy the generic, and  can't
/// conform to Encodable. A concrete struct is the clean fix.
private struct RecordedTimeUpdate: Encodable {
    let swimmer_id: String
    let confidence: Int?
    let assignment_confidence: Double
}

public enum PairingHandoffResult: Codable, Sendable {
    case matched(swimmerId: String, swimmerName: String, confidence: Double, fallbackTier: FallbackTier, context: PairingHandoffContext)
    case unmatched(reason: UnmatchedReason, context: PairingHandoffContext)

    public enum FallbackTier: String, Codable, Sendable {
        case exactContext = "exact_context"
        case intensityOverlap = "intensity_overlap"
        case gearInferred = "gear_inferred"
        case ambiguous = "ambiguous"
    }

    public enum UnmatchedReason: String, Codable, Sendable {
        case emptyRoster = "empty_roster"
        case noValidPrediction = "no_valid_prediction"
        case costAboveThreshold = "cost_above_threshold"
    }

    public var context: PairingHandoffContext {
        switch self {
        case .matched(_, _, _, _, let ctx): return ctx
        case .unmatched(_, let ctx): return ctx
        }
    }
}

/// Inputs to the pairing handoff. Either:
///   - a recordedTimesRow (read by the service), OR
///   - fragment metadata + recorded time + a parent recorded_time id
///     (the service writes the row first, then pairs).
///
/// Either path yields the same PairingHandoffResult.
public struct PairingHandoffInput: Sendable {
    public let rowId: String
    public let recordedMs: Int
    public let fragmentId: String
    public let setId: String?
    public let distanceMeters: Int?
    public let intensity: String?
    public let startType: String?
    public let paceTargetSec: Int?
    public let rawText: String?

    public init(
        rowId: String,
        recordedMs: Int,
        fragmentId: String,
        setId: String?,
        distanceMeters: Int?,
        intensity: String?,
        startType: String?,
        paceTargetSec: Int?,
        rawText: String?
    ) {
        self.rowId = rowId
        self.recordedMs = recordedMs
        self.fragmentId = fragmentId
        self.setId = setId
        self.distanceMeters = distanceMeters
        self.intensity = intensity
        self.startType = startType
        self.paceTargetSec = paceTargetSec
        self.rawText = rawText
    }

    public var context: PairingHandoffContext {
        PairingHandoffContext(
            fragmentId: fragmentId,
            setId: setId,
            distanceMeters: distanceMeters,
            intensity: intensity,
            startType: startType,
            paceTargetSec: paceTargetSec,
            rawText: rawText,
            recordedMs: recordedMs
        )
    }
}

/// A per-swimmer prediction the handoff evaluates against. Mirrors
/// the iOS Prediction shape but the minimum the handoff needs (timeMs
/// + sigmaMs + name). The caller is responsible for fetching the
/// (swimmer, distance, intensity, start) prediction — the handoff is
/// not a predictor.
public struct HandoffSwimmerCandidate: Sendable, Hashable {
    public let swimmerId: String
    public let swimmerName: String
    public let predictedTouchMs: Int
    public let predictedSigmaMs: Int

    public init(swimmerId: String, swimmerName: String, predictedTouchMs: Int, predictedSigmaMs: Int) {
        self.swimmerId = swimmerId
        self.swimmerName = swimmerName
        self.predictedTouchMs = predictedTouchMs
        self.predictedSigmaMs = predictedSigmaMs
    }
}

// ─── PairingHandoff ──────────────────────────────────────────────────────────

/// PairingHandoff — the spec's "pairing-engine handoff function."
///
/// Pure function. Takes an input row (or fragment metadata + time)
/// and a roster of per-(swimmer, fragment) predictions, returns
/// {swimmerId, context} or unmatched. The velocity-space Gaussian
/// cost is the same V10 formula PairingEngine uses (cost = (vel -
/// meanVel)^2 / (2 * varVel)). The handoff is the single-row flavor:
/// pick the cheapest swimmer across the roster; if the cheapest cost
/// is above the ghost-tap threshold, return unmatched.
public enum PairingHandoff {

    /// Cost above which a tap is treated as a ghost (impossible to
    /// pair). Same value as PairingEngine.ghostTapThresholdCost.
    /// Tuned value: 5.0.
    public static let ghostTapThresholdCost: Double = 5.0

    /// Run the handoff for a single input + roster. Returns matched
    /// or unmatched. Does not throw — unmatched is a typed result,
    /// not an error. The caller is responsible for writing the
    /// resolved swimmer_id back to the row.
    public static func run(
        input: PairingHandoffInput,
        candidates: [HandoffSwimmerCandidate]
    ) -> PairingHandoffResult {
        if candidates.isEmpty {
            return .unmatched(reason: .emptyRoster, context: input.context)
        }

        var bestCandidate: HandoffSwimmerCandidate? = nil
        var bestCost: Double = Double.greatestFiniteMagnitude
        for c in candidates {
            if c.predictedTouchMs <= 0 { continue }
            let cost = velocitySpaceCost(
                actualTimeMs: input.recordedMs,
                predTimeMs: c.predictedTouchMs,
                predSigmaMs: c.predictedSigmaMs
            )
            if cost < bestCost {
                bestCost = cost
                bestCandidate = c
            }
        }

        guard let best = bestCandidate else {
            return .unmatched(reason: .noValidPrediction, context: input.context)
        }

        if bestCost >= ghostTapThresholdCost {
            return .unmatched(reason: .costAboveThreshold, context: input.context)
        }

        let gaussian = exp(-(bestCost))
        return .matched(
            swimmerId: best.swimmerId,
            swimmerName: best.swimmerName,
            confidence: gaussian,
            fallbackTier: .exactContext,
            context: input.context
        )
    }

    /// Velocity-space Gaussian cost (V10, port of
    /// PairingEngine.velocitySpaceCost). Same formula as the
    /// multi-row pairing engine — the handoff is just the
    /// single-row flavor.
    static func velocitySpaceCost(
        actualTimeMs: Int,
        predTimeMs: Int,
        predSigmaMs: Int
    ) -> Double {
        if predTimeMs <= 0 || actualTimeMs <= 0 { return ghostTapThresholdCost }
        let vel = 1.0 / Double(actualTimeMs)
        let meanVel = 1.0 / Double(predTimeMs)
        let stdevVel = (1.0 / pow(Double(predTimeMs), 2)) * Double(predSigmaMs)
        let varVel = pow(stdevVel, 2)
        if varVel <= 0 { return ghostTapThresholdCost }
        return pow(vel - meanVel, 2) / (2.0 * varVel)
    }
}

// ─── PersistRecordedTimeError (typed error path) ─────────────────────────────

/// Typed error surfaced by `persistRecordedTime` instead of a
/// raw supabase `Error`. Buckets the three failure modes the
/// stopwatch-on-stop path can hit:
///
///   - `.duplicateRow` — the row's UUID is already on the table
///     (id is the only UNIQUE constraint on recorded_times;
///     re-inserting the same UUID is the most likely cause).
///     Surfaced as a typed result so the caller can decide
///     whether to retry-with-new-uuid or surface to the user.
///
///   - `.networkError(underlying)` — URLSession / connectivity
///     failure (DNS, timeout, offline). The supabase-swift SDK
///     raises a generic `Error`; we bucket on the message text
///     (`URLSession`, `offline`, `timed out`, `The Internet`,
///     `could not connect`) and on `URLError` codes. Anything we
///     can't classify falls through to `.unknown`.
///
///   - `.decodingError(underlying)` — the inserted row came back
///     but JSONDecoder() couldn't shape it into `RecordedTime`.
///     Indicates a schema drift between the iOS model and the
///     DB (a column was renamed or removed). The row landed,
///     but the caller can't see what was inserted.
///
///   - `.unknown(underlying)` — anything else. Logged with the
///     underlying error; the caller decides whether to swallow.
///
/// Why typed: the spec's "fire-and-await is fine, but show a
/// 'Saved' indicator once the insert succeeds" rule depends on
/// the caller being able to distinguish success from failure.
/// Catching the typed error and not flipping the indicator is
/// the UI contract.
public enum PersistRecordedTimeError: LocalizedError {
    case duplicateRow(id: String)
    case networkError(underlying: Error)
    case decodingError(underlying: Error)
    case unknown(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .duplicateRow(let id):
            return "A recorded_times row with id \(id) already exists."
        case .networkError(let underlying):
            return "Network error saving recorded time: \(underlying.localizedDescription)"
        case .decodingError(let underlying):
            return "Inserted row could not be decoded: \(underlying.localizedDescription)"
        case .unknown(let underlying):
            return "Failed to save recorded time: \(underlying.localizedDescription)"
        }
    }

    /// Bucket a raw `Error` into the typed error. The supabase-swift
    /// SDK doesn't expose typed error variants for the postgrest
    /// call paths, so we pattern-match on the message text + the
    /// `URLError`/`NSURLError*` codes. If the match is ambiguous,
    /// we fall through to `.unknown` so the caller still gets a
    /// surface-able error.
    static func classify(_ error: Error) -> PersistRecordedTimeError {
        let nsError = error as NSError
        let message = (error.localizedDescription + " " + (nsError.userInfo[NSLocalizedDescriptionKey] as? String ?? "")).lowercased()

        // Duplicate-row detection. Postgres surfaces these as
        // "duplicate key value violates unique constraint" or
        // "23505". The supabase-swift SDK wraps the message
        // verbatim into localizedDescription.
        if message.contains("duplicate") || message.contains("unique constraint") || message.contains("23505") {
            // Try to extract the row id from the message — best-effort.
            // PostgREST returns the conflicting row's PK in the error
            // body, but the SDK only exposes localizedDescription.
            return .duplicateRow(id: extractDuplicateId(from: message) ?? "unknown")
        }

        // Network / connectivity. URLError is the URLSession layer's
        // own type; the SDK doesn't wrap it. Match on domain + code
        // names so we don't have to import URLSession here.
        if nsError.domain == NSURLErrorDomain {
            return .networkError(underlying: error)
        }
        if message.contains("urlsession") || message.contains("timed out") ||
           message.contains("the internet") || message.contains("offline") ||
           message.contains("could not connect") || message.contains("network") {
            return .networkError(underlying: error)
        }

        // Decoding error from JSONDecoder.
        if nsError.domain == "NSCocoaErrorDomain" && (
            message.contains("decoded") || message.contains("expected to decode") ||
            message.contains("keynotfound") || message.contains("type mismatch")
        ) {
            return .decodingError(underlying: error)
        }

        return .unknown(underlying: error)
    }

    /// Best-effort duplicate id extraction. The supabase-swift
    /// SDK's error message format for a 409 isn't stable across
    /// versions, so we try a few regexes and fall back to nil.
    /// The id isn't strictly required for the typed error — the
    /// `.duplicateRow` case carries it as a hint, not a contract.
    private static func extractDuplicateId(from message: String) -> String? {
        // Postgres format: "Key (id)=(abc-123) already exists."
        if let range = message.range(of: #"(?:id|=)\s*\(?([0-9a-fA-F-]{36})\)?\s*already"#, options: .regularExpression) {
            let match = String(message[range])
            if let idRange = match.range(of: #"[0-9a-fA-F-]{36}"#, options: .regularExpression) {
                return String(match[idRange])
            }
        }
        return nil
    }
}

// ─── RecordedTimeFragmentService ─────────────────────────────────────────────

/// RecordedTimeFragmentService — persists a per-fragment recorded
/// time to `recorded_times` with all spec fields populated, then
/// runs the pairing handoff and writes the resolved swimmer_id back.
///
/// The service is the production writer the WorkoutDetailView's
/// `recordedTimesByFragmentId` map drains into on save success.
///
/// Usage (from WorkoutDetailView or a save-flow view model):
///
///   let service = RecordedTimeFragmentService()
///   let result = try await service.saveAndPair(
///       sessionId: session.id,
///       workoutSetId: set.id,
///       input: PairingHandoffInput(
///           rowId: UUID().uuidString,
///           recordedMs: elapsedMs,
///           fragmentId: fragmentId,
///           setId: set.id,
///           distanceMeters: fragment.distanceMeters,
///           intensity: fragment.intensity,
///           startType: fragment.startType,
///           paceTargetSec: fragment.paceTargetSec,
///           rawText: set.rawText
///       ),
///       candidates: perFragmentCandidates
///   )
///
/// The `candidates` array is the caller's responsibility — it
/// mirrors the TimingViewModel.save() pattern (per-fragment PB
/// prediction). The handoff itself is a pure function; the
/// service just persists the row + runs handoff + writes back.
public final class RecordedTimeFragmentService {
    private let supabase = SupabaseService.shared.client

    /// Persist a single per-fragment recorded time to the
    /// `recorded_times` table and return the inserted row. On
    /// success, run the pairing handoff against the caller-supplied
    /// roster and write the resolved `swimmer_id` back in a
    /// follow-up UPDATE.
    ///
    /// Spec signature: `persistRecordedTime(input: {...}) -> RecordedTime`.
    /// All metadata fields from the input struct are written:
    /// set_id, fragment_id, distance_meters, intensity, start_type,
    /// pace_target_sec, raw_text, recorded_ms (mapped to time_ms),
    /// created_at (server default). **swimmer_id is left NULL** at
    /// insert time — the inline pairing handoff below writes the
    /// resolved swimmer_id back in a follow-up UPDATE. When no
    /// candidates are supplied (the common case for the
    /// per-fragment CTA flow, which doesn't have access to the
    /// wave roster at insert time), the row stays swimmer_id=NULL
    /// and a structured log is emitted carrying the full
    /// PairingContext; the deferred `pairExistingRow` path can
    /// resolve it later when the roster is fetched.
    ///
    /// `candidates` defaults to `[]`. Empty roster → `.unmatched`
    /// with reason `emptyRoster` → no UPDATE fired → row keeps
    /// swimmer_id=NULL → structured log carries the context. The
    /// caller never sees a thrown error from the handoff; the
    /// handoff is wrapped in try/catch and never propagates
    /// (this is the spec's "the handoff must NEVER throw" rule).
    ///
    /// On success: returns the inserted `RecordedTime` decoded from
    /// the postgrest response (the `.insert().select().single()`
    /// pattern). The caller can use the returned row's `id` for
    /// downstream pairing handoff wiring (e.g. a deferred pass).
    ///
    /// On insert failure: throws `PersistRecordedTimeError`. Four
    /// buckets: `.duplicateRow` (id conflict), `.networkError`
    /// (URLSession / connectivity), `.decodingError` (schema drift
    /// — row landed but couldn't be decoded), `.unknown` (anything
    /// else). The caller is responsible for surfacing these — the
    /// function does not swallow.
    ///
    /// Why a separate function from `saveOnly`:
    ///   - `saveOnly` returns Void and discards the postgrest
    ///     response; the caller can't see what was written.
    ///   - `persistRecordedTime` returns the inserted row so the
    ///     UI / pairing handoff can use the server-side id
    ///     (which equals the client-generated UUID we passed in,
    ///     but verifying server echo is the spec's "verify
    ///     swimmer_id is null immediately after insert" check).
    ///   - `persistRecordedTime` raises typed errors so the
    ///     stopwatch's "Saved" indicator can fire on the success
    ///     path and not on the failure path.
    ///   - `persistRecordedTime` runs the inline handoff on the
    ///     success path (when candidates are available), keeping
    ///     the call site simple — the iOS view layer doesn't
    ///     need a second post-insert call when the roster is on
    ///     hand.
    ///
    /// Internal (not public): the return type `RecordedTime` is
    /// internal-by-default; declaring a `public` method whose
    /// result uses an internal type is illegal under Swift's
    /// access-control rules and trips the strict-concurrency
    /// build. Only the iOS module calls this today
    /// (WorkoutDetailView.persistRecordedTime), so internal is
    /// the correct scope.
    func persistRecordedTime(
        input: PairingHandoffInput,
        sessionId: String?,
        workoutSetId: String?,
        coachId: String? = nil,
        candidates: [HandoffSwimmerCandidate] = []
    ) async throws -> RecordedTime {
        // Build the row from the input. swimmer_id is left NULL
        // — the pairing handoff (inline, this slice) writes it
        // back after the row lands. If the inline handoff doesn't
        // resolve (no candidates, cost-above-threshold, etc.) the
        // row stays NULL and a structured log carries the
        // PairingContext for later manual resolution.
        let row = FragmentRow(
            id: input.rowId,
            sessionId: sessionId,
            swimmerId: nil,                    // pairing handoff fills this in
            workoutSetId: workoutSetId,
            fragmentId: input.fragmentId,
            distanceMeters: input.distanceMeters,
            intensity: input.intensity,
            startType: input.startType,
            paceTargetSec: input.paceTargetSec,
            rawText: input.rawText,
            timeMs: input.recordedMs,
            coachId: coachId,
            confidence: nil,                   // not yet paired
            assignmentConfidence: nil          // not yet paired
        )

        // Insert + return the row. The supabase-swift SDK's
        // `.insert(row).select().single().execute()` pattern asks
        // PostgREST to add `Prefer: return=representation` so the
        // inserted row comes back in the response body.
        let inserted: RecordedTime
        do {
            inserted = try await supabase
                .from("recorded_times")
                .insert(row)
                .select()
                .single()
                .execute()
                .value
        } catch let error as PersistRecordedTimeError {
            // Already classified — re-throw as-is.
            throw error
        } catch {
            // Bucket the raw supabase / URLSession error into the
            // typed error. The SDK doesn't expose typed variants
            // on the postgrest path; we classify by message text
            // + URLError domain.
            throw PersistRecordedTimeError.classify(error)
        }

        // Inline pairing handoff (t_ea9a65ca). Runs against the
        // caller-supplied roster. On .matched: writes swimmer_id
        // (and confidence / assignment_confidence) back to the
        // row via UPDATE. On .unmatched: leaves swimmer_id=NULL
        // and emits a structured log carrying the full
        // PairingContext for manual resolution. NEVER throws —
        // the whole handoff is wrapped in try/catch.
        await pairRecordedTimeViaHandoff(
            inserted: inserted,
            candidates: candidates
        )

        return inserted
    }

    /// Run the inline pairing handoff against an already-persisted
    /// row. On `.matched`, writes `swimmer_id` (and `confidence` /
    /// `assignment_confidence`) back to the row in `recorded_times`.
    /// On `.unmatched`, leaves `swimmer_id=NULL` and emits a
    /// structured log carrying the full `PairingHandoffContext`.
    /// NEVER throws — the whole handoff + UPDATE path is wrapped in
    /// try/catch and any error is logged + swallowed. This is the
    /// spec's "the handoff must NEVER throw — wrap in try/catch and
    /// log on error" rule.
    ///
    /// Designed to be called from `persistRecordedTime`'s success
    /// path (the inline case) but is also usable standalone when
    /// the caller has the inserted row in hand. For the
    /// "look-up-by-rowId" deferred case, use `pairExistingRow`
    /// instead — that variant reads the row back from the DB and
    /// runs the same handoff + write-back; it's not invoked from
    /// the inline path because we already have the row in scope.
    ///
    /// Internal (not public): the `inserted: RecordedTime`
    /// parameter type is internal-by-default; declaring a
    /// `public` method whose parameter uses an internal type is
    /// illegal under Swift's access-control rules and trips the
    /// strict-concurrency build.
    func pairRecordedTimeViaHandoff(
        inserted: RecordedTime,
        candidates: [HandoffSwimmerCandidate]
    ) async {
        let handoffInput = PairingHandoffInput(
            rowId: inserted.id,
            recordedMs: inserted.timeMs,
            fragmentId: inserted.fragmentId ?? "",
            setId: inserted.workoutSetId,
            distanceMeters: inserted.distanceMeters,
            intensity: inserted.intensity,
            startType: inserted.fragmentStartType,
            paceTargetSec: inserted.paceTargetSec,
            rawText: inserted.rawText
        )

        // Run the pure handoff. PairingHandoff.run is a pure
        // function and does NOT throw — unmatched is a typed
        // result, not an error. The follow-up UPDATE can fail
        // (network, DB) and we must not surface that to the
        // stopwatch UI. The spec is explicit: "The handoff
        // must NEVER throw — wrap in try/catch and log on
        // error." So the pure handoff call is unconditional;
        // the try/catch sits around the UPDATE.
        let result = PairingHandoff.run(input: handoffInput, candidates: candidates)

        switch result {
        case .matched(let swimmerId, let swimmerName, let confidence, let fallbackTier, let ctx):
            // Resolved — write swimmer_id + confidence back to
            // the row. The confidence fields are derived from the
            // handoff's gaussian (same formula PairingEngine
            // uses for its integer confidence column).
            let confidenceInt = matchedConfidence(from: result)
            do {
                // Confidence fields are Int?/Double? — both
                // conform to Encodable. The previous `as Any?`
                // cast tripped Swift's "Type 'Any' cannot conform
                // to 'Encodable'" error under strict-concurrency;
                // passing the typed optionals lets the supabase
                // SDK's [String: any Encodable] dict accept
                // them.
                try await supabase.from("recorded_times")
                    .update(RecordedTimeUpdate(
                        swimmer_id: swimmerId,
                        confidence: confidenceInt,
                        assignment_confidence: confidence
                    ))
                    .eq("id", value: inserted.id)
                    .execute()
                print("[RecordedTimeFragmentService] pairRecordedTimeViaHandoff: row=\(inserted.id) MATCHED swimmer=\(swimmerName)(\(swimmerId)) confidence=\(String(format: "%.4f", confidence)) tier=\(fallbackTier.rawValue)")
            } catch {
                // Handoff resolved but the write-back failed.
                // Surface a structured warning so the dev console
                // + future telemetry pipeline can detect the
                // mismatch (swimmer known, row not updated).
                // The stopwatch UI is unaffected — the row stays
                // swimmer_id=NULL on disk and the deferred
                // pairExistingRow pass can retry later.
                print("[RecordedTimeFragmentService] pairRecordedTimeViaHandoff: row=\(inserted.id) MATCHED \(swimmerName)(\(swimmerId)) but UPDATE failed: \(error.localizedDescription) — context: fragment=\(ctx.fragmentId) distance=\(ctx.distanceMeters ?? -1)m intensity=\(ctx.intensity ?? "nil") recorded_ms=\(ctx.recordedMs)")
            }

        case .unmatched(let reason, let ctx):
            // No resolution. Row stays swimmer_id=NULL. Emit a
            // structured log so the coach UI can later surface
            // this for manual resolution (per spec: "carry the
            // full PairingContext so the coach UI can later
            // surface it for manual resolution").
            //
            // The log format is structured (one line, prefix +
            // key=value pairs) so a future telemetry consumer can
            // parse it without re-deriving the context. Includes
            // every PairingContext field so the coach review UI
            // can hydrate a manual-resolution card with no extra
            // round-trip.
            print("[RecordedTimeFragmentService] pairRecordedTimeViaHandoff: row=\(inserted.id) UNMATCHED reason=\(reason.rawValue) " +
                  "context_fragment=\(ctx.fragmentId) " +
                  "context_set=\(ctx.setId ?? "nil") " +
                  "context_distance_m=\(ctx.distanceMeters.map(String.init) ?? "nil") " +
                  "context_intensity=\(ctx.intensity ?? "nil") " +
                  "context_start_type=\(ctx.startType ?? "nil") " +
                  "context_pace_target_sec=\(ctx.paceTargetSec.map(String.init) ?? "nil") " +
                  "context_raw_text=\(ctx.rawText ?? "nil") " +
                  "context_recorded_ms=\(ctx.recordedMs)")
        }
    }

    /// Save a per-fragment recorded-time row, run the pairing
    /// handoff, and write the resolved swimmer_id back. Returns
    /// the final PairingHandoffResult (matched or unmatched).
    ///
    /// On failure (network / DB error), throws. The handoff itself
    /// never throws — unmatched is a typed result.
    public func saveAndPair(
        sessionId: String?,
        workoutSetId: String?,
        coachId: String? = nil,
        input: PairingHandoffInput,
        candidates: [HandoffSwimmerCandidate]
    ) async throws -> PairingHandoffResult {
        // 1. Run the handoff first — pure function, no I/O.
        let result = PairingHandoff.run(input: input, candidates: candidates)

        // 2. Persist the row. The spec wants ALL metadata fields
        //    populated, including the raw_text, fragment_id,
        //    distance_meters, start_type, pace_target_sec. The
        //    swimmer_id is the handoff's resolution (nil on
        //    unmatched so the coach can resolve manually).
        let row = FragmentRow(
            id: input.rowId,
            sessionId: sessionId,
            swimmerId: resolvedSwimmerId(from: result),
            workoutSetId: workoutSetId,
            fragmentId: input.fragmentId,
            distanceMeters: input.distanceMeters,
            intensity: input.intensity,
            startType: input.startType,
            paceTargetSec: input.paceTargetSec,
            rawText: input.rawText,
            timeMs: input.recordedMs,
            coachId: coachId,
            confidence: matchedConfidence(from: result),
            assignmentConfidence: matchedGaussian(from: result)
        )
        try await supabase.from("recorded_times")
            .insert(row)
            .execute()

        return result
    }

    /// Save the row only (no handoff). Useful when the caller has
    /// already resolved the swimmer_id (e.g. the single-swimmer
    /// prefill path), or when the pairing flow is deferred to a
    /// later session-review pass.
    public func saveOnly(
        sessionId: String?,
        workoutSetId: String?,
        coachId: String? = nil,
        input: PairingHandoffInput,
        swimmerId: String? = nil,
        confidence: Int? = nil,
        assignmentConfidence: Double? = nil
    ) async throws {
        let row = FragmentRow(
            id: input.rowId,
            sessionId: sessionId,
            swimmerId: swimmerId,
            workoutSetId: workoutSetId,
            fragmentId: input.fragmentId,
            distanceMeters: input.distanceMeters,
            intensity: input.intensity,
            startType: input.startType,
            paceTargetSec: input.paceTargetSec,
            rawText: input.rawText,
            timeMs: input.recordedMs,
            coachId: coachId,
            confidence: confidence,
            assignmentConfidence: assignmentConfidence
        )
        try await supabase.from("recorded_times")
            .insert(row)
            .execute()
    }

    /// Run the handoff for an already-persisted row. Looks the row
    /// up by id, runs the handoff, writes the resolved swimmer_id
    /// back. Returns the PairingHandoffResult.
    public func pairExistingRow(
        rowId: String,
        candidates: [HandoffSwimmerCandidate]
    ) async throws -> PairingHandoffResult {
        let row: RecordedTime = try await supabase.from("recorded_times")
            .select()
            .eq("id", value: rowId)
            .single()
            .execute()
            .value

        let input = PairingHandoffInput(
            rowId: row.id,
            recordedMs: row.timeMs,
            fragmentId: row.fragmentId ?? "",
            setId: row.workoutSetId,
            distanceMeters: row.distanceMeters,
            intensity: row.intensity,
            startType: row.fragmentStartType,
            paceTargetSec: row.paceTargetSec,
            rawText: row.rawText
        )
        let result = PairingHandoff.run(input: input, candidates: candidates)

        let resolvedSwimmerId = self.resolvedSwimmerId(from: result)
        // `String?` is Encodable; the previous `as Any?` cast
        // tripped the strict-concurrency "Type 'Any' cannot
        // conform to 'Encodable'" error. Pass the typed optional
        // through; the supabase SDK's [String: any Encodable]
        // dict accepts it.
        try await supabase.from("recorded_times")
            .update(["swimmer_id": resolvedSwimmerId])
            .eq("id", value: rowId)
            .execute()

        return result
    }

    // MARK: - Helpers

    private func resolvedSwimmerId(from result: PairingHandoffResult) -> String? {
        switch result {
        case .matched(let swimmerId, _, _, _, _): return swimmerId
        case .unmatched: return nil
        }
    }

    private func matchedConfidence(from result: PairingHandoffResult) -> Int? {
        switch result {
        case .matched(_, _, let gaussian, _, _):
            // Map Gaussian → 0..99 integer (port of
            // PairingEngine.confidenceFromZ formula).
            // z = sqrt(-2 * ln(gaussian)); clamp.
            guard gaussian > 0 else { return 0 }
            let z = sqrt(-2.0 * log(gaussian))
            return max(0, 99 - Int((z * 15.0).rounded()))
        case .unmatched: return nil
        }
    }

    private func matchedGaussian(from result: PairingHandoffResult) -> Double? {
        switch result {
        case .matched(_, _, let gaussian, _, _): return gaussian
        case .unmatched: return nil
        }
    }
}

// ─── DB row shape ────────────────────────────────────────────────────────────

/// The DB row Encodable used by `saveAndPair` / `saveOnly`. Matches
/// the columns added by the migration
/// `extend_recorded_times_with_fragment_metadata` plus the existing
/// columns the service writes.
private struct FragmentRow: Encodable {
    let id: String
    let session_id: String?
    let swimmer_id: String?
    let workout_set_id: String?
    let fragment_id: String
    let distance_meters: Int?
    let intensity: String?
    let start_type: String?
    let pace_target_sec: Int?
    let raw_text: String?
    let time_ms: Int
    let rep_index: Int
    let source: String
    let confidence: Int?
    let assignment_confidence: Double?
    let lap_order: Int
    let created_at: String
    /// V0.46 fix (2026-08-20): owning coach's coaches.id. Required by
    /// the coach_own_recorded_times RLS policy. nil → NULL → RLS
    /// WITH CHECK violation on INSERT.
    let coach_id: String?

    init(
        id: String,
        sessionId: String?,
        swimmerId: String?,
        workoutSetId: String?,
        fragmentId: String,
        distanceMeters: Int?,
        intensity: String?,
        startType: String?,
        paceTargetSec: Int?,
        rawText: String?,
        timeMs: Int,
        coachId: String? = nil,
        confidence: Int? = nil,
        assignmentConfidence: Double? = nil
    ) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        self.id = id
        self.session_id = sessionId
        self.swimmer_id = swimmerId
        self.workout_set_id = workoutSetId
        self.fragment_id = fragmentId
        self.distance_meters = distanceMeters
        self.intensity = intensity
        self.start_type = startType
        self.pace_target_sec = paceTargetSec
        self.raw_text = rawText
        self.time_ms = timeMs
        self.rep_index = 1
        self.source = "auto"
        self.confidence = confidence
        self.assignment_confidence = assignmentConfidence
        self.lap_order = 0
        self.created_at = timestamp
        self.coach_id = coachId
    }
}