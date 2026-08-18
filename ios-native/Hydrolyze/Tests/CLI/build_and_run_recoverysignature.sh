#!/bin/bash
# V0.42 Slice 1 — RecoverySignature CLI runner.
#
# Pure-logic gate for the recovery-signature aggregator: median at
# first strike per (swimmer, set), average delta + extended rest
# across strike rows, revert rate, weekly trend bucketing (ISO
# weeks, Monday-start), the coachSignatureLine copy, the
# coachRevertFlag copy + threshold, and the rep-count approximation.
#
# The runner compiles the production `RecoverySignature.swift` (pure
# Foundation — no UIKit, no Supabase, no Combine, no async) + the
# CLI test file. The slice-1 spec carves `RecoverySignature.swift`
# out explicitly so the orchestrator Mac's command-line tools can
# compile it standalone, matching the pattern set by V0.39's
# `build_and_run_restcountdown.sh`.
#
# Exit 0 = all 9 cases passed. Non-zero = regression in the median
# math, the revert-rate, the weekly bucketing, the coach copy, or
# the rep-count approximation.
set -e
cd "/Users/nathanmaxwell/Documents/VS Code/Hydrolyze 2/ios-native"

# Source files needed by the CLI test.
#   - RecoverySignature.swift: the new Slice 1 file with
#     `RestEventRecord`, `RecoverySignature`, `WeeklyStrainPoint`,
#     `RecoveryAggregator`. Pure, no UIKit, no Combine, no async,
#     no Supabase — CLI-friendly.
#   - RecoverySignatureCLITest.swift: the @main entry, last in the list.
SOURCES=(
  "Hydrolyze/Sources/Services/RecoverySignature.swift"
  "Hydrolyze/Tests/CLI/RecoverySignatureCLITest.swift"
)

OUTDIR="/tmp/hydrolyze-cli-build"
mkdir -p "$OUTDIR"

# Compile all sources into a single executable.
# -parse-as-library makes the @main entry callable.
# -O for release-ish perf (matches the sibling runners).
swiftc -O -parse-as-library \
  -o "$OUTDIR/recoverysignature-cli-test" \
  "${SOURCES[@]}" 2>&1

echo ""
echo "=== Compiled. Running ==="
echo ""
"$OUTDIR/recoverysignature-cli-test"