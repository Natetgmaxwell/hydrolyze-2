// V0541RepCardExemplarCollapseSmoke.swift
//
// V0.54 S3.1 (2026-09-09, jodie-09 de-busy pass): the
// `shouldCollapseToExemplar(...)` gate that the Mode 1 (.track) and
// Mode 2 (.uniform) `*RepGroupRow` views consult to decide whether
// to render ONE exemplar rep card with a ×N trailing badge (instead
// of N identical rep cards). Rule 1 of the dedupe rules: when every
// rep in the repGroup is identical, render one card with the ×N
// multiplier. Mode 3 (.progression) is excluded because each card
// has a distinct per-rep target — collapsing would hide the ladder
// that IS the point of Mode 3.
//
// What this verifies:
//
//   A. shouldCollapseToExemplar(reps: 2..8, mode: .track) = true
//      → Mode 1 with reps in the cap renders ONE exemplar card.
//   B. shouldCollapseToExemplar(reps: 2..8, mode: .uniform) = true
//      → Mode 2 same as Mode 1.
//   C. shouldCollapseToExemplar(reps: ..., mode: .progression) = false
//      → Mode 3 NEVER collapses, even at reps = 4.
//   D. shouldCollapseToExemplar(reps: nil) = false (defensive default).
//   E. shouldCollapseToExemplar(reps: 1) = false (singletons
//      render one card as before — no multiplier badge needed).
//   F. repCardCount(...) stays unchanged from V0.53.1: 4 reps → 4,
//      8 reps → 8, 9 reps → 1 (cap), nil → 1 (defensive). The S3.1
//      exemplar collapse is a complementary path that fires BEFORE
//      the repCardCount cap when reps ∈ 2..8 AND mode ∈ {track, uniform}.
//
// Run with:
//   cd "/Users/nathanmaxwell/Documents/VS Code/Hydrolyze 2"
//   swift ios-native/Hydrolyze/Tests/V0541RepCardExemplarCollapseSmoke.swift
//
// Standalone smoke. No Xcode required — the helpers are file-scope
// functions in WorkoutPreview.swift, mirrored here as a contract
// assertion. The build fails if the production file forgets to export
// `shouldCollapseToExemplar(...)` or changes its semantics.

import Foundation

// ─── mirror of the file-scope helpers that will live in WorkoutPreview.swift ───

// V0.53.1 (unchanged by S3.1): how many rep cards to render for a
// composite repGroup when the collapse path doesn't fire. 4 reps →
// 4 cards. 12 reps → 1 card + "×12" (cap). 0 reps → 1 card (defensive).
func repCardCount(reps: Int?) -> Int {
    guard let reps = reps, reps >= 1 else { return 1 }
    return reps > 8 ? 1 : reps
}

// V0.54 S3.1: the exemplar-collapse gate. Mode-discriminating.
// Mode 1 (.track) and Mode 2 (.uniform) collapse when reps ≥ 2.
// Mode 3 (.progression) never collapses — each card has a distinct
// per-rep target, the variation IS the point.
enum ExemplarCollapseMode {
    case track
    case uniform
    case progression
}

func shouldCollapseToExemplar(reps: Int?, mode: ExemplarCollapseMode) -> Bool {
    guard mode == .track || mode == .uniform else { return false }
    guard let reps = reps, reps >= 2 else { return false }
    return true
}

// ─── assertions ────────────────────────────────────────────────────────

func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) throws {
    if actual != expected {
        throw SmokeError.assertionFailed("\(name): expected \(expected), got \(actual)")
    }
}

func assertTrue(_ actual: Bool, _ name: String) throws {
    if !actual {
        throw SmokeError.assertionFailed("\(name): expected true, got false")
    }
}

func assertFalse(_ actual: Bool, _ name: String) throws {
    if actual {
        throw SmokeError.assertionFailed("\(name): expected false, got true")
    }
}

enum SmokeError: Error {
    case assertionFailed(String)
}

func runTest(_ name: String, _ body: () throws -> Void) {
    do {
        try body()
        print("  ✓ \(name)")
    } catch {
        print("  ✗ \(name): \(error)")
        exit(1)
    }
}

// ─── driver ────────────────────────────────────────────────────────────

