#!/usr/bin/env bash
#
# build-verify.sh — Hydrolyze iOS end-to-end build verification.
#
# PURPOSE
#   A single, idempotent script that connects to the macstudio build host and
#   runs the full canonical verification chain for the Hydrolyze iOS app:
#
#     1. git state        — confirm HEAD and working tree on macstudio
#     2. xcodegen         — regenerate Hydrolyze.xcodeproj from project.yml
#     3. xcodebuild       — compile for iOS Simulator (Debug)
#     4. install + launch — simctl install/launch on the booted simulator
#
# LESSON ENCODED (2026-07-14)
#   xcodegen is installed via Homebrew at /opt/homebrew/bin/xcodegen but is
#   NOT on the non-interactive SSH PATH. We must invoke it by absolute path.
#   xcodebuild and xcrun simctl ARE on the default SSH PATH, so they can be
#   invoked by name. Re-running xcodegen is cheap and idempotent — the
#   directory globs in project.yml pick up any newly added Swift/Resource
#   files automatically. The DerivedData path is stable
#   (Hydrolyze-gwpktjsfprbqdwgxyjyrstgxdvcw) so we can install the .app
#   directly without parsing xcodebuild output.
#
# USAGE
#   bash scripts/build-verify.sh                 # use default project root
#   bash scripts/build-verify.sh /custom/path    # override project root
#   bash scripts/build-verify.sh --dry-run       # print commands only
#   bash scripts/build-verify.sh --help          # this header
#
# EXIT CODES
#   0   SHIPS  — xcodebuild succeeded AND app launched on simulator
#   non-zero BLOCKED — any phase failed; printed error precedes exit
#
# REQUIREMENTS
#   - SSH alias 'macstudio' resolves in ~/.ssh/config
#   - macstudio has /opt/homebrew/bin/xcodegen installed
#   - macstudio has an iOS Simulator booted (default: iPhone 15 Pro)
#   - Hydrolyze.xcodeproj was previously generated (so DerivedData exists)
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

# Default project root on macstudio. The local checkout lives at
# /Users/nathanmaxwell/Documents/VS Code/Hydrolyze 2/ios-native on macstudio.
# (Local and remote are the same path because this repo is also checked out
# on macstudio under the same user — nathanmaxwell.)
DEFAULT_REMOTE_ROOT='/Users/nathanmaxwell/Documents/VS Code/Hydrolyze 2/ios-native'
PROJECT_ROOT="${DEFAULT_REMOTE_ROOT}"

# Dry-run flag — when true, print the SSH commands without executing them.
DRY_RUN=0

# Stable DerivedData path for Hydrolyze (set by Xcode on first build).
APP_BUNDLE='/Users/nathanmaxwell/Library/Developer/Xcode/DerivedData/Hydrolyze-gwpktjsfprbqdwgxyjyrstgxdvcw/Build/Products/Debug-iphonesimulator/Hydrolyze.app'

# Bundle ID — must match PRODUCT_BUNDLE_IDENTIFIER in project.yml.
BUNDLE_ID='com.hydrolyze.mobile'

# SSH alias. macstudio is configured in ~/.ssh/config.
SSH_HOST='macstudio'

# xcodegen absolute path — NOT on non-interactive SSH PATH.
XCODEGEN='/opt/homebrew/bin/xcodegen'

# Print usage / help text.
print_help() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

# Walk positional args and pull out --dry-run / --help.
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --help|-h) print_help ;;
    --*)
      echo "BLOCKED: unknown flag: $arg" >&2
      exit 2
      ;;
    *)
      # First non-flag positional arg overrides the project root.
      PROJECT_ROOT="$arg"
      ;;
  esac
done

# ---------------------------------------------------------------------------
# ssh-wrapper helper
# ---------------------------------------------------------------------------
# Run a remote command. If DRY_RUN is set, print the would-be invocation
# instead of executing it. We always quote the command into a single ssh
# string so the remote shell parses it; no shell injection surface.
run_remote() {
  local label="$1"
  local cmd="$2"
  echo "  [remote] $label"
  echo "  ssh $SSH_HOST '$cmd'"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  # -tt not used; BatchMode preferred for non-interactive. We rely on
  # ~/.ssh/config for identity, port, and any keepalive options.
  ssh "$SSH_HOST" "$cmd"
}

# ---------------------------------------------------------------------------
# PHASE 1: git state
# ---------------------------------------------------------------------------
# Confirm we're on the right branch and the working tree is what we expect.
# This is informational — we do NOT fail on dirty working tree, only on
# catastrophic git failure (network down, repo missing).
phase_git_state() {
  echo
  echo '================================================================'
  echo 'PHASE 1: git state'
  echo '================================================================'
  if ! run_remote 'git status (short) + last 3 commits' \
       "cd '${PROJECT_ROOT}' && git status --short && git log --oneline -3"; then
    echo 'BLOCKED in PHASE 1: could not read git state from macstudio.' >&2
    return 1
  fi
  echo 'PHASE 1 OK: git state read.'
}

