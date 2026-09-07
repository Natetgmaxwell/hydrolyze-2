#!/usr/bin/env bash
#
# verify-parse-ladder.sh — 14-call live ladder for parse-workout.
#
# PURPOSE
#   End-to-end verification of the deployed parse-workout Edge Function.
#   Hits the live URL with 8 Jodie's corpus workouts + 4 half-pool
#   boundary cases + 2 control cases. Asserts ZERO fragment.distance
#   values come back as JSON floats (the bug that broke iOS decode on
#   2026-09-08). Prints timing per case for cold/warm visibility.
#
# USAGE
#   AUTH="eyJhbGc…" bash scripts/verify-parse-ladder.sh
#
# ENV
#   AUTH       Bearer token (required) — anon role, same as iOS sends
#   PARSE_URL  full URL (default: live flidjtldfvrrntzwtnsq)
#
# EXIT CODES
#   0  PASS — every case returned integer-only fragment distances
#   1  FAIL — one or more cases still emit floats
#   2  USAGE — no AUTH provided
#
# WHY THIS EXISTS
#   The 4-place sync invariant (V0.47 §3, parser-architecture skill)
#   demands every change to the parser be verified on the deployed
#   function. The bench is a unit test — it doesn't catch serialization
#   regressions that only show up on the live edge (e.g. JS number
#   emitting 12.5 as JSON float when iOS expects Int). This ladder
#   is the deployment gate.

set -eo pipefail

PROJECT_REF="flidjtldfvrrntzwtnsq"
PARSE_URL="${PARSE_URL:-https://${PROJECT_REF}.supabase.co/functions/v1/parse-workout}"
AUTH="${AUTH:-${PARSE_WORKOUT_TEST_JWT:-}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORPUS_DIR="${SCRIPT_DIR}/parser-bench"

if [[ -z "${AUTH}" ]]; then
  cat >&2 <<'USAGE'
verify-parse-ladder.sh — live parse-workout ladder verifier

Provide an Authorization Bearer token via the AUTH env var (anon role):

  AUTH="eyJhbGc…" bash scripts/verify-parse-ladder.sh

Exit codes:
  0  PASS  — zero JSON floats in any fragment.distance across all 14 cases
  1  FAIL  — one or more cases still emit floats
  2  USAGE — no AUTH provided
USAGE
  exit 2
fi

# Build the cases. We can't use tab-delimited line-per-case because
# workouts span multiple lines (the corpus has 30-260 line workouts).
# Instead, write one big shell-quoted blob: each case is its own
# heredoc block, and we `eval` each block to retrieve name+payload
# in shell. Cleaner than wrestling with `read` on multi-line input.

CASES_FILE="$(mktemp)"
trap 'rm -f "${CASES_FILE}" /tmp/ladder_resp.*' EXIT

cat > "${CASES_FILE}" <<CASES_EOF
# __RUN_CASE__ is set by the for-loop in the parent shell — DON'T shadow it
# here. The case branches below key off \${__RUN_CASE__}.
case \${__RUN_CASE__} in
  1) name="synth-threshold-frac"
     payload='THRESHOLD SESSION
4 x 25: 12.5 fast / 12.5 easy @ 0:45
4 x 50 threshold @ 1:00
' ;;
  2) name="synth-625"
     payload='4 x 75: 62.5 build / 12.5 easy @ 1:30
' ;;
  3) name="synth-375"
     payload='4 x 75: 37.5 build / 37.5 easy @ 1:30
' ;;
  4) name="synth-875"
     payload='4 x 100: 87.5 build / 12.5 easy @ 2:00
' ;;
  5) name="synth-clean-int"
     payload='4 x 50: 25 fast / 25 easy @ 1:00
' ;;
  6) name="synth-no-frag"
     payload='4 x 100 threshold @ 1:30
