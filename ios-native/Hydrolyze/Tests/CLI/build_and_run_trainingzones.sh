#!/bin/bash
# V0.40 Slice 1 — TrainingZoneService CLI runner.
#
# Pure-logic gate for the new zone-derivation service. Compiles
# the production helper (`TrainingZoneService` + its sole dep
# `thresholdPaceString` from `ThreeMTReviewSupport.swift`) plus
# the CLI test file into a standalone macOS executable, then
# runs it. No simulator, no Supabase, no UIKit — the orchestrator
# Mac only ships the macOS SDK, so the test is a vanilla
# swiftc -parse-as-library invocation.
#
# Source-file closure (slice-1 spec, line 64):
#   - ThreeMTReviewSupport.swift: `thresholdPaceString` (pace
#     stringifier reused as-is for the per-100m zone paces) +
#     `SwimmerTestProfile` (unused by the test, but compiles in
#     cleanly since the file is self-contained: Foundation only,
#     no model deps).
#   - TrainingZoneService.swift: the new Slice 1 file with
#     `TrainingZoneService`, `TrainingZones`, `PacePer100m`.
#     Pure, no UIKit, no Combine, no async, no Supabase —
#     CLI-friendly.
#   - TrainingZonesCLITest.swift: the @main entry, last in the
#     list so swiftc sees it as the executable target.
#
# No Enums.swift needed (the spec is explicit: NO — only if
# TrainingZoneService references IntensityLevel, and the zone
# math does not).
#
# Exit 0 = all 7 cases passed. Non-zero = regression in the
# boundary math, the pace rendering, the peak clamp, the nil-on-
# bad-CS contract, or the invalid-peak fallback.
set -e
cd "/Users/nathanmaxwell/Documents/VS Code/Hydrolyze 2/ios-native"

SOURCES=(
  "Hydrolyze/Sources/Services/ThreeMTReviewSupport.swift"
  "Hydrolyze/Sources/Services/TrainingZoneService.swift"
  "Hydrolyze/Tests/CLI/TrainingZonesCLITest.swift"
)

OUTDIR="/tmp/hydrolyze-cli-build"
mkdir -p "$OUTDIR"

# Compile all sources into a single executable.
# -parse-as-library makes the @main entry callable.
# -O for release-ish perf (matches the sibling runners).
swiftc -O -parse-as-library \
  -o "$OUTDIR/trainingzones-cli-test" \
  "${SOURCES[@]}" 2>&1

echo ""
echo "=== Compiled. Running ==="
echo ""
"$OUTDIR/trainingzones-cli-test"
