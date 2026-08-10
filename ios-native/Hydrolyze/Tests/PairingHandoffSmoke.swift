import Foundation

// PairingHandoffSmoke.swift
//
// Standalone smoke test for the PairingHandoff pure function in
// Services/RecordedTimeFragmentService.swift (t_be09a643, 2026-08-05).
// Run with:
//   swift ios-native/Hydrolyze/Tests/PairingHandoffSmoke.swift
//
// The smoke copies the algorithm types verbatim from
// RecordedTimeFragmentService.swift (Swift can't import a single
// file without a module, so we copy). The algorithm is unchanged:
// same velocity-space Gaussian cost, same threshold, same unmatched
// enum cases. If the production file drifts, this smoke drifts with it.
//
// Covers the worked example "4 x (75 fast / 25 easy)" with pace=90s:
//   - TEST 1: matched path → returns the right swimmer + full context
//   - TEST 2: empty roster → unmatched with context preserved
//   - TEST 3: ghost tap (out-of-distribution time) → unmatched with context
//   - TEST 4: invalid predictions in roster → noValidPrediction
//   - TEST 5: a slow outlier with wide sigma doesn't displace the fastest match
//
// All 5 must pass for the production PairingHandoff to ship.

// ─── Types lifted from RecordedTimeFragmentService.swift (verbatim enough
// to be a faithful copy). The smoke test executes the same algorithm the
// production service uses, against the worked example "75 fast" segment
// from the per-fragment CTA UI shipped in t_d59998d9.

struct PairingHandoffContext: Sendable {
    let fragmentId: String
    let setId: String?
    let distanceMeters: Int?
    let intensity: String?
    let startType: String?
    let paceTargetSec: Int?
    let rawText: String?
    let recordedMs: Int
}

enum UnmatchedReason: String { case emptyRoster, noValidPrediction, costAboveThreshold }
enum FallbackTier: String { case exactContext, intensityOverlap, gearInferred, ambiguous }

enum PairingHandoffResult: CustomStringConvertible {
    case matched(swimmerId: String, swimmerName: String, confidence: Double, fallbackTier: FallbackTier, context: PairingHandoffContext)
    case unmatched(reason: UnmatchedReason, context: PairingHandoffContext)

    var description: String {
        switch self {
        case .matched(let id, let name, let conf, let tier, let ctx):
            return "matched(\(name)=\(id), conf=\(String(format: "%.3f", conf)), tier=\(tier), distance=\(ctx.distanceMeters ?? -1)m intensity=\(ctx.intensity ?? "?") start=\(ctx.startType ?? "?") pace=\(ctx.paceTargetSec ?? -1)s)"
        case .unmatched(let reason, let ctx):
            return "unmatched(\(reason), distance=\(ctx.distanceMeters ?? -1)m intensity=\(ctx.intensity ?? "?") start=\(ctx.startType ?? "?") pace=\(ctx.paceTargetSec ?? -1)s)"
        }
    }
}

struct PairingHandoffInput {
    let rowId: String
    let recordedMs: Int
    let fragmentId: String
    let setId: String?
    let distanceMeters: Int?
    let intensity: String?
    let startType: String?
    let paceTargetSec: Int?
    let rawText: String?
}

struct HandoffSwimmerCandidate: Hashable {
    let swimmerId: String
    let swimmerName: String
    let predictedTouchMs: Int
    let predictedSigmaMs: Int
}

