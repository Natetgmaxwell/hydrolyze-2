#!/bin/bash
# V0.39 Slice 2 — RestCountdownModel CLI runner.
#
# Pure-logic gate for the NEW drop-rule state machine added in
# Slice 2: strike math, maturity gate, intensity gate, threshold
# scaling (25m/50m/odd), escalation caps, strike reset, revert,
# tick, multi-swimmer common clock, and reset.
#
# The runner compiles the production `RestCountdownModel` + the
# model deps (`Prediction.swift` for `Prediction.Maturity`) + the
# CLI test file. The slice-2 spec carves out
# `RestCountdownModel.swift` (Services/) explicitly so the CLI
# can compile it without UIKit, Combine, async, or Supabase — the
# orchestrator Mac's command-line tools only ship the macOS SDK,
# no iOS simulator, and the model is pure-function.
#
# Exit 0 = all 12 cases passed. Non-zero = regression in the
# strike math, threshold scaling, maturity gate, intensity gate,
# strike reset, revert, tick, or multi-swimmer behavior.
set -e
cd "/Users/nathanmaxwell/Documents/VS Code/Hydrolyze 2/ios-native"

# Source files needed by the CLI test.
#   - Prediction.swift: `Prediction.Maturity` enum (the maturity
#     gate reads `.reliable` / `.excellent`).
#   - RestCountdownModel.swift: the new Slice 2 file with
#     `RestCountdownModel`, `DropEvaluation`, `RevertResult`,
#     `RestStandardSource`. Pure, no UIKit, no Combine, no
#     async, no Supabase — CLI-friendly.
#   - RestCountdownCLITest.swift: the @main entry, last in the list.
SOURCES=(
  "Hydrolyze/Sources/Models/Prediction.swift"
  "Hydrolyze/Sources/Services/RestCountdownModel.swift"
  "Hydrolyze/Tests/CLI/RestCountdownCLITest.swift"
)

OUTDIR="/tmp/hydrolyze-cli-build"
mkdir -p "$OUTDIR"

# Compile all sources into a single executable.
# -parse-as-library makes the @main entry callable.
# -O for release-ish perf (matches the sibling runners).
swiftc -O -parse-as-library \
  -o "$OUTDIR/restcountdown-cli-test" \
  "${SOURCES[@]}" 2>&1

echo ""
echo "=== Compiled. Running ==="
echo ""
"$OUTDIR/restcountdown-cli-test"
