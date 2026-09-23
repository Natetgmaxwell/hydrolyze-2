#!/usr/bin/env bash
# bench-verify.sh — runs the multi-axis parser bench against the LATEST
# baseline run, fails the build if any axis regresses by >0.05.
#
# Usage:
#   bash scripts/bench-verify.sh                # compares to latest baseline
#   bash scripts/bench-verify.sh --strict       # also requires ≥0.85 per-file
#   bash scripts/bench-verify.sh --refresh      # re-POST Jodie corpus to live
#
# Returns 0 on PASS, non-zero on REGRESSION (exit 2) or STRICT-FAIL (exit 3).

set -euo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/parser-bench" && pwd)"
ROOT="$(cd "${BENCH_DIR}/.." && pwd)"

cd "${ROOT}"

# Find the most recent baseline run (the snapshot the bench is gated against).
BASELINE=$(ls -1t "${BENCH_DIR}/runs/"*.json 2>/dev/null | grep -E '(baseline|\-baseline)' | head -1)
if [ -z "${BASELINE}" ]; then
  echo "no baseline run found in ${BENCH_DIR}/runs/" >&2
  exit 1
fi
echo "comparing against: ${BASELINE}"

ARGS=(--diff "${BASELINE}")
for arg in "$@"; do
  case "${arg}" in
    --strict|--refresh) ARGS+=("${arg}") ;;
  esac
done

python3 "${BENCH_DIR}/bench.py" --corpus=all "${ARGS[@]}"
