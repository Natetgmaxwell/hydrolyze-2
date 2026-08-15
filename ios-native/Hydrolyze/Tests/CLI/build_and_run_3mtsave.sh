#!/bin/bash
# V0.38 Slice 4 — ThreeMTSave CLI runner.
#
# Pure-logic gate for the NEW 3MT save-flow pieces added in
# Slice 4: trial-number increment, per-swimmer split grouping,
# analyzer wiring, profile row assembly, and quality-flags
# rawValue forwarding. The runner compiles the production
# helpers (`groupSplitsPerSwimmer`, `assembleTestProfiles`,
# `TestProfileRow`) + the real `ThreeMinuteTestAnalyzer` +
# `LapAssignment` model + the supporting model layer.
#
# The slice-4 spec carves out `ThreeMinuteTestSaveSupport.swift`
# (Services/) explicitly so the CLI can compile it without
# UIKit — the helpers live in their own file, NOT as a
# TimingViewModel extension, because TimingViewModel imports
# UIKit (the @MainActor Combine timer) and the orchestrator
# Mac's command-line tools only ship the macOS SDK, no
# iOS simulator.
#
# Exit 0 = all 5 cases passed. Non-zero = regression in the
# trial-number math, split grouping, analyzer wiring, or
# quality-flags forwarding.
set -e
cd "/Users/nathanmaxwell/Documents/VS Code/Hydrolyze 2/ios-native"

# Source files needed by the CLI test.
#   - Enums.swift, FragmentContext.swift, LapAssignment.swift,
#     TimingModels.swift: dependency closure for the Lap type
#     and the helpers' parameters.
#   - ThreeMinuteTestAnalyzer.swift: the real analyzer the
#     helpers wire into (no copy in the test).
#   - ThreeMinuteTestSaveSupport.swift: the new Slice 4
#     file with `groupSplitsPerSwimmer`, `assembleTestProfiles`,
#     `TestProfileRow`. Pure, no UIKit — CLI-friendly.
#   - ThreeMTSaveCLITest.swift: the @main entry, last in the list.
SOURCES=(
  "Hydrolyze/Sources/Models/Enums.swift"
  "Hydrolyze/Sources/Models/FragmentContext.swift"
  "Hydrolyze/Sources/Models/LapAssignment.swift"
  "Hydrolyze/Sources/Models/TimingModels.swift"
  "Hydrolyze/Sources/Services/ThreeMinuteTestAnalyzer.swift"
  "Hydrolyze/Sources/Services/ThreeMinuteTestSaveSupport.swift"
  "Hydrolyze/Tests/CLI/ThreeMTSaveCLITest.swift"
)

OUTDIR="/tmp/hydrolyze-cli-build"
mkdir -p "$OUTDIR"

# Compile all sources into a single executable.
# -parse-as-library makes the @main entry callable.
# -O for release-ish perf (matches the sibling runners).
swiftc -O -parse-as-library \
  -o "$OUTDIR/3mtsave-cli-test" \
  "${SOURCES[@]}" 2>&1

echo ""
echo "=== Compiled. Running ==="
echo ""
"$OUTDIR/3mtsave-cli-test"