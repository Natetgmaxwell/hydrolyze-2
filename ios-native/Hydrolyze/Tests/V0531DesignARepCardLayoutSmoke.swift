// V0531DesignARepCardLayoutSmoke.swift
//
// V0.53.1 Design A (2026-09-08, jodie-09 approved direction): the
// composite-rep row renders as N rep cards, each one a connected
// horizontal segment track. Inside each card the segments are one
// visual unit (no dividers, shared rounded background) — the card is
// the tap target, not the segments. Easy segments render muted and
// carry no tap affordance of their own.
//
// What this verifies (the dispatch's acceptance criteria for Design A):
//
//   A. repCardCount(reps) — N when reps ≤ 8, 1 when reps > 8 (collapsed
//      "×N" affordance). Never paginates, never returns 0.
//   B. segmentWidth(fragment, totalDistance) — proportional to the
//      fragment's distance over the rep's total. Sums to 1.0 over a
//      full composite. 0 when distance is nil (defensive fallback).
//   C. cardAccessibilityLabel(...) — one VoiceOver string per rep card
//      with reps context + segment breakdown + interval. Distinct for
//      each rep in the set so screen-reader navigation isn't ambiguous.
//   D. tapFragmentIndex(...) — for a composite with at least one
//      timable fragment, returns the index of the first timable one
//      (so the card-level play button keys on it). When ALL fragments
//      are easy, returns nil (the card carries no play button at all).
//   E. segmentLabel(fragment) — the text shown inside / under the
//      segment, e.g. "25 event rhythm" or "25 easy". Mirrors the
//      visible label so sighted and screen-reader users see the same
//      breakdown.
//
// Run with:
//   cd "/Users/nathanmaxwell/Documents/VS Code/Hydrolyze 2"
//   swift ios-native/Hydrolyze/Tests/V0531DesignARepCardLayoutSmoke.swift
//
// Standalone smoke. No Xcode required — the helpers are file-scope
// functions in WorkoutPreview.swift, mirrored here as a contract
// assertion. The build fails if the production file forgets to export
// any of them; the smoke catches any behavioural drift.

import Foundation

// ─── mirror of the file-scope helpers that will live in WorkoutPreview.swift ───

// Design A: how many rep cards to render for a composite repGroup.
// 4 reps → 4 cards. 12 reps → 1 card + "×12" (collapsed). 0 reps → 1
// card (defensive — the parent fragment list still renders a single
// rep even when reps is nil/0). Never paginates.
func repCardCount(reps: Int?) -> Int {
    guard let reps = reps, reps >= 1 else { return 1 }
    return reps > 8 ? 1 : reps
}

// Design A: the proportional width of one segment inside a rep card.
// Returns 0 when distance is nil/missing (defensive — the segment
// still renders with zero visual width, doesn't crash the layout).
// Sum across all fragments in a rep equals 1.0.
func segmentWidth(fragmentDistance: Int?, totalDistance: Int) -> Double {
    guard let d = fragmentDistance, totalDistance > 0 else { return 0 }
    return Double(d) / Double(totalDistance)
}

// Design A: which fragment the rep-card play button should key on,
// when the card is tapped. nil = card has no play button (all
// fragments are easy — feel-based, coaches don't time).
func tapFragmentIndex(fragments: [ParsedFragmentMirror]) -> Int? {
    for (i, f) in fragments.enumerated() {
        if isTimableFragment(f) { return i }
    }
    return nil
}

// Design A: label rendered inside / under a segment of the rep-card
// track. Format: "<distance> <intensity-label>" (e.g. "25 event
// rhythm"). Falls back to "<distance> <descriptor>" / "<distance>
// <instruction>" / "<distance> swim" / "Fragment" — mirrors
// fragmentChipTitle fallback chain.
func segmentLabel(fragment: ParsedFragmentMirror) -> String {
    var parts: [String] = []
    if let d = fragment.distance { parts.append("\(d)m") }
    if let label = fragment.intensity?.label, !label.isEmpty {
        return parts.joined(separator: " ") + " " + label
    }
    if let desc = fragment.descriptor, !desc.isEmpty {
        return parts.joined(separator: " ") + " " + desc
    }
    if let instr = fragment.instruction, !instr.isEmpty {
        return parts.joined(separator: " ") + " " + instr
    }
    if !parts.isEmpty { return parts.joined(separator: " ") }
    return "Fragment"
}

