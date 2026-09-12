// Hydrolyze — StopwatchCapture (Swift mirror, t_bec2b88b, 2026-08-06)
//
// Mirror of the canonical TypeScript schema in
// /Users/nathanmaxwell/.hermes/kanban/workspaces/t_da3e9614/stopwatch-capture-payload.ts
// (the workspace's `stopwatch-capture-payload.ts` file).
//
// The TS schema is the source of truth; this Swift file is the iOS
// production mirror. The field set + types are field-for-field
// equivalent. If the two drift, the iOS app breaks the contract
// the persistence layer (task 3, t_1789d5c7) consumes.
//
// What this type is for:
//   - `TimingViewModel.assembleCapturePayload(...)` builds one of
//     these on STOP, in `.onChange(of: viewModel.state)`.
//   - `TimingView.onRecord` delivers the full StopwatchCapture to
//     the caller (WorkoutDetailView's per-fragment CTA flow) — the
//     prior `(fragmentId, elapsedMs)` tuple carried the rest of
//     the metadata implicitly; the explicit payload is the typed
//     contract.
//   - `RecordedTimeFragmentService.persistRecordedTime(input: ...)`
//     receives a `PairingHandoffInput` projected from this payload
//     (the projection is `StopwatchCapture.toPersistInput()`).
//
// Design notes:
//   - The payload is a value type (struct, Codable, Sendable,
//     Hashable). All identifiers are String (UUID-shaped).
//   - `context.swimmerId` is optional (multi-swimmer path) — the
//     pairing engine resolves swimmer_id from the wave roster.
//   - `context.workoutSetId` is optional (bare-start path) — the
//     coach times a swimmer without a workout_set context.
//   - `capture.appBuildNumber` is optional — populated when
//     available, omitted from the payload otherwise (the TS schema
//     uses optional with `?` for the same field).
//   - The version constant pins the schema — bump it whenever a
//     field is added or the contract changes.
//
// See also:
//   - PairingHandoffInput (in RecordedTimeFragmentService.swift):
//     the row-shape the persistence layer writes; `toPersistInput`
//     below projects StopwatchCapture → PairingHandoffInput 1:1.
//   - FragmentContext (in Models/FragmentContext.swift): the
//     per-fragment metadata the stopwatch pre-fills from
//     WorkoutDetailView.launchFragmentTiming.

import Foundation

/// Canonical schema version. Mirrors `STOPWATCH_CAPTURE_VERSION`
/// in the TS schema. Bump both together when the contract changes.
public let STOPWATCH_CAPTURE_VERSION = "hydrolyze.stopwatch-capture.v1"

/// How the time was recorded. The union is open — future paths
/// (manual entry, video stop) reuse the same payload shape.
public enum StopwatchCaptureMethod: String, Codable, Sendable, Hashable {
    case stopwatch
    case manual
    case videoStop = "video_stop"
}

/// The moment + method of one recorded time. One StopwatchCapture
/// belongs to exactly one StopwatchCapturePayload.
public struct StopwatchCaptureMoment: Codable, Sendable, Hashable {
    public let method: StopwatchCaptureMethod
    /// ISO8601 wall-clock — the moment the stopwatch transitioned to .running.
    public let startedAt: String
    /// ISO8601 wall-clock — the moment the stopwatch transitioned to .finished / .saving.
    public let stoppedAt: String
    /// 1-indexed tap sequence within this stopwatch run.
    /// For the per-fragment CTA path (single fragment) the value is 1.
    public let deviceEventSequence: Int
    /// The app's build number at capture time (optional; persistence
    /// layer tolerates missing).
    public let appBuildNumber: String?

    public init(
        method: StopwatchCaptureMethod,
        startedAt: String,
        stoppedAt: String,
        deviceEventSequence: Int,
        appBuildNumber: String? = nil
    ) {
        self.method = method
        self.startedAt = startedAt
        self.stoppedAt = stoppedAt
        self.deviceEventSequence = deviceEventSequence
        self.appBuildNumber = appBuildNumber
    }
}

/// The fragment-level metadata the stopwatch observed. Mirrors
/// the `Fragment` shape from `hydrolyze.parse.v2` (schema.ts).
public struct StopwatchFragmentEcho: Codable, Sendable, Hashable {
    public let fragmentId: String
    public let parentIntervalId: String
    public let distanceMeters: Int
    public let intensityLabel: String
    public let startType: String  // "in_water" | "dive" | "backstroke_start"
    public let paceTargetSec: Int?
    public let descriptor: String?
    public let suit: Bool?
    public let gear: [String]?

    public init(
        fragmentId: String,
        parentIntervalId: String,
        distanceMeters: Int,
        intensityLabel: String,
        startType: String,
        paceTargetSec: Int?,
        descriptor: String? = nil,
        suit: Bool? = nil,
        gear: [String]? = nil
    ) {
        self.fragmentId = fragmentId
        self.parentIntervalId = parentIntervalId
        self.distanceMeters = distanceMeters
        self.intensityLabel = intensityLabel
        self.startType = startType
        self.paceTargetSec = paceTargetSec
        self.descriptor = descriptor
        self.suit = suit
        self.gear = gear
    }
}