' ;;
  7) name="commit-jodie-01-sep"
     payload="\$(cat "${CORPUS_DIR}/commit-jodie-01-sep.txt")" ;;
  8) name="commit-jodie-02-sep"
     payload="\$(cat "${CORPUS_DIR}/commit-jodie-02-sep.txt")" ;;
  9) name="commit-jodie-03-sep"
     payload="\$(cat "${CORPUS_DIR}/commit-jodie-03-sep.txt")" ;;
  10) name="commit-jodie-04-sep"
     payload="\$(cat "${CORPUS_DIR}/commit-jodie-04-sep.txt")" ;;
  11) name="commit-jodie-05-aug"
     payload="\$(cat "${CORPUS_DIR}/commit-jodie-05-aug.txt")" ;;
  12) name="commit-jodie-06-aug"
     payload="\$(cat "${CORPUS_DIR}/commit-jodie-06-aug.txt")" ;;
  13) name="commit-jodie-07-aug"
     payload="\$(cat "${CORPUS_DIR}/commit-jodie-07-aug.txt")" ;;
  14) name="commit-jodie-08-aug"
     payload="\$(cat "${CORPUS_DIR}/commit-jodie-08-aug.txt")" ;;
esac
CASES_EOF

# Drive each case by its index. Each iteration sources CASES_FILE with
# a different `case` trigger, leaving name+payload set for that case.
total_floats=0
count=14

printf '\n=== parse-workout ladder — %d cases ===\n' "${count}"
for i in $(seq 1 "${count}"); do
  # Source into a subshell so the evaluation doesn't pollute us, with
  # __RUN_CASE__ set to the current iteration index.
  eval "$(__RUN_CASE__=${i}; set +u; . "${CASES_FILE}" 2>/dev/null; printf 'name=%q payload=%q\n' "${name:-}" "${payload:-}")"
  # ↑ %q wraps with single-quotes so we can re-eval cleanly below.

  if [[ -z "${payload:-}" ]]; then continue; fi

  # Build the JSON body with jq for portability (fallback to python).
  if command -v jq >/dev/null 2>&1; then
    body="$(printf '%s' "${payload}" | jq -Rs '{workoutText: .}')"
  else
    body="$(python3 -c "import json,sys; print(json.dumps({'workoutText': sys.argv[1]}))" "${payload}")"
  fi

  tmp_resp="/tmp/ladder_resp.$$.${name}"
  resp="$(curl -sS -o "${tmp_resp}" -w '%{http_code} %{time_total}' \
    -X POST "${PARSE_URL}" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${AUTH}" \
    --data-raw "${body}")" || {
      printf '  %-32s HTTP_ERROR\n' "${name}"
      rm -f "${tmp_resp}"
      continue
    }
  http="${resp%% *}"
  dt="${resp##* }"
  raw="$(cat "${tmp_resp}")"
  rm -f "${tmp_resp}"

  # Count JSON floats in *any* "distance": field (the bug emits 12.5; controls emit 0).
  # `grep -oE` exits 1 when there are no matches — under pipefail that kills the
  # script via `set -e`. `|| true` keeps the pipeline exit code at 0 so the
  # assignment completes; we only care about the captured count.
  floats=$(printf '%s' "${raw}" | { grep -oE '"distance"\s*:\s*[0-9]+\.[0-9]+' || true; } | wc -l | tr -d ' ')

  # Count sections. Use jq (preferred — fast, single-process) with a python
  # fallback when jq isn't available.
  sections=$(printf '%s' "${raw}" | jq -r '.sections | length' 2>/dev/null || python3 -c "import json,sys; print(len(json.load(sys.stdin).get('sections',[])))" 2>/dev/null || echo "?")

  marker=' ✓int'
  if [[ "${floats}" -gt 0 ]]; then
    marker=' ⚠FLOATS'
    total_floats=$(( total_floats + floats ))
  fi

  printf '  %-32s HTTP %s %5ss sections=%-3s floats=%d%s\n' \
    "${name}" "${http}" "${dt}" "${sections}" "${floats}" "${marker}"
done

printf '\n=== LADDER '
if [[ "${total_floats}" -gt 0 ]]; then
  printf 'FAIL ✗ — %d floats across %d cases (regression: server emits fractional fragment.distance)\n' \
    "${total_floats}" "${count}"
  exit 1
fi
printf 'PASS ✓ — zero floats, %d cases clean\n' "${count}"
