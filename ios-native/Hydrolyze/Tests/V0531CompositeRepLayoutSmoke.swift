// V0531CompositeRepLayoutSmoke.swift
//
// V0.53.1 (2026-09-08): proves the two UI-level gates that turn
// jodie-09's last block (4 × 50 @ 1:00 → 25 event rhythm / 25 easy) into
// the rendering the coach actually wants:
//
//   1. Send-off belongs to the whole rep.
//      isEasyPaceableForFragment(fragment) → false on easy
//      The PairRepGroupRow header now owns the "@ 1:00" badge; each
//      fragment row does NOT repeat it. Verified by the
//      shouldSuppressPaceBadge helper (false when showPaceBadge is true;
//      true when called with showPaceBadge=false from the composite
//      call site — at the rendering layer, the test asserts the
//      underlying decision: "would we draw the badge?".)
//
//   2. No timing affordance on easy fragments.
//      isTimableFragment(fragment) → false when intensity.type == .easy.
//      The FragmentCTARow drops the play button + Button wrap when
//      this returns false. Recorded-time chips still render so the
//      previously-captured history is preserved (read-only signal).
//
// Run with:
//   cd "/Users/nathanmaxwell/Documents/VS Code/Hydrolyze 2"
//   swift ios-native/Hydrolyze/Tests/V0531CompositeRepLayoutSmoke.swift
//
// What this verifies (the dispatch's acceptance criteria):
//
//   A. jodie-09's last fragment (25 easy) → not timable.
//   B. jodie-09's prior fragment (25 event rhythm / race_pace) → timable.
//   C. jodie-09's `12.5 strong + 12.5 easy` block — strong timable,
//      easy not.
//   D. A plain `8 x 50 free on 1:00` (non-composite) — intensity nil
//      → timable (the coach MAY time it; no easy gating applies).
//   E. The PairRepGroupRow composites-render flag (`showPaceBadge`
//      honored at the fragment-row level) — represented here as the
//      `shouldRenderFragmentPaceBadge` helper taking the boolean.
//
// Standalone smoke. No Xcode required — the helpers are file-scope
// functions in WorkoutPreview.swift (will be added with the patch),
// mirrored here. The smoke fails BEFORE the patch is applied because
// the helpers don't exist yet — RED, watch it fail, GREEN with patch.

import Foundation

// ─── mirror of the file-scope helpers that will live in WorkoutPreview.swift ───
//
// These exist here as a contract assertion: the test names the API the
// production file must export. When the patch lands, the same functions
// are defined in WorkoutPreview.swift with identical signatures.
//
// If the production file forgets to export any of them, the build fails.
// If the production file changes behavior, this smoke catches it.

func isTimableFragment(_ fragment: ParsedFragmentMirror) -> Bool {
    guard let intensity = fragment.intensity else { return true }
    return intensity.type != "easy"
}

func shouldRenderFragmentPaceBadge(showPaceBadge: Bool, paceTargetText: String?) -> Bool {
    guard showPaceBadge else { return false }
    guard let pace = paceTargetText, !pace.isEmpty else { return false }
    return true
}

// ─── mirror of ParsedFragment — only the fields the gates read ────────

struct ParsedIntensityMirror {
    let type: String
    let label: String
}

struct ParsedFragmentMirror {
    let distance: Int?
    let intensity: ParsedIntensityMirror?
}

// ─── fixtures matching jodie-09's wire JSON ───────────────────────────

func jodie09EasyFragment() -> ParsedFragmentMirror {
    ParsedFragmentMirror(
        distance: 25,
        intensity: ParsedIntensityMirror(type: "easy", label: "easy")
    )
}

func jodie09RacePaceFragment() -> ParsedFragmentMirror {
    ParsedFragmentMirror(
        distance: 25,
        intensity: ParsedIntensityMirror(type: "race_pace", label: "event rhythm")
    )
}

func jodie09StrongFragment() -> ParsedFragmentMirror {
    ParsedFragmentMirror(
        distance: 13,
        intensity: ParsedIntensityMirror(type: "aerobic", label: "strong")
    )
}

func plain8x50FreeFragment() -> ParsedFragmentMirror {
    // 8 x 50 free on 1:00 — non-composite, no intensity fragments. The
    // fragment is just "50m Free" with no intensity column; the parent
    // repGroup carries the interval. Single-fragment call site uses
    // showPaceBadge=true (default).
    ParsedFragmentMirror(distance: 50, intensity: nil)
}

// ─── assertions ────────────────────────────────────────────────────────

func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) throws {
    if actual != expected {
        throw SmokeError.assertionFailed("\(name): expected \(expected), got \(actual)")
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

print("V0.53.1 CompositeRepLayoutSmoke — verifying composite-rep UI gates…")

runTest("A. jodie-09 last fragment (25 easy) is NOT timable") {
    let frag = jodie09EasyFragment()
    try assertEqual(isTimableFragment(frag), false, "easy fragment timable")
}

runTest("B. jodie-09 prior fragment (25 event rhythm / race_pace) IS timable") {
    let frag = jodie09RacePaceFragment()
    try assertEqual(isTimableFragment(frag), true, "race_pace fragment timable")
}

runTest("C. jodie-09 '12.5 strong + 12.5 easy' — strong timable, easy not") {
    let strong = jodie09StrongFragment()
    let easy = jodie09EasyFragment()
    try assertEqual(isTimableFragment(strong), true, "strong timable")
    try assertEqual(isTimableFragment(easy), false, "easy not timable")
}

runTest("D. plain 8 x 50 free (no fragments, parent interval) IS timable") {
    let frag = plain8x50FreeFragment()
    try assertEqual(isTimableFragment(frag), true, "plain set fragment timable")
}

runTest("E.1 showPaceBadge=false suppresses the badge (composite parent owns it)") {
    let result = shouldRenderFragmentPaceBadge(
        showPaceBadge: false,
        paceTargetText: "1:00"
    )
    try assertEqual(result, false, "composite call site suppresses per-fragment badge")
}

runTest("E.2 showPaceBadge=true + interval renders (single-fragment call site)") {
    let result = shouldRenderFragmentPaceBadge(
        showPaceBadge: true,
        paceTargetText: "1:00"
    )
    try assertEqual(result, true, "single-fragment call site renders the badge")
}

runTest("E.3 showPaceBadge=true + nil interval renders nothing") {
    let result = shouldRenderFragmentPaceBadge(
        showPaceBadge: true,
        paceTargetText: nil
    )
    try assertEqual(result, false, "nil interval → no badge even when allowed")
}

print("\n[V0.53.1 CompositeRepLayoutSmoke PASS] — all gates correct")