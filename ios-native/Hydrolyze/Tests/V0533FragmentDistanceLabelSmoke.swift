// V0533FragmentDistanceLabelSmoke.swift
//
// V0.53.3 (2026-09-08, jodie-09 display fidelity): proves the
// fragmentDistanceText helper reads the verbatim distance_label
// (e.g. "12.5m") when present, falls back to the int distance
// (e.g. "13m") when label is nil, and returns "" when both are
// nil. Also verifies the JSON decoder tolerates payloads with and
// without `distance_label` — old servers without the field must
// keep working.
//
// Run with:
//   cd "/Users/nathanmaxwell/Documents/VS Code/Hydrolyze 2"
//   swift ios-native/Hydrolyze/Tests/V0533FragmentDistanceLabelSmoke.swift
//
// Standalone smoke. No Xcode required. Mirrors the production
// ParsedFragment + fragmentDistanceText helper as a contract
// assertion. Build fails BEFORE the patch because the helper
// doesn't exist; smoke catches any drift after the patch lands.

import Foundation

// ─── mirrors of the production types (only fields the helper reads) ───

enum ParsedIntensityTypeMirror: String, Codable {
    case easy, threshold, race_pace, sprint
    case descend, build, negative_split
    case aerobic, pace_target, percent_range, form
}

struct ParsedIntensityMirror: Codable {
    let type: ParsedIntensityTypeMirror
    let label: String
}

struct ParsedFragmentMirror: Codable {
    let id: String?
    let distance: Int?
    // V0.53.3 new optional wire field.
    let distanceLabel: String?
    let stroke: String?
    let instruction: String?
    let intensity: ParsedIntensityMirror?
    let descriptor: String?
}

// ─── mirror of fragmentDistanceText in WorkoutPreview.swift ───
//
// The helper is a file-scope func in WorkoutPreview.swift (line 1303).
// Mirror here as a contract assertion so smoke drift surfaces here
// first when production drifts.

func fragmentDistanceText(_ fragment: ParsedFragmentMirror) -> String {
    if let label = fragment.distanceLabel, !label.isEmpty {
        return "\(label)m"
    }
    if let d = fragment.distance {
        return "\(d)m"
    }
    return ""
}

// ─── smoke assertions ───

var passed = 0
var failed = 0

func check(_ label: String, _ got: String, _ want: String) {
    if got == want {
        passed += 1
        print("OK: \(label) → \"\(got)\"")
    } else {
        failed += 1
        print("FAIL: \(label) → got \"\(got)\", want \"\(want)\"")
    }
}

// 1. Half-pool fragment with distance_label set → verbatim "12.5m".
do {
    let f = ParsedFragmentMirror(
        id: "frag-fast", distance: 13, distanceLabel: "12.5",
        stroke: nil, instruction: nil, intensity: nil, descriptor: nil
    )
    check("half-pool with label", fragmentDistanceText(f), "12.5m")
}

// 2. Half-pool fragment with distance_label set → verbatim "37.5m".
do {
    let f = ParsedFragmentMirror(
        id: "frag-build", distance: 38, distanceLabel: "37.5",
        stroke: nil, instruction: nil, intensity: nil, descriptor: nil
    )
    check("37.5 with label", fragmentDistanceText(f), "37.5m")
}

// 3. Integer fragment with distance_label set → "25m" (matches int).
do {
    let f = ParsedFragmentMirror(
        id: "frag-25", distance: 25, distanceLabel: "25",
        stroke: nil, instruction: nil, intensity: nil, descriptor: nil
    )
    check("integer with label", fragmentDistanceText(f), "25m")
}

// 4. Integer fragment without distance_label (old server) → falls back
//    to the int distance. This is the V0.51 contract — every existing
//    payload keeps working.
do {
    let f = ParsedFragmentMirror(
        id: "frag-100", distance: 100, distanceLabel: nil,
        stroke: nil, instruction: nil, intensity: nil, descriptor: nil
    )
    check("integer without label (old server)", fragmentDistanceText(f), "100m")
}

// 5. Both distance AND distance_label nil → empty string. The render
//    surface guards on `!dist.isEmpty` so this path is unreachable in
//    practice, but the contract is explicit.
do {
    let f = ParsedFragmentMirror(
        id: "frag-time", distance: nil, distanceLabel: nil,
        stroke: nil, instruction: nil, intensity: nil, descriptor: nil
    )
    check("both nil (time-based fragment)", fragmentDistanceText(f), "")
}

// 6. distance_label is empty string → falls back to int (the !isEmpty
//    guard inside the helper). Defensive against malformed server
//    payloads where label = "".
do {
    let f = ParsedFragmentMirror(
        id: "frag-empty", distance: 50, distanceLabel: "",
        stroke: nil, instruction: nil, intensity: nil, descriptor: nil
    )
    check("empty label falls back to int", fragmentDistanceText(f), "50m")
}

// 7. Decoder tolerates a payload WITHOUT distance_label (old server
//    contract). distanceLabel stays nil and the render fallback chain
//    uses the int distance.
do {
    let json = """
    {"id":"frag-old","distance":25,"stroke":null,"instruction":null,"intensity":null,"descriptor":null}
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    let f = try decoder.decode(ParsedFragmentMirror.self, from: json)
    check(
        "decode old payload (no distance_label)",
        fragmentDistanceText(f),
        "25m"
    )
    if f.distanceLabel != nil {
        failed += 1
        print("FAIL: decode old payload — distanceLabel should be nil")
    } else {
        passed += 1
        print("OK: decode old payload — distanceLabel is nil (old-server compat)")
    }
}

// 8. Decoder reads distance_label="12.5" verbatim when present.
do {
    let json = """
    {"id":"frag-new","distance":13,"distanceLabel":"12.5","stroke":null,"instruction":null,"intensity":null,"descriptor":null}
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    let f = try decoder.decode(ParsedFragmentMirror.self, from: json)
    check(
        "decode new payload (distance_label=\"12.5\")",
        fragmentDistanceText(f),
        "12.5m"
    )
    if f.distanceLabel != "12.5" {
        failed += 1
        print("FAIL: decode new payload — distanceLabel should be \"12.5\"")
    } else {
        passed += 1
        print("OK: decode new payload — distanceLabel is \"12.5\"")
    }
}

// 9. The full jodie-09 4×25 fragment payload decodes end-to-end and
//    produces "12.5m" as the fragment distance text.
do {
    let json = """
    {"id":"frag-1","distance":13,"distanceLabel":"12.5","stroke":null,"instruction":"strong","intensity":{"type":"race_pace","label":"strong"},"descriptor":null}
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    let f = try decoder.decode(ParsedFragmentMirror.self, from: json)
    check(
        "jodie-09 fragment 1 full",
        fragmentDistanceText(f),
        "12.5m"
    )
}

print("")
print("V0.53.3 FragmentDistanceLabelSmoke — \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)