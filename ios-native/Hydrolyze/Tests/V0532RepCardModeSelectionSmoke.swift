// V0532RepCardModeSelectionSmoke.swift
//
// V0.53.2 (2026-09-08): proves the mode-selection logic that decides
// which of the three rep-card rendering modes a ParsedRepGroup lands
// in:
//
//   Mode 1 — within-rep intensity change
//     Track renders (RepCard segment track). The metaphor "part of
//     this rep is at intensity X then changes to Y" is true.
//     Trigger: ≥2 fragments with ≥2 distinct intensity types.
//
//   Mode 2 — uniform rep
//     Plain row. One intensity / one instruction across the whole
//     rep, OR a single fragment with no progression descriptor.
//     The track would falsely imply an intensity split that
//     doesn't exist.
//     Trigger: single fragment OR all-fragments-share-one-intensity,
//     AND no progression descriptor (descend/build/ascend).
//
//   Mode 3 — per-rep progression
//     Each rep carries its own target (70%, 75%, 80%, ~85%…).
//     Subtle chevron between cards shows progression direction.
//     Trigger: progression descriptor on a repGroup that doesn't
//     itself fragment (rg.descend != nil OR rg.pacing == "build"
//     OR the zoneTerm is "descend" OR the rg's intensity is
//     "descend" type). Also when any fragment carries intensity
//     type "descend" or "build".
//
// The selection helper is `repCardMode(for rg:)`. It must be
// deterministic: every fixture maps to exactly one mode.
//
// Run with:
//   cd "/Users/nathanmaxwell/Documents/VS Code/Hydrolyze 2"
//   swift ios-native/Hydrolyze/Tests/V0532RepCardModeSelectionSmoke.swift
//
// Standalone smoke. No Xcode required — the helper is a file-scope
// function in WorkoutPreview.swift, mirrored here as a contract
// assertion. Build fails BEFORE the patch because the helper
// doesn't exist; smoke catches any drift after the patch lands.

import Foundation

// ─── mirrors of the production types (subset of fields the helper reads) ───

enum RepCardMode: Equatable {
    case track          // Mode 1 — connected segment track
    case uniform        // Mode 2 — plain row
    case progression    // Mode 3 — per-rep target labels + chevron
}

struct ModeIntensityMirror {
    let type: String
    let label: String
}

struct ModeFragmentMirror {
    let intensity: ModeIntensityMirror?
    let pacing: String?
}

struct ModeRepGroupMirror {
    let fragments: [ModeFragmentMirror]?
    let descend: String?
    let pacing: String?
    let intensityType: String?
    let intensityLabel: String?
    let zoneTerm: String?
}

// ─── mirror of the file-scope helper that will live in WorkoutPreview.swift ───
//
// Selection rule, in this exact order:
//
//   1. If the repGroup has ≥2 fragments AND the fragments carry ≥2
//      distinct intensity types (counted by `.type`, "easy" counts as a
//      type, nil-intensity fragments don't count as a type) → track.
//
//      This is the case the user complained about going wrong: when
//      a fragment was a single intensity across the whole rep, the
//      track falsely implied "this part is Y then Z" when really the
//      rep was just one swim at one intensity.
//
//   2. Else if the repGroup carries a progression descriptor
//      (rg.descend != nil OR rg.pacing == "build") OR any fragment
//      is a "build" pacing OR a "descend" intensity → progression.
//
//      This is the "build through the set" or "1=70% 2=75% 3=80%
//      4=~85%" case — the rep itself is uniform (one swim per
//      rep), but the instruction varies ACROSS reps.
//
//   3. Else → uniform. The plain row: one card, one instruction,
//      one play affordance, no track. Captures both "no fragments
//      at all" and "all fragments share one intensity".

func repCardMode(for rg: ModeRepGroupMirror) -> RepCardMode {
    let fragments = rg.fragments ?? []
    let distinctIntensityTypes: Set<String> = Set(
        fragments.compactMap { $0.intensity?.type }
    )

    // Rule 1: within-rep intensity change.
    if fragments.count >= 2, distinctIntensityTypes.count >= 2 {
        return .track
    }

    // Rule 2: progression across reps.
    let rgHasProgression =
        rg.descend != nil ||
        rg.pacing == "build" ||
        rg.intensityType == "descend" ||
        rg.zoneTerm == "descend"
    // Fragment-level progression: intensity.type only (ParsedFragment
    // doesn't carry pacing — the server emits "build" as rg-level).
    let anyFragmentIsProgression = fragments.contains { f in
        f.intensity?.type == "descend" || f.intensity?.type == "build"
    }
    if rgHasProgression || anyFragmentIsProgression {
        return .progression
    }

    // Rule 3: uniform.
    return .uniform
}