# ---------------------------------------------------------------------------
# PHASE 2: xcodegen
# ---------------------------------------------------------------------------
# Regenerate Hydrolyze.xcodeproj from project.yml. xcodegen is idempotent:
# running it again with no source changes produces no diff. New Swift /
# Resource files under Hydrolyze/Sources and Hydrolyze/Resources are picked
# up automatically because project.yml uses directory globs (see line 19-20
# of project.yml).
phase_xcodegen() {
  echo
  echo '================================================================'
  echo 'PHASE 2: xcodegen generate'
  echo '================================================================'
  # Capture full output to a temp file so we can grep for errors AND tail
  # for the user. set -euo pipefail means the `local` + pipeline below
  # inherits pipefail, so a failure inside xcodegen propagates.
  local xcodegen_out
  xcodegen_out="$(mktemp -t xcodegen.XXXXXX)"
  # shellcheck disable=SC2064  # we WANT $xcodegen_out expanded now, not later.
  trap "rm -f '$xcodegen_out'" EXIT
  echo "  running ${XCODEGEN} generate on macstudio (output → $xcodegen_out)"
  echo "  ssh $SSH_HOST '${XCODEGEN} generate 2>&1 | tail -10'"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    rm -f "$xcodegen_out"
    echo 'PHASE 2 OK (dry-run): xcodegen would run.'
    return 0
  fi
  if ! ssh "$SSH_HOST" "cd '${PROJECT_ROOT}' && ${XCODEGEN} generate" \
       >"$xcodegen_out" 2>&1; then
    echo 'BLOCKED in PHASE 2: xcodegen generate failed.' >&2
    echo '--- last 30 lines of xcodegen output ---' >&2
    tail -30 "$xcodegen_out" >&2 || true
    rm -f "$xcodegen_out"
    return 1
  fi
  echo '--- last 10 lines of xcodegen output ---'
  tail -10 "$xcodegen_out"
  rm -f "$xcodegen_out"
  echo 'PHASE 2 OK: xcodegen generate succeeded.'
}

# ---------------------------------------------------------------------------
# PHASE 3: xcodebuild
# ---------------------------------------------------------------------------
# Build for iOS Simulator (Debug). We use a generic destination so the
# build does not require a specific simulator model — the install phase
# uses whichever simulator is currently booted.
phase_xcodebuild() {
  echo
  echo '================================================================'
  echo 'PHASE 3: xcodebuild (iOS Simulator, Debug)'
  echo '================================================================'
  local xc_out
  xc_out="$(mktemp -t xcodebuild.XXXXXX)"
  # shellcheck disable=SC2064
  trap "rm -f '$xc_out'" EXIT
  echo "  building -scheme Hydrolyze -destination 'generic/platform=iOS Simulator'"
  echo "  full output → $xc_out"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    rm -f "$xc_out"
    echo 'PHASE 3 OK (dry-run): xcodebuild would run.'
    return 0
  fi
  # We let the full output stream to the temp file. `tail -40` is then
  # printed after — xcodebuild output is huge and we only want the tail.
  if ! ssh "$SSH_HOST" "cd '${PROJECT_ROOT}' && xcodebuild \
      -project Hydrolyze.xcodeproj \
      -scheme Hydrolyze \
      -destination 'generic/platform=iOS Simulator' \
      -configuration Debug \
      build" >"$xc_out" 2>&1; then
    echo 'BLOCKED in PHASE 3: xcodebuild exited non-zero.' >&2
    echo '--- error: lines ---' >&2
    grep -E '^(/.*:[0-9]+:[0-9]+: error:|error:)' "$xc_out" \
      | head -40 >&2 || true
    echo '--- last 40 lines ---' >&2
    tail -40 "$xc_out" >&2 || true
    rm -f "$xc_out"
    return 1
  fi
  echo '--- last 40 lines of xcodebuild output ---'
  tail -40 "$xc_out"
  rm -f "$xc_out"
  echo 'PHASE 3 OK: BUILD SUCCEEDED.'
}

# ---------------------------------------------------------------------------
# PHASE 4: install + launch on booted simulator
# ---------------------------------------------------------------------------
# simctl install on an already-running app replaces it cleanly — no need to
# terminate first. simctl launch returns immediately with the new PID; we
# don't wait for the app to draw its first frame. If the launch fails the
# script exits non-zero and we report BLOCKED.
phase_install_launch() {
  echo
  echo '================================================================'
  echo 'PHASE 4: install + launch on booted simulator'
  echo '================================================================'
  # Confirm the .app bundle exists before we try to install — a missing
  # .app usually means PHASE 3 silently produced no product (a known
  # xcodebuild quirk when scheme/destination mismatch).
  echo "  verifying .app exists at: $APP_BUNDLE"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    if ! ssh "$SSH_HOST" "test -d '${APP_BUNDLE}'"; then
      echo "BLOCKED in PHASE 4: .app bundle not found at expected DerivedData path." >&2
      echo "  expected: $APP_BUNDLE" >&2
      echo "  hint: re-run PHASE 3 (xcodebuild) — the build may have produced output to a different DerivedData folder." >&2
      return 1
    fi
  fi

  local install_cmd="xcrun simctl install booted '${APP_BUNDLE}'"
  local launch_cmd="xcrun simctl launch booted '${BUNDLE_ID}'"
  echo "  ssh $SSH_HOST '$install_cmd && $launch_cmd'"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo 'PHASE 4 OK (dry-run): install + launch would run.'
    return 0
  fi
  if ! ssh "$SSH_HOST" "$install_cmd && $launch_cmd"; then
    echo 'BLOCKED in PHASE 4: simctl install or launch failed.' >&2
    return 1
  fi
  echo 'PHASE 4 OK: app installed and launched on simulator.'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

echo 'Hydrolyze iOS build verification'
echo "  remote root : $PROJECT_ROOT"
echo "  dry-run     : $DRY_RUN"
echo "  ssh host    : $SSH_HOST"
echo "  xcodegen    : $XCODEGEN"
echo "  app bundle  : $APP_BUNDLE"
echo "  bundle id   : $BUNDLE_ID"

phase_git_state
phase_xcodegen
phase_xcodebuild
phase_install_launch

echo
echo '================================================================'
echo 'RESULT: SHIPS'
echo '================================================================'
echo 'Hydrolyze built, installed, and launched on the booted simulator.'
exit 0
