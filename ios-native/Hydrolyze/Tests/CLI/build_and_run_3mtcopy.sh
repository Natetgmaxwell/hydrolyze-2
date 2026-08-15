#!/bin/bash
# V0.38 Slice 5 — ThreeMTCopy CLI runner.
#
# Pure-logic gate for the NEW 3MT review surface helpers added in
# Slice 5: coach-vocabulary flag→copy mapping, multi-flag joiner,
# critical-speed → per-100m pace conversion, and the deterministic
# signal-color mapping. The runner compiles the production helpers
# (`flagCopy`, `flagCopy(qualityFlags:)`, `thresholdPaceString`,
# `threeMTSignal`) from `ThreeMTReviewSupport.swift` + the
# `SwimmerTestProfile` model + the CLI test file.
#
# The slice-5 spec carves out `ThreeMTReviewSupport.swift`
# (Services/) explicitly so the CLI can compile it without UIKit —
# the helpers live in their own file, NOT as a
# `SessionReviewViewModel` extension, because that VM imports
# SwiftUI + Supabase (the @MainActor Combine timer + the supabase-
# swift client) and the orchestrator Mac's command-line tools
# only ship the macOS SDK, no iOS simulator + no live Supabase
# connection.
#
# Exit 0 = all 4 cases passed. Non-zero = regression in the coach
# vocabulary, the pace conversion, the signal-color mapping, or
# the multi-flag joiner.
set -e
cd "/Users/nathanmaxwell/Documents/VS Code/Hydrolyze 2/ios-native"

# Source files needed by the CLI test.
#   - Enums.swift: dependency closure for the helper module.
#   - ThreeMTReviewSupport.swift: the new Slice 5 file with
#     `SwimmerTestProfile`, `flagCopy(_:)`,
#     `flagCopy(qualityFlags:)`, `thresholdPaceString(_:)`,
#     `threeMTSignal(_:)`. Pure, no UIKit, no Supabase — CLI-
#     friendly.
#   - ThreeMTCopyCLITest.swift: the @main entry, last in the list.
SOURCES=(
  "Hydrolyze/Sources/Models/Enums.swift"
  "Hydrolyze/Sources/Services/ThreeMTReviewSupport.swift"
  "Hydrolyze/Tests/CLI/ThreeMTCopyCLITest.swift"
)

OUTDIR="/tmp/hydrolyze-cli-build"
mkdir -p "$OUTDIR"

# Compile all sources into a single executable.
# -parse-as-library makes the @main entry callable.
# -O for release-ish perf (matches the sibling runners).
swiftc -O -parse-as-library \
  -o "$OUTDIR/3mtcopy-cli-test" \
  "${SOURCES[@]}" 2>&1

echo ""
echo "=== Compiled. Running ==="
echo ""
"$OUTDIR/3mtcopy-cli-test"