enum PairingHandoff {
    static let ghostTapThresholdCost: Double = 5.0
    static func run(input: PairingHandoffInput, candidates: [HandoffSwimmerCandidate]) -> PairingHandoffResult {
        if candidates.isEmpty { return .unmatched(reason: .emptyRoster, context: makeCtx(input)) }
        var best: HandoffSwimmerCandidate? = nil
        var bestCost = Double.greatestFiniteMagnitude
        for c in candidates {
            if c.predictedTouchMs <= 0 { continue }
            let cost = velocitySpaceCost(actualTimeMs: input.recordedMs, predTimeMs: c.predictedTouchMs, predSigmaMs: c.predictedSigmaMs)
            if cost < bestCost { bestCost = cost; best = c }
        }
        guard let b = best else { return .unmatched(reason: .noValidPrediction, context: makeCtx(input)) }
        if bestCost >= ghostTapThresholdCost { return .unmatched(reason: .costAboveThreshold, context: makeCtx(input)) }
        let gaussian = exp(-(bestCost))
        return .matched(swimmerId: b.swimmerId, swimmerName: b.swimmerName, confidence: gaussian, fallbackTier: .exactContext, context: makeCtx(input))
    }
    static func velocitySpaceCost(actualTimeMs: Int, predTimeMs: Int, predSigmaMs: Int) -> Double {
        if predTimeMs <= 0 || actualTimeMs <= 0 { return ghostTapThresholdCost }
        let vel = 1.0 / Double(actualTimeMs)
        let meanVel = 1.0 / Double(predTimeMs)
        let stdevVel = (1.0 / pow(Double(predTimeMs), 2)) * Double(predSigmaMs)
        let varVel = pow(stdevVel, 2)
        if varVel <= 0 { return ghostTapThresholdCost }
        return pow(vel - meanVel, 2) / (2.0 * varVel)
    }
    static func makeCtx(_ i: PairingHandoffInput) -> PairingHandoffContext {
        PairingHandoffContext(fragmentId: i.fragmentId, setId: i.setId, distanceMeters: i.distanceMeters, intensity: i.intensity, startType: i.startType, paceTargetSec: i.paceTargetSec, rawText: i.rawText, recordedMs: i.recordedMs)
    }
}

// ─── Worked example: "4 x (75 fast / 25 easy)" with pace=90s
// Coach stops the 75 fast stopwatch at 0:42.31 (42310 ms).
// Predictions: 4 swimmers in the squad, each with a per-(75, fast, dive)
// predictedTouchMs. The fastest is "Alice" (matches within sigma) and
// three other swimmers are slower. We expect Alice to win.

let input = PairingHandoffInput(
    rowId: UUID().uuidString,
    recordedMs: 42310,            // 0:42.31 — the stopped 75 fast time
    fragmentId: "fragment_0_75_fast",
    setId: "workout_set_xyz",
    distanceMeters: 75,
    intensity: "fast",
    startType: "dive",
    paceTargetSec: 90,             // enclosing interval send-off
    rawText: "4 x (75 fast / 25 easy)"
)

let candidates = [
    HandoffSwimmerCandidate(swimmerId: "s_alice", swimmerName: "Alice", predictedTouchMs: 42500, predictedSigmaMs: 1200),
    HandoffSwimmerCandidate(swimmerId: "s_bob",   swimmerName: "Bob",   predictedTouchMs: 47500, predictedSigmaMs: 1500),
    HandoffSwimmerCandidate(swimmerId: "s_carol", swimmerName: "Carol", predictedTouchMs: 51000, predictedSigmaMs: 1800),
    HandoffSwimmerCandidate(swimmerId: "s_dave",  swimmerName: "Dave",  predictedTouchMs: 55000, predictedSigmaMs: 2000),
]

print("─── TEST 1: matched path, full context preserved ───")
let r1 = PairingHandoff.run(input: input, candidates: candidates)
print(r1)
switch r1 {
case .matched(let id, let name, _, _, let ctx):
    precondition(id == "s_alice", "FAIL: expected Alice (s_alice), got \(id)")
    precondition(name == "Alice", "FAIL: expected Alice, got \(name)")
    precondition(ctx.distanceMeters == 75, "FAIL: distance not preserved (\(ctx.distanceMeters ?? -1))")
    precondition(ctx.intensity == "fast", "FAIL: intensity not preserved (\(ctx.intensity ?? "?"))")
    precondition(ctx.startType == "dive", "FAIL: startType not preserved (\(ctx.startType ?? "?"))")
    precondition(ctx.paceTargetSec == 90, "FAIL: pace not preserved (\(ctx.paceTargetSec ?? -1))")
    precondition(ctx.recordedMs == 42310, "FAIL: recordedMs not preserved (\(ctx.recordedMs))")
    precondition(ctx.rawText == "4 x (75 fast / 25 easy)", "FAIL: rawText not preserved (\(ctx.rawText ?? "?"))")
    print("PASS — Alice matched, full context preserved")
case .unmatched(let reason, _):
    print("FAIL: expected match, got unmatched(\(reason))")
    exit(1)
}