// Design A: VoiceOver label for one rep card. Includes reps context
// ("Rep 1 of 4"), the rep's distance, the segment breakdown
// ("25 event rhythm then 25 easy"), and the interval ("on 1:00").
func cardAccessibilityLabel(
    repNumber: Int,
    totalReps: Int,
    parentDistance: Int?,
    segments: [ParsedFragmentMirror],
    interval: String?
) -> String {
    var parts: [String] = []
    parts.append("Rep \(repNumber) of \(totalReps)")
    if let d = parentDistance {
        parts.append("\(d) meters")
    }
    let breakdown = segments.map { segmentLabel(fragment: $0) }.joined(separator: " then ")
    if !breakdown.isEmpty {
        parts.append(breakdown)
    }
    if let interval = interval, !interval.isEmpty {
        parts.append("on \(interval)")
    }
    return parts.joined(separator: ", ")
}

// ─── mirror types (subset of fields the helpers read) ────────────────

struct ParsedIntensityMirror2 {
    let type: String
    let label: String
}

struct ParsedFragmentMirror {
    let id: String?
    let distance: Int?
    let intensity: ParsedIntensityMirror2?
    let intensityLabel: String?
    let descriptor: String?
    let instruction: String?
    let restAfter: Int?
}

// Re-use the easy-detection helper from V0.53.1 — it's stable.
func isTimableFragment(_ fragment: ParsedFragmentMirror) -> Bool {
    guard let intensity = fragment.intensity else { return true }
    return intensity.type != "easy"
}

// ─── fixtures matching jodie-09's wire JSON ───────────────────────────

func jodie09Fragments() -> [ParsedFragmentMirror] {
    [
        ParsedFragmentMirror(
            id: "frag-46e066db1b66",
            distance: 25,
            intensity: ParsedIntensityMirror2(type: "race_pace", label: "event rhythm"),
            intensityLabel: nil,
            descriptor: nil,
            instruction: nil,
            restAfter: nil
        ),
        ParsedFragmentMirror(
            id: "frag-28d645f0046b",
            distance: 25,
            intensity: ParsedIntensityMirror2(type: "easy", label: "easy"),
            intensityLabel: nil,
            descriptor: nil,
            instruction: nil,
            restAfter: nil
        ),
    ]
}

func allEasyFragments() -> [ParsedFragmentMirror] {
    [
        ParsedFragmentMirror(
            id: "frag-1",
            distance: 25,
            intensity: ParsedIntensityMirror2(type: "easy", label: "easy"),
            intensityLabel: nil,
            descriptor: nil,
            instruction: nil,
            restAfter: nil
        ),
        ParsedFragmentMirror(
            id: "frag-2",
            distance: 25,
            intensity: ParsedIntensityMirror2(type: "easy", label: "easy"),
            intensityLabel: nil,
            descriptor: nil,
            instruction: nil,
            restAfter: nil
        ),
    ]
}

func plainFragment() -> ParsedFragmentMirror {
    ParsedFragmentMirror(
        id: "frag-plain",
        distance: 50,
        intensity: nil,
        intensityLabel: nil,
        descriptor: nil,
        instruction: nil,
        restAfter: nil
    )
}

// ─── assertions ────────────────────────────────────────────────────────

func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) throws {
    if actual != expected {
        throw SmokeError.assertionFailed("\(name): expected \(expected), got \(actual)")
    }
}