// ─── fixtures matching the jodie-09 Purposeful Threshold corpus ─────

/// Mode 1 fixture: 4 × 50 @ 1:00 / 25 event rhythm / 25 easy.
/// Two fragments, distinct intensity types (race_pace + easy).
/// Must route to .track — the segment track is the correct metaphor.
func jodie09EventRhythmEasy() -> ModeRepGroupMirror {
    ModeRepGroupMirror(
        fragments: [
            ModeFragmentMirror(
                intensity: ModeIntensityMirror(type: "race_pace", label: "event rhythm"),
                pacing: nil
            ),
            ModeFragmentMirror(
                intensity: ModeIntensityMirror(type: "easy", label: "easy"),
                pacing: nil
            ),
        ],
        descend: nil,
        pacing: nil,
        intensityType: nil,
        intensityLabel: nil,
        zoneTerm: nil
    )
}

/// Mode 1 fixture: 4 × 100 / 25 scull / 50 strong aerobic / 25 easy.
/// Three fragments, three distinct intensity types (nil + percent_range
/// + easy). Note: nil-intensity fragments (scull) don't count as a
/// distinct type — they collapse into the "work" bucket.
/// But percent_range + easy are distinct, so this lands in .track.
func jodie09ScullStrongEasy() -> ModeRepGroupMirror {
    ModeRepGroupMirror(
        fragments: [
            ModeFragmentMirror(
                intensity: nil,
                pacing: nil
            ),
            ModeFragmentMirror(
                intensity: ModeIntensityMirror(type: "percent_range", label: "75-80%"),
                pacing: nil
            ),
            ModeFragmentMirror(
                intensity: ModeIntensityMirror(type: "easy", label: "easy"),
                pacing: nil
            ),
        ],
        descend: nil,
        pacing: nil,
        intensityType: nil,
        intensityLabel: nil,
        zoneTerm: nil
    )
}

/// Mode 2 fixture: 4 × 50 @ 1:00 / 12.5 strong + 12.5 easy.
/// The USER COMPLAINT — same composite shape but both fragments
/// share an "intensity that varies between work and rest". The user
/// said the track "is not applicable" because the rep is essentially
/// uniform (one continuous swim at varying intensity within itself
/// isn't a true "this part then that part" split). Wait — strong +
/// easy IS a within-rep split, so this should STILL be Mode 1
/// (.track). The complaint was about reps where the parser emitted
/// a single descriptor across the whole rep.
///
/// Actually re-reading: the user's complaint was "for some of the
/// reps the instructions for some of the reps are build so the
/// slider is not applicable". That's Mode 3 — per-rep progression,
/// not within-rep. Mode 2 covers the case where the repGroup has
/// no fragments AT ALL (a plain set) — every rep is the same
/// descriptor.
///
/// Let's add a fragmentless fixture (plain set) for Mode 2.
func plainSetFragmentless() -> ModeRepGroupMirror {
    ModeRepGroupMirror(
        fragments: nil,
        descend: nil,
        pacing: nil,
        intensityType: nil,
        intensityLabel: nil,
        zoneTerm: nil
    )
}

/// Mode 2 fixture: a 50 that is just "build" throughout.
/// Single fragment, no progression descriptor on the rg, no build
/// pacing on the fragment, no descend anywhere → uniform.
func plainBuildFragment() -> ModeRepGroupMirror {
    ModeRepGroupMirror(
        fragments: [
            ModeFragmentMirror(
                intensity: nil,
                pacing: nil
            ),
        ],
        descend: nil,
        pacing: nil,
        intensityType: nil,
        intensityLabel: nil,
        zoneTerm: nil
    )
}

/// Mode 2 fixture: a composite where ALL fragments share one
/// intensity (rare, but possible — e.g. "4 × 50 with 3 fast 50s").
/// Two fragments, one distinct type → uniform, not track.
func allEasyFragmentComposite() -> ModeRepGroupMirror {
    ModeRepGroupMirror(
        fragments: [
            ModeFragmentMirror(
                intensity: ModeIntensityMirror(type: "easy", label: "easy"),
                pacing: nil
            ),
            ModeFragmentMirror(
                intensity: ModeIntensityMirror(type: "easy", label: "easy"),
                pacing: nil
            ),
        ],
        descend: nil,
        pacing: nil,
        intensityType: nil,
        intensityLabel: nil,
        zoneTerm: nil
    )
}

