#!/usr/bin/env bash
#
# db-verify.sh — Hydrolyze Supabase behavioural verification.
#
# PURPOSE
#   Runs every probe in scripts/verify/*.sql against the linked Supabase
#   project and fails on the first FAIL row. The DB-layer counterpart to
#   build-verify.sh: that one proves the app compiles, this one proves the
#   schema and RLS policies actually behave.
#
# LESSON ENCODED (2026-07-26, v1.17 Slice 1)
#   Existence checks are not verification. The Slice 1 migration created
#   every table, column and policy exactly as specified — and the feature
#   was dead on arrival because two policies referenced each other and
#   every swimmer-side read threw 42P17 infinite recursion. Only a probe
#   that impersonates a swimmer through real RLS catches that class of bug.
#
#   Probes must therefore:
#     - run inside BEGIN ... ROLLBACK (no persistent writes)
#     - SET LOCAL ROLE authenticated + request.jwt.claims to impersonate
#     - capture expected values BEFORE the role switch, or the "want" side
#       is RLS-filtered too and every assertion is tautologically true
#     - emit a `result` column containing exactly 'PASS' or 'FAIL'
#
#   The supabase CLI exits non-zero on its own version-check chatter, so
#   the exit code is untrustworthy. We grep the output for FAIL instead.
#
# USAGE
#   bash scripts/db-verify.sh              # run all probes
#   bash scripts/db-verify.sh attendance   # run probes matching a substring
#
# EXIT CODES
#   0   PASS    — every probe row reported PASS
#   1   BLOCKED — a probe reported FAIL, errored, or emitted no rows
#
# REQUIREMENTS
#   - ~/.supabase/load-env.sh exports the Personal Access Token
#   - the project is linked (supabase link --project-ref ...)

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
filter="${1:-}"
# shellcheck disable=SC1090
source ~/.supabase/load-env.sh 2>/dev/null
# load-env.sh runs `set -euo pipefail`, which leaks into THIS shell. With -e
# active, the `out=$(supabase ...)` assignment below aborts the whole script
# the instant a probe errors -- no output, no FAIL line, and an exit code
# laundered to 0 by the trailing pipe. A gate that dies silently on a broken
# probe is worse than no gate. Turn it back off explicitly.
set +e

shopt -s nullglob
probes=(scripts/verify/*"$filter"*.sql)
(( ${#probes[@]} )) || { echo "✗ no probes match '$filter'"; exit 1; }

failed=0
for probe in "${probes[@]}"; do
  echo "── $(basename "$probe")"
  out=$(supabase db query --linked -f "$probe" 2>&1 | grep -v 'New version\|We recommend')
  echo "$out"

  if   grep -q 'FAIL'  <<<"$out"; then echo "✗ FAIL rows present"; failed=1
  elif grep -qE 'ERROR|unexpected status|Failed to run' <<<"$out"; then
    echo "✗ query errored"; failed=1
  elif ! grep -q 'PASS' <<<"$out"; then echo "✗ no PASS rows — probe emitted nothing"; failed=1
  fi
done

(( failed )) && { echo "BLOCKED"; exit 1; }
echo "PASS — all probes green"