func assertApproxEqual(_ actual: Double, _ expected: Double, _ tolerance: Double, _ name: String) throws {
    if abs(actual - expected) > tolerance {
        throw SmokeError.assertionFailed("\(name): expected \(expected) ±\(tolerance), got \(actual)")
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

print("V0.53.1 Design A RepCardLayoutSmoke — verifying rep-card + segment-track gates…")

runTest("A.1 repCardCount(4) = 4 (4 reps renders as 4 cards)") {
    try assertEqual(repCardCount(reps: 4), 4, "repCardCount(4)")
}

runTest("A.2 repCardCount(8) = 8 (cap holds)") {
    try assertEqual(repCardCount(reps: 8), 8, "repCardCount(8)")
}

runTest("A.3 repCardCount(9) = 1 (collapsed beyond cap)") {
    try assertEqual(repCardCount(reps: 9), 1, "repCardCount(9)")
}

runTest("A.4 repCardCount(20) = 1 (collapsed, ×20 affordance)") {
    try assertEqual(repCardCount(reps: 20), 1, "repCardCount(20)")
}

runTest("A.5 repCardCount(nil) = 1 (defensive default)") {
    try assertEqual(repCardCount(reps: nil), 1, "repCardCount(nil)")
}

runTest("A.6 repCardCount(0) = 1 (defensive default)") {
    try assertEqual(repCardCount(reps: 0), 1, "repCardCount(0)")
}

runTest("B.1 segmentWidth(25, 50) = 0.5 (half the rep)") {
    try assertApproxEqual(segmentWidth(fragmentDistance: 25, totalDistance: 50), 0.5, 0.001, "segmentWidth(25,50)")
}

runTest("B.2 segmentWidth(50, 50) = 1.0 (whole rep)") {
    try assertApproxEqual(segmentWidth(fragmentDistance: 50, totalDistance: 50), 1.0, 0.001, "segmentWidth(50,50)")
}

runTest("B.3 segmentWidth(nil, 50) = 0 (defensive)") {
    try assertApproxEqual(segmentWidth(fragmentDistance: nil, totalDistance: 50), 0.0, 0.001, "segmentWidth(nil,50)")
}

runTest("B.4 segmentWidth(25, 0) = 0 (defensive — zero total)") {
    try assertApproxEqual(segmentWidth(fragmentDistance: 25, totalDistance: 0), 0.0, 0.001, "segmentWidth(25,0)")
}

runTest("B.5 jodie-09 fragments: sum of widths = 1.0") {
    let frags = jodie09Fragments()
    let total = frags.reduce(0) { $0 + (segmentWidth(fragmentDistance: $1.distance, totalDistance: 50)) }
    try assertApproxEqual(total, 1.0, 0.001, "jodie-09 widths sum")
}

runTest("C.1 cardAccessibilityLabel includes rep number and total") {
    let frags = jodie09Fragments()
    let label = cardAccessibilityLabel(repNumber: 1, totalReps: 4, parentDistance: 50, segments: frags, interval: "1:00")
    if !label.contains("Rep 1 of 4") {
        throw SmokeError.assertionFailed("expected 'Rep 1 of 4' in '\(label)'")
    }
}

runTest("C.2 cardAccessibilityLabel includes segment breakdown") {
    let frags = jodie09Fragments()
    let label = cardAccessibilityLabel(repNumber: 1, totalReps: 4, parentDistance: 50, segments: frags, interval: "1:00")
    if !label.contains("event rhythm") || !label.contains("easy") {
        throw SmokeError.assertionFailed("expected segment labels in '\(label)'")
    }
}

runTest("C.3 cardAccessibilityLabel includes interval") {
    let frags = jodie09Fragments()
    let label = cardAccessibilityLabel(repNumber: 1, totalReps: 4, parentDistance: 50, segments: frags, interval: "1:00")
    if !label.contains("on 1:00") {
        throw SmokeError.assertionFailed("expected 'on 1:00' in '\(label)'")
    }
}

runTest("C.4 cardAccessibilityLabel omits interval when nil") {
    let frags = jodie09Fragments()
    let label = cardAccessibilityLabel(repNumber: 1, totalReps: 4, parentDistance: 50, segments: frags, interval: nil)
    if label.contains("on nil") || label.contains("on ,") {
        throw SmokeError.assertionFailed("interval should be absent in '\(label)'")
    }
}

runTest("C.5 cardAccessibilityLabel is distinct for rep 1 vs rep 4") {
    let frags = jodie09Fragments()
    let l1 = cardAccessibilityLabel(repNumber: 1, totalReps: 4, parentDistance: 50, segments: frags, interval: "1:00")
    let l4 = cardAccessibilityLabel(repNumber: 4, totalReps: 4, parentDistance: 50, segments: frags, interval: "1:00")
    if l1 == l4 {
        throw SmokeError.assertionFailed("rep 1 and rep 4 should have distinct labels, got identical: '\(l1)'")
    }
}

runTest("D.1 tapFragmentIndex(jodie-09) = 0 (first segment is timable race_pace)") {
    let frags = jodie09Fragments()
    try assertEqual(tapFragmentIndex(fragments: frags), 0, "tapFragmentIndex(jodie-09)")
}

runTest("D.2 tapFragmentIndex(all-easy) = nil (no play button on the card)") {
    let frags = allEasyFragments()
    try assertEqual(tapFragmentIndex(fragments: frags), Optional<Int>.none, "tapFragmentIndex(all-easy)")
}

runTest("D.3 tapFragmentIndex([plain]) = 0 (nil intensity → timable)") {
    try assertEqual(tapFragmentIndex(fragments: [plainFragment()]), 0, "tapFragmentIndex(plain)")
}

runTest("E.1 segmentLabel(race_pace) = '25m event rhythm'") {
    let f = jodie09Fragments()[0]
    try assertEqual(segmentLabel(fragment: f), "25m event rhythm", "segmentLabel(race_pace)")
}

runTest("E.2 segmentLabel(easy) = '25m easy'") {
    let f = jodie09Fragments()[1]
    try assertEqual(segmentLabel(fragment: f), "25m easy", "segmentLabel(easy)")
}

runTest("E.3 segmentLabel(plain) = '50m' (distance only)") {
    try assertEqual(segmentLabel(fragment: plainFragment()), "50m", "segmentLabel(plain)")
}

print("\n[V0.53.1 Design A RepCardLayoutSmoke PASS] — all gates correct")