/// Identifiers the persistence layer needs to write the row into
/// the right session / set / coach / swimmer bucket.
///
/// sessionId: required, UUID of the active session.
/// workoutSetId: optional, UUID of the parent workout_set (nil for bare-start).
/// coachId: required, UUID of the coach.
/// swimmerId: optional, UUID of the swimmer (nil for multi-swimmer; pairing engine resolves).
public struct StopwatchContextIds: Codable, Sendable, Hashable {
    public let sessionId: String
    public let workoutSetId: String?
    public let coachId: String
    public let swimmerId: String?

    public init(
        sessionId: String,
        workoutSetId: String?,
        coachId: String,
        swimmerId: String?
    ) {
        self.sessionId = sessionId
        self.workoutSetId = workoutSetId
        self.coachId = coachId
        self.swimmerId = swimmerId
    }
}

/// StopwatchCapturePayload — the full structured payload the live
/// stopwatch hands off to the persistence layer on STOP. Mirrors
/// the TS `StopwatchCapturePayload` interface field-for-field.
///
/// Every STOP, every LAP-driven re-entry on a fragment emits a
/// new payload (with a fresh `eventId` + `idempotencyKey` +
/// `capture.stoppedAt`). The persistence layer inserts a new row
/// per payload; the idempotencyKey de-dupes accidental double-tap
/// inserts on the same stopwatch run.
public struct StopwatchCapturePayload: Codable, Sendable, Hashable {
    public let version: String
    public let eventId: String
    public let idempotencyKey: String
    public let occurredAt: String
    public let recordedTimeMs: Int
    public let fragment: StopwatchFragmentEcho
    public let context: StopwatchContextIds
    public let capture: StopwatchCaptureMoment
    /// Original raw set text the coach entered (e.g. "4 x (75 fast / 25 easy)").
    public let sourceSetText: String

    public init(
        version: String,
        eventId: String,
        idempotencyKey: String,
        occurredAt: String,
        recordedTimeMs: Int,
        fragment: StopwatchFragmentEcho,
        context: StopwatchContextIds,
        capture: StopwatchCaptureMoment,
        sourceSetText: String
    ) {
        self.version = version
        self.eventId = eventId
        self.idempotencyKey = idempotencyKey
        self.occurredAt = occurredAt
        self.recordedTimeMs = recordedTimeMs
        self.fragment = fragment
        self.context = context
        self.capture = capture
        self.sourceSetText = sourceSetText
    }

    /// The projected row the persistence layer (task 3, t_1789d5c7)
    /// consumes. Mirrors `toPersistInput` in the TS schema. The iOS
    /// app wraps this in `PairingHandoffInput` for
    /// `RecordedTimeFragmentService.persistRecordedTime`.
    public func toPersistInput() -> StopwatchCapturePersistInput {
        StopwatchCapturePersistInput(
            rowId: eventId,
            recordedMs: recordedTimeMs,
            fragmentId: fragment.fragmentId,
            setId: context.workoutSetId,
            distanceMeters: fragment.distanceMeters,
            intensity: fragment.intensityLabel,
            startType: fragment.startType,
            paceTargetSec: fragment.paceTargetSec,
            rawText: sourceSetText,
            idempotencyKey: idempotencyKey
        )
    }
}

/// The row the persistence layer writes. Mirrors the TS
/// `StopwatchCapturePersistInput` interface field-for-field.
public struct StopwatchCapturePersistInput: Codable, Sendable, Hashable {
    public let rowId: String
    public let recordedMs: Int
    public let fragmentId: String
    public let setId: String?
    public let distanceMeters: Int
    public let intensity: String
    public let startType: String
    public let paceTargetSec: Int?
    public let rawText: String
    public let idempotencyKey: String

    public init(
        rowId: String,
        recordedMs: Int,
        fragmentId: String,
        setId: String?,
        distanceMeters: Int,
        intensity: String,
        startType: String,
        paceTargetSec: Int?,
        rawText: String,
        idempotencyKey: String
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
        self.idempotencyKey = idempotencyKey
    }
}

/// Typed error from `assembleCapturePayload`. Distinct from the
/// supabase SDK's `Error` so the UI can show actionable messages
/// ("payload is missing recordedTimeMs — re-time the set") rather
/// than a stack-trace-y URL error. Mirrors the TS
/// `StopwatchCaptureError` class.
public enum StopwatchCaptureError: LocalizedError {
    case missingField(String)
    case invalidValue(field: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .missingField(let field):
            return "StopwatchCaptureError: missingField on \(field)"
        case .invalidValue(let field, let reason):
            return "StopwatchCaptureError: invalidValue on \(field) (\(reason))"
        }
    }
}
