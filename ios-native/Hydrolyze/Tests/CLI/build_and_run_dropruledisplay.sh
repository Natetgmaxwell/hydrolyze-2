#!/bin/bash
# V0.39 Slice 3 — DropRuleDisplay CLI runner.
#
# Pure-helper gate for the inline-badge surface. The interval-to-seconds
# parser and the rep-time / rest-clock formatters live in
# `RestCountdownModel.swift` (the same file as the model) so this
# runner compiles them + the CLI test without UIKit. The VM-side
# wiring (10ms timer gating, view rendering) is UIKit-bound and is
# verified by `swiftc -parse` of the VM and View files (Verify gate
# 5) — the pure helpers carry the test burden for the data path.
#
# Exit 0 = all 4 cases passed. Non-zero = regression in the parser
# or the display formatters.
set -e
cd "/Users/nathanmaxwell/Documents/VS Code/Hydrolyze 2/ios-native"

# Source files needed by the CLI test.
#   - Prediction.swift: nothing in this file is used by the helpers,
#     but RestCountdownModel.swift ignores it (no imports), so the
#     list stays minimal. Listed for parity with the sibling runner.
#   - RestCountdownModel.swift: the new free helpers (intervalToSeconds,
#     formatRepDelta, formatRepTime, formatRestSec) live here.
#   - DropRuleDisplayCLITest.swift: the @main entry, last in the list.
SOURCES=(
  "Hydrolyze/Sources/Models/Prediction.swift"
  "Hydrolyze/Sources/Services/RestCountdownModel.swift"
  "Hydrolyze/Tests/CLI/DropRuleDisplayCLITest.swift"
)

OUTDIR="/tmp/hydrolyze-cli-build"
mkdir -p "$OUTDIR"

# Compile all sources into a single executable.
# -parse-as-library makes the @main entry callable.
# -O for release-ish perf (matches the sibling runners).
swiftc -O -parse-as-library \
  -o "$OUTDIR/dropruledisplay-cli-test" \
  "${SOURCES[@]}" 2>&1

echo ""
echo "=== Compiled. Running ==="
echo ""
"$OUTDIR/dropruledisplay-cli-test"