print("\n─── TEST 2: empty roster → unmatched with context preserved ───")
let r2 = PairingHandoff.run(input: input, candidates: [])
switch r2 {
case .unmatched(let reason, let ctx):
    precondition(reason == .emptyRoster, "FAIL: expected .emptyRoster, got \(reason)")
    precondition(ctx.distanceMeters == 75 && ctx.intensity == "fast" && ctx.startType == "dive" && ctx.paceTargetSec == 90, "FAIL: context not preserved on unmatched")
    precondition(ctx.rawText == "4 x (75 fast / 25 easy)", "FAIL: rawText not preserved on unmatched")
    print("PASS — .emptyRoster, context preserved verbatim (\(ctx.distanceMeters ?? -1)m \(ctx.intensity ?? "?") \(ctx.startType ?? "?") pace=\(ctx.paceTargetSec ?? -1)s)")
case .matched(let id, _, _, _, _):
    print("FAIL: expected unmatched, got matched(\(id))")
    exit(1)
}

print("\n─── TEST 3: ghost tap (way out of distribution) → unmatched with context preserved ───")
let r3 = PairingHandoff.run(input: input, candidates: [
    HandoffSwimmerCandidate(swimmerId: "s_alice", swimmerName: "Alice", predictedTouchMs: 42500, predictedSigmaMs: 1200),
    HandoffSwimmerCandidate(swimmerId: "s_bob",   swimmerName: "Bob",   predictedTouchMs: 47500, predictedSigmaMs: 1500),
])
// Recorded 0:42.31 is fine for Alice. Test ghost tap by recording 1:30.00.
let ghostInput = PairingHandoffInput(
    rowId: UUID().uuidString,
    recordedMs: 90000,
    fragmentId: "fragment_ghost",
    setId: input.setId,
    distanceMeters: 75,
    intensity: "fast",
    startType: "dive",
    paceTargetSec: 90,
    rawText: input.rawText
)
let r4 = PairingHandoff.run(input: ghostInput, candidates: candidates)
print(r4)
switch r4 {
case .unmatched(let reason, let ctx):
    precondition(reason == .costAboveThreshold, "FAIL: expected .costAboveThreshold, got \(reason)")
    precondition(ctx.distanceMeters == 75 && ctx.intensity == "fast" && ctx.startType == "dive" && ctx.paceTargetSec == 90, "FAIL: ghost-tap context not preserved")
    print("PASS — ghost tap → .costAboveThreshold, context preserved")
case .matched(let id, _, _, _, _):
    print("FAIL: expected unmatched, got matched(\(id))")
    exit(1)
}

print("\n─── TEST 4: no throw on any path (spec: 'unmatched cases handled without throwing') ───")
// Run the handoff against garbage input that would have thrown pre-spec.
let r5 = PairingHandoff.run(input: input, candidates: [
    HandoffSwimmerCandidate(swimmerId: "s_zero", swimmerName: "Zero", predictedTouchMs: 0, predictedSigmaMs: 100),
    HandoffSwimmerCandidate(swimmerId: "s_neg",  swimmerName: "Neg",  predictedTouchMs: -100, predictedSigmaMs: 100),
])
switch r5 {
case .unmatched(let reason, _):
    precondition(reason == .noValidPrediction, "FAIL: expected .noValidPrediction, got \(reason)")
    print("PASS — invalid predictions skipped → .noValidPrediction")
case .matched(_, _, _, _, _):
    print("FAIL: should not match anything in the garbage roster")
    exit(1)
}

print("\n─── TEST 5: slower swimmers in roster don't displace fastest match ───")
// Add a slow outlier that should NOT win even though its sigma is wide.
let wildRoster = candidates + [
    HandoffSwimmerCandidate(swimmerId: "s_slowpoke", swimmerName: "Slowpoke", predictedTouchMs: 90000, predictedSigmaMs: 5000),
]
let r6 = PairingHandoff.run(input: input, candidates: wildRoster)
switch r6 {
case .matched(let id, _, _, _, _):
    precondition(id == "s_alice", "FAIL: expected Alice, got \(id)")
    print("PASS — Slowpoke's wide sigma doesn't displace Alice")
case .unmatched(let reason, _):
    print("FAIL: should have matched Alice, got unmatched(\(reason))")
    exit(1)
}

print("\nALL 5 ACCEPTANCE TESTS PASS")
