#!/bin/bash
# V0.38 Slice 3 — WorkoutParser 3MT recognition CLI runner.
#
# Mirrors build_and_run_3mt.sh (slice 2's analyzer gate) and the
# resolver runner's shim pattern: WorkoutPreview.swift is a SwiftUI
# view whose #Preview macro and VocabularyService dependency can't
# compile outside Xcode. We compile a sed-stripped copy (everything
# from the trailing #Preview block onward is dead weight for the
# parser test) plus a minimal VocabularyService.RPERange shim, so
# the Parsed* types the parser emits are the real production types.
set -e
cd "/Users/nathanmaxwell/Documents/VS Code/Hydrolyze 2/ios-native"

OUTDIR="/tmp/hydrolyze-cli-build"
mkdir -p "$OUTDIR"

# Strip the trailing #Preview block from a temp copy of the view file.
# Everything from the #Preview marker to EOF is preview-only.
sed '/^#Preview {/,$d' Hydrolyze/Sources/Views/Components/WorkoutPreview.swift > "$OUTDIR/WorkoutPreview_nopreview.swift"

# Minimal shims: RPEPromptBadge references VocabularyService.RPERange;
# .font(.numeric) resolves through Font.jetBrainsMono whose loader needs
# UIKit — the CLI target is macOS, so we substitute the monospaced-system
# fallback the real implementation already uses when the font is missing.
cat > "$OUTDIR/VocabShim.swift" <<'SHIM'
import SwiftUI
struct VocabularyShim_RPERange: Codable, Hashable {
    var low: Int
    var high: Int
    var label: String { low == high ? "RPE\(low)" : "RPE\(low)-\(high)" }
}
enum Haptics {
    static func warning() { }
}
enum VocabularyService {
    typealias RPERange = VocabularyShim_RPERange
    static let shared = VocabularyServiceDummy()
    static var rpeBuckets: [RPERange] = []
    static func lookupSync(_ term: String) -> RPERange? { nil }
}
struct VocabularyServiceDummy {
    func saveMapping(term: String, rpe: VocabularyShim_RPERange) async { }
}
extension Font {
    static func jetBrainsMono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static let numeric      = jetBrainsMono(size: 15)
    static let numericSmall = jetBrainsMono(size: 11)
    static let numericLarge = jetBrainsMono(size: 22, weight: .bold)
    static let captionStrong = jetBrainsMono(size: 12, weight: .semibold)
    static let eyebrow       = jetBrainsMono(size: 11, weight: .semibold)
}
SHIM

SOURCES=(
  "Hydrolyze/Sources/Models/Enums.swift"
  "Hydrolyze/Sources/Models/FragmentContext.swift"
  "Hydrolyze/Sources/Models/WorkoutSetFragment.swift"
  "Hydrolyze/Sources/Lib/Color+Hex.swift"
  "Hydrolyze/Sources/Lib/HydrolyzeColors.swift"
  "$OUTDIR/VocabShim.swift"
  "$OUTDIR/WorkoutPreview_nopreview.swift"
  "Hydrolyze/Sources/Services/WorkoutParser.swift"
  "Hydrolyze/Tests/CLI/WorkoutParser3MTCLITest.swift"
)

swiftc -O -parse-as-library \
  -o "$OUTDIR/parser3mt-cli-test" \
  "${SOURCES[@]}" 2>&1

echo ""
echo "=== Compiled. Running ==="
echo ""
"$OUTDIR/parser3mt-cli-test"
