#!/bin/bash
# v1.17 Slice 3 — AttendanceResolver truth-table runner.
#
# The resolver is pure (no Supabase, no async), so it compiles and runs
# standalone on the orchestrator Mac in ~2s. No simulator, no network,
# no RLS. That is the point: the precedence chain is the load-bearing
# logic of the attendance loop and deserves a gate that runs every time,
# not one that needs a booted device.
#
# Exit 0 = all assertions passed. Non-zero = a rule regressed.
set -e
cd "/Users/nathanmaxwell/Documents/VS Code/Hydrolyze 2/ios-native"

SOURCES=(
  "Hydrolyze/Sources/Models/TrainingSchedule.swift"
  "Hydrolyze/Sources/Services/AttendanceResolver.swift"
  "Hydrolyze/Tests/CLI/AttendanceResolverCLITest.swift"
)

OUTDIR="/tmp/hydrolyze-cli-build"
mkdir -p "$OUTDIR"

# SwimmerAttendanceIntent lives in IntentService.swift, which imports the
# Supabase SDK. Rather than drag the whole SDK into a pure-logic test, we
# compile a minimal stand-in with the identical stored properties. If the
# real struct's shape drifts, the resolver stops compiling against this
# and the gate fails loudly -- which is the behaviour we want.
cat > "$OUTDIR/IntentShim.swift" <<'SHIM'
struct SwimmerAttendanceIntent: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let workoutId: String
    let swimmerId: String
    let intent: String
    let markedAt: String
    let source: String
}
SHIM

swiftc -O -parse-as-library \
  -o "$OUTDIR/attendance-resolver-test" \
  "$OUTDIR/IntentShim.swift" \
  "${SOURCES[@]}" 2>&1

echo ""
"$OUTDIR/attendance-resolver-test"
