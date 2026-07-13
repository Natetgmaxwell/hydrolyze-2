#!/bin/bash
set -e
cd "/Users/nathanmaxwell/Documents/VS Code/Hydrolyze 2/ios-native"

# Source files needed by the CLI test (all in the Hydrolyze target).
# Order doesn't matter for compile, but the test file needs to be last
# because it has the `main` entry point.
SOURCES=(
  "Hydrolyze/Sources/Lib/Color+Hex.swift"
  "Hydrolyze/Sources/Lib/RPEParser.swift"
  "Hydrolyze/Sources/Models/Enums.swift"
  "Hydrolyze/Sources/Models/Coach.swift"
  "Hydrolyze/Sources/Models/CoachPreferences.swift"
  "Hydrolyze/Sources/Models/Swimmer.swift"
  "Hydrolyze/Sources/Models/TimingModels.swift"
  "Hydrolyze/Sources/Models/WaveAssignment.swift"
  "Hydrolyze/Sources/Models/LapAssignment.swift"
  "Hydrolyze/Sources/Models/Prediction.swift"
  "Hydrolyze/Sources/Models/RecordedTime.swift"
  "Hydrolyze/Sources/Models/Workout.swift"
  "Hydrolyze/Sources/Services/HungarianMatching.swift"
  "Hydrolyze/Sources/Services/SpeedCurveFitter.swift"
  "Hydrolyze/Sources/Services/HistoricalTimePredictor.swift"
  "Hydrolyze/Sources/Services/PBService.swift"
  "Hydrolyze/Sources/Services/PairingEngine.swift"
  "Hydrolyze/Tests/CLI/PairingEngineCLITest.swift"
)

OUTDIR="/tmp/hydrolyze-cli-build"
mkdir -p "$OUTDIR"

# Compile all sources into a single executable.
# -parse-as-library makes the top-level `main` callable.
# -O for release-ish perf (the Gaussian noise is hot).
# macOS-only (we run on the orchestrator Mac, no iOS frameworks needed).
swiftc -O -parse-as-library \
  -o "$OUTDIR/pairing-cli-test" \
  "${SOURCES[@]}" 2>&1

echo ""
echo "=== Compiled. Running ==="
echo ""
"$OUTDIR/pairing-cli-test"