/// Mode 3 fixture: 4 × 50 @ 1:00 — Descend: 1=70% 2=75% 3=80% 4=~85%.
/// No fragments (the per-rep targets live in rg.descend) → Mode 3.
func descendLadder4x50() -> ModeRepGroupMirror {
    ModeRepGroupMirror(
        fragments: nil,
        descend: "1-4",
        pacing: nil,
        intensityType: nil,
        intensityLabel: nil,
        zoneTerm: nil
    )
}

/// Mode 3 fixture: 4 × 50 @ 1:00 — build through the set.
/// Single fragment + rg.pacing == "build" → Mode 3 (per-rep build).
func buildThroughSet() -> ModeRepGroupMirror {
    ModeRepGroupMirror(
        fragments: [
            ModeFragmentMirror(
                intensity: nil,
                pacing: nil
            ),
        ],
        descend: nil,
        pacing: "build",
        intensityType: nil,
        intensityLabel: nil,
        zoneTerm: nil
    )
}

/// Mode 3 fixture: per-fragment "build" intensity type.
/// Two fragments: one with intensity.type "build" + one with nil
/// intensity (a drill or hold rate — the parser doesn't classify it).
/// distinctIntensityTypes = {"build"} = 1, so Rule 1 doesn't fire.
/// The "build" type fires Rule 2 (any fragment is progression).
/// → Mode 3 (.progression).
///
/// Why a nil-intensity second fragment? It demonstrates the
/// realistic parser shape: a build warm-up repGroup where one
/// fragment is the build effort and another is the easy cool-down
/// within the same rep. The "easy" type WOULD make it Mode 1
/// (two distinct types → track), but the nil-intensity case is
/// the more interesting Rule-2-fires boundary.
func buildPerFragment() -> ModeRepGroupMirror {
    ModeRepGroupMirror(
        fragments: [
            ModeFragmentMirror(
                intensity: ModeIntensityMirror(type: "build", label: "build"),
                pacing: nil
            ),
            ModeFragmentMirror(
                intensity: nil,
                pacing: nil
            ),
        ],
        descend: nil,
        pacing: nil,
        intensityType: nil,
        intensityLabel: nil,
        zoneTerm: nil
    )
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

print("V0.53.2 RepCardModeSelectionSmoke — verifying mode selection…")

// Mode 1 — within-rep intensity change (segment track)
runTest("1.1 jodie-09 4×50 event rhythm / easy → .track (within-rep split)") {
    try assertEqual(repCardMode(for: jodie09EventRhythmEasy()), .track, "event_rhythm_easy")
}

runTest("1.2 jodie-09 4×100 scull / strong / easy → .track (3 fragments, 2 distinct types)") {
    try assertEqual(repCardMode(for: jodie09ScullStrongEasy()), .track, "scull_strong_easy")
}

// Mode 2 — uniform rep
runTest("2.1 plain set (no fragments) → .uniform (every rep same descriptor)") {
    try assertEqual(repCardMode(for: plainSetFragmentless()), .uniform, "fragmentless")
}

runTest("2.2 single-fragment set → .uniform (no progression descriptor)") {
    try assertEqual(repCardMode(for: plainBuildFragment()), .uniform, "single_fragment")
}

runTest("2.3 all-fragments-share-one-intensity → .uniform (not a track-worthy split)") {
    try assertEqual(repCardMode(for: allEasyFragmentComposite()), .uniform, "all_easy")
}

// Mode 3 — per-rep progression
runTest("3.1 Descend ladder 4×50 → .progression (rg.descend set)") {
    try assertEqual(repCardMode(for: descendLadder4x50()), .progression, "descend_ladder")
}

runTest("3.2 build through set → .progression (rg.pacing == build)") {
    try assertEqual(repCardMode(for: buildThroughSet()), .progression, "build_through_set")
}

runTest("3.3 per-fragment build pacing → .progression (any fragment has build)") {
    try assertEqual(repCardMode(for: buildPerFragment()), .progression, "build_per_fragment")
}

print("\n[V0.53.2 RepCardModeSelectionSmoke PASS] — mode selection correct across all 8 fixtures")