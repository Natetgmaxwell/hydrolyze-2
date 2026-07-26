#!/bin/bash
# v1.17 Slice 8 — AttendanceNarrowing CLI test runner.
#
# The new scenario uses the SAME sources as the resolver CLI test
# (AttendanceResolver is pure). We extend that test with a second test
# main, compiled together so the resolver is available in-process, then
# invoke the new binary. Exit 0 = the resolved-attendance pool actually
# reaches the PairingEngine; non-zero = the narrowing failed.
set -e
cd "/Users/nathanmaxwell/Documents/VS Code/Hydrolyze 2/ios-native"

OUTDIR="/tmp/hydrolyze-cli-build"
mkdir -p "$OUTDIR"

# Same intent shim as build_and_run_resolver.sh -- lets the test compile
# without dragging in the Supabase SDK just for SwimmerAttendanceIntent.
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

# PairingEngine pulls in models + HungarianMatching. List them all rather
# than chase transitive deps; compile is fast.
SOURCES=(
  "$OUTDIR/IntentShim.swift"
  "Hydrolyze/Sources/Models/TrainingSchedule.swift"
  "Hydrolyze/Sources/Models/TimingModels.swift"
  "Hydrolyze/Sources/Models/Swimmer.swift"
  "Hydrolyze/Sources/Models/WaveAssignment.swift"
  "Hydrolyze/Sources/Models/LapAssignment.swift"
  "Hydrolyze/Sources/Models/Prediction.swift"
  "Hydrolyze/Sources/Models/Workout.swift"
  "Hydrolyze/Sources/Models/Enums.swift"
  "Hydrolyze/Sources/Services/AttendanceResolver.swift"
  "Hydrolyze/Sources/Services/HungarianMatching.swift"
  "Hydrolyze/Sources/Services/PairingEngine.swift"
  "Hydrolyze/Tests/CLI/AttendanceNarrowingCLITest.swift"
)

swiftc -O -parse-as-library \
  -o "$OUTDIR/attendance-narrowing-test" \
  "${SOURCES[@]}" 2>&1

echo ""
echo "=== Compiled. Running ==="
echo ""
"$OUTDIR/attendance-narrowing-test"