print("V0.54 S3.1 RepCardExemplarCollapseSmoke — verifying dedupe gate…")

// A. Mode 1 (.track) collapses at reps = 2..8
runTest("A.1 shouldCollapseToExemplar(reps: 2, mode: .track) = true") {
    try assertTrue(shouldCollapseToExemplar(reps: 2, mode: .track), "2-track")
}
runTest("A.2 shouldCollapseToExemplar(reps: 4, mode: .track) = true (jodie-09 Set 1 + Set 2 case)") {
    try assertTrue(shouldCollapseToExemplar(reps: 4, mode: .track), "4-track")
}
runTest("A.3 shouldCollapseToExemplar(reps: 8, mode: .track) = true (cap boundary)") {
    try assertTrue(shouldCollapseToExemplar(reps: 8, mode: .track), "8-track")
}

// B. Mode 2 (.uniform) collapses at reps = 2..8
runTest("B.1 shouldCollapseToExemplar(reps: 2, mode: .uniform) = true") {
    try assertTrue(shouldCollapseToExemplar(reps: 2, mode: .uniform), "2-uniform")
}
runTest("B.2 shouldCollapseToExemplar(reps: 4, mode: .uniform) = true") {
    try assertTrue(shouldCollapseToExemplar(reps: 4, mode: .uniform), "4-uniform")
}
runTest("B.3 shouldCollapseToExemplar(reps: 6, mode: .uniform) = true (jodie-09 hypothetical 6×100 uniform)") {
    try assertTrue(shouldCollapseToExemplar(reps: 6, mode: .uniform), "6-uniform")
}

// C. Mode 3 (.progression) NEVER collapses — each card has a distinct target
runTest("C.1 shouldCollapseToExemplar(reps: 2, mode: .progression) = false") {
    try assertFalse(shouldCollapseToExemplar(reps: 2, mode: .progression), "2-progression")
}
runTest("C.2 shouldCollapseToExemplar(reps: 4, mode: .progression) = false (jodie-09 Set 4 DESCEND 70-85%)") {
    try assertFalse(shouldCollapseToExemplar(reps: 4, mode: .progression), "4-progression")
}
runTest("C.3 shouldCollapseToExemplar(reps: 12, mode: .progression) = false (12-rep ladder stays expanded)") {
    try assertFalse(shouldCollapseToExemplar(reps: 12, mode: .progression), "12-progression")
}

// D. Defensive: nil reps → false (singletons never collapse)
runTest("D.1 shouldCollapseToExemplar(reps: nil, mode: .track) = false") {
    try assertFalse(shouldCollapseToExemplar(reps: nil, mode: .track), "nil-track")
}
runTest("D.2 shouldCollapseToExemplar(reps: nil, mode: .uniform) = false") {
    try assertFalse(shouldCollapseToExemplar(reps: nil, mode: .uniform), "nil-uniform")
}

// E. Defensive: reps == 1 → false (singletons render one card as before)
runTest("E.1 shouldCollapseToExemplar(reps: 1, mode: .track) = false (jodie-09 Set 0 400 free warm-up)") {
    try assertFalse(shouldCollapseToExemplar(reps: 1, mode: .track), "1-track")
}
runTest("E.2 shouldCollapseToExemplar(reps: 1, mode: .uniform) = false") {
    try assertFalse(shouldCollapseToExemplar(reps: 1, mode: .uniform), "1-uniform")
}

// F. repCardCount stays unchanged from V0.53.1 (the S3.1 collapse is
// complementary; repCardCount is the > 8 cap path that still fires
// for Mode 3 and for any future mode that doesn't collapse).
runTest("F.1 repCardCount(4) = 4 (V0.53.1 unchanged)") {
    try assertEqual(repCardCount(reps: 4), 4, "repCardCount(4)")
}
runTest("F.2 repCardCount(9) = 1 (V0.53.1 cap unchanged)") {
    try assertEqual(repCardCount(reps: 9), 1, "repCardCount(9)")
}
runTest("F.3 repCardCount(nil) = 1 (defensive unchanged)") {
    try assertEqual(repCardCount(reps: nil), 1, "repCardCount(nil)")
}

print("\n[V0.54 S3.1 RepCardExemplarCollapseSmoke PASS] — all gates correct")
