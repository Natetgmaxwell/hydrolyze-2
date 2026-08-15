#!/bin/bash
# V0.38 Slice 2 — ThreeMinuteTestAnalyzer CLI runner.
#
# The 3MT analyzer is pure (no Supabase, no async), so it compiles and runs
# standalone on the orchestrator Mac in ~2s. No simulator, no network.
# That is the point: the curve math is the load-bearing logic of the 3MT
# feature and deserves a gate that runs every time, not one that needs a
# booted device.
#
# Exit 0 = all 6 cases passed. Non-zero = a regression in the math or the
# quality flags.
set -e
cd "/Users/nathanmaxwell/Documents/VS Code/Hydrolyze 2/ios-native"

# Source files needed by the CLI test. The analyzer depends on Lap (in
# TimingModels.swift). The test file has the `main` entry point — last.
SOURCES=(
  "Hydrolyze/Sources/Models/Enums.swift"
  "Hydrolyze/Sources/Models/FragmentContext.swift"
  "Hydrolyze/Sources/Models/TimingModels.swift"
  "Hydrolyze/Sources/Services/ThreeMinuteTestAnalyzer.swift"
  "Hydrolyze/Tests/CLI/ThreeMinuteTestCLITest.swift"
)

OUTDIR="/tmp/hydrolyze-cli-build"
mkdir -p "$OUTDIR"

# Compile all sources into a single executable.
# -parse-as-library makes the @main entry callable.
# -O for release-ish perf (irrelevant here, matches the sibling).
swiftc -O -parse-as-library \
  -o "$OUTDIR/3mt-cli-test" \
  "${SOURCES[@]}" 2>&1

echo ""
echo "=== Compiled. Running ==="
echo ""
"$OUTDIR/3mt-cli-test"
