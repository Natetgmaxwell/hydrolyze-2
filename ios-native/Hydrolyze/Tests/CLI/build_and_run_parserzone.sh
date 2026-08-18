#!/bin/bash
# V0.41 Slice 1 — WorkoutParser zone_term extraction CLI runner.
#
# Mirrors build_and_run_parser3mt.sh: WorkoutPreview.swift is a SwiftUI
# view whose #Preview macro + VocabularyService dependency can't compile
# outside Xcode, so we compile a sed-stripped copy plus a minimal
# VocabularyService shim, so the Parsed* types are the real production
# types.
set -e
cd "/Users/nathanmaxwell/Documents/VS Code/Hydrolyze 2/ios-native"

OUTDIR="/tmp/hydrolyze-cli-build"
mkdir -p "$OUTDIR"

# Strip the trailing #Preview block from a temp copy of the view file.
sed '/^#Preview {/,$d' Hydrolyze/Sources/Views/Components/WorkoutPreview.swift > "$OUTDIR/WorkoutPreview_nopreview.swift"

# Minimal shims (same as parser3mt runner).
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
  "Hydrolyze/Tests/CLI/WorkoutParserZoneCLITest.swift"
)

swiftc -O -parse-as-library \
  -o "$OUTDIR/parserzone-cli-test" \
  "${SOURCES[@]}" 2>&1

echo ""
echo "=== Compiled. Running ==="
echo ""
"$OUTDIR/parserzone-cli-test"
