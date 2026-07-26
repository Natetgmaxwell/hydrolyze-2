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
# PHASE 4: install + launch + screenshot on booted simulator(s)
# ---------------------------------------------------------------------------
# We DO NOT use 'simctl install booted' (which is iPhone-biased — the first
# booted simulator wins, and in our setup that is always iPhone). Instead
# we explicitly discover all booted iOS Simulators via
# 'xcrun simctl list devices booted', categorize them by name (iPhone vs
# iPad), boot an iPad if none is booted, install + launch on each, and
# capture a screenshot from each for visual verification. Screenshots are
# scp'd back to this Mac into /tmp/hydrolyze-screenshots/ for inspection.
#
# iPad is the priority target because:
#   (a) iPad-specific layout changes (split view, sidebar, multi-column)
#       are the most fragile parts of our pipeline — small layout
#       differences don't show on iPhone, so an iPhone-only SHIPS claim
#       says nothing about iPad correctness.
#   (b) every prior SHIPS claim in this repo was for iPhone; iPad has
#       never been the default-tested device. Commit a6f94fd (iPad
#       split layout) was shipped without ever being verified on an
#       iPad. We refuse to repeat that.

# Known iPad Pro 11-inch UDID on macstudio. Verify with
#   xcrun simctl list devices available
IPAD_UDID='7135C236-4F54-47D3-8609-3F6808A35149'

# Where screenshots land locally (this Mac) and stage remotely (macstudio)
# before scp. Both are in /tmp so they do not pollute the repo.
LOCAL_SCREENSHOT_DIR='/tmp/hydrolyze-screenshots'
REMOTE_SCREENSHOT_DIR='/tmp/hydrolyze-screenshots-remote'

phase_install_launch() {
  echo
  echo '================================================================'
  echo 'PHASE 4: install + launch + screenshot on booted simulator(s)'
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

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo 'PHASE 4 OK (dry-run): install + launch + screenshot would run.'
    return 0
  fi

  # Allocate temp files first so the EXIT trap can safely reference all of
  # them even on early return (set -u would otherwise complain).
  local booted_pairs_file ipad_pairs_file iphone_pairs_file
  booted_pairs_file="$(mktemp -t booted.XXXXXX)"
  ipad_pairs_file="$(mktemp -t ipadpairs.XXXXXX)"
  iphone_pairs_file="$(mktemp -t iphonepairs.XXXXXX)"
  # shellcheck disable=SC2064  # we WANT these expanded now, not later.
  trap "rm -f '$booted_pairs_file' '$ipad_pairs_file' '$iphone_pairs_file'" EXIT

  # ---------------------------------------------------------------------
  # Step 1: Discover currently-booted simulators. Output of
  # 'simctl list devices booted' is human-readable; we extract lines
  # matching `^<spaces><name> (<udid>) (Booted)$` into `<udid>|<name>`
  # pairs in a temp file.
  # ---------------------------------------------------------------------
  echo '  discovering booted simulators on macstudio...'
  local booted_raw
  booted_raw="$(ssh "$SSH_HOST" 'xcrun simctl list devices booted')"
  echo "$booted_raw" | sed 's/^/    /'

  echo "$booted_raw" \
    | grep -E '\([0-9A-Fa-f-]{36}\) \(Booted\)' \
    | sed -E 's/^[[:space:]]+(.+) \(([0-9A-Fa-f-]{36})\) \(Booted\)[[:space:]]*$/\2|\1/' \
    > "$booted_pairs_file"

  # ---------------------------------------------------------------------
  # Step 2: If no iPad is booted, boot the iPad Pro 11-inch and wait up
  # to 10s for it to appear in 'simctl list devices booted'.
  # ---------------------------------------------------------------------
  if ! grep -qi '|iPad' "$booted_pairs_file"; then
    echo "  no iPad booted; booting iPad Pro 11-inch (${IPAD_UDID})..."
    ssh "$SSH_HOST" "xcrun simctl boot '${IPAD_UDID}'" >/dev/null 2>&1 || true
    local waited=0
    while [[ "$waited" -lt 10 ]]; do
      if ssh "$SSH_HOST" 'xcrun simctl list devices booted' \
           | grep -q "${IPAD_UDID}"; then
        echo "  iPad booted after ${waited}s."
        break
      fi
      sleep 1
      waited=$((waited + 1))
    done
    if [[ "$waited" -ge 10 ]]; then
      echo "  WARNING: iPad did not appear in booted list within 10s." >&2
    fi
    # Re-discover booted devices now that the iPad may be there.
    booted_raw="$(ssh "$SSH_HOST" 'xcrun simctl list devices booted')"
    echo "$booted_raw" \
      | grep -E '\([0-9A-Fa-f-]{36}\) \(Booted\)' \
      | sed -E 's/^[[:space:]]+(.+) \(([0-9A-Fa-f-]{36})\) \(Booted\)[[:space:]]*$/\2|\1/' \
      > "$booted_pairs_file"
  fi

  if [[ ! -s "$booted_pairs_file" ]]; then
    echo 'BLOCKED in PHASE 4: no booted simulators after iPad-boot attempt.' >&2
    return 1
  fi

  # ---------------------------------------------------------------------
  # Step 3: Process each booted device. iPad goes first (priority target).
  # Per device: install, launch, screenshot, scp back to local.
  # ---------------------------------------------------------------------
  grep -i '|iPad' "$booted_pairs_file" > "$ipad_pairs_file" || true
  grep -iv '|iPad' "$booted_pairs_file" > "$iphone_pairs_file" || true
  local device_count
  device_count=$(wc -l < "$booted_pairs_file" | tr -d ' ')
  echo "  found ${device_count} booted simulator(s); processing iPad first."

  # Prepare local + remote screenshot dirs.
  mkdir -p "$LOCAL_SCREENSHOT_DIR"
  ssh "$SSH_HOST" "mkdir -p '${REMOTE_SCREENSHOT_DIR}' && rm -f '${REMOTE_SCREENSHOT_DIR}'/*.png" \
    >/dev/null 2>&1 || true

  local processed=0
  while IFS='|' read -r udid name; do
    [[ -z "$udid" || -z "$name" ]] && continue
    processed=$((processed + 1))
    # Slugify name for filename ("iPad Pro 11-inch" -> "ipad-pro-11-inch").
    local slug
    slug="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' \
            | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//')"
    local remote_png="${REMOTE_SCREENSHOT_DIR}/hydrolyze-${slug}.png"
    local local_png="${LOCAL_SCREENSHOT_DIR}/hydrolyze-${slug}.png"

    echo
    echo "  -- device: ${name} (${udid}) --"
    echo "  ssh $SSH_HOST 'xcrun simctl install ${udid} \"${APP_BUNDLE}\" && xcrun simctl launch ${udid} \"${BUNDLE_ID}\"'"
    if ! ssh "$SSH_HOST" "xcrun simctl install '${udid}' '${APP_BUNDLE}' && xcrun simctl launch '${udid}' '${BUNDLE_ID}'"; then
      echo "BLOCKED in PHASE 4: install or launch failed on ${name} (${udid})." >&2
      return 1
    fi

    # Give the app a moment to draw its first frame before screenshotting.
    sleep 3

    echo "  ssh $SSH_HOST 'xcrun simctl io ${udid} screenshot ${remote_png}'"
    if ! ssh "$SSH_HOST" "xcrun simctl io '${udid}' screenshot '${remote_png}'" 2>/dev/null; then
      echo "  WARNING: screenshot capture failed on ${name} (${udid}); continuing." >&2
      continue
    fi

    echo "  scp ${SSH_HOST}:${remote_png} ${local_png}"
    if ! scp "${SSH_HOST}:${remote_png}" "$local_png" 2>/dev/null; then
      echo "  WARNING: scp of screenshot from ${name} failed; remote copy remains at ${remote_png}." >&2
      continue
    fi
    local size
    size=$(wc -c < "$local_png" | tr -d ' ')
    echo "  saved: ${local_png} (${size} bytes)"

    # iPad-specific layout assertion: if the most recent commit touched a
    # known iPad-fragile file, note that landscape testing is required as
    # a separate user-initiated step. simctl cannot rotate the device
    # programmatically, so we capture portrait only and surface the gap.
    if [[ "$name" == *iPad* ]]; then
      local recent_files
      recent_files="$(ssh "$SSH_HOST" "cd '${PROJECT_ROOT}' && git log -1 --name-only --pretty=format:" 2>/dev/null || true)"
      if printf '%s' "$recent_files" | grep -qE '(WorkoutBuilderView\.swift|WorkoutPreview\.swift)'; then
        echo "  iPad layout NOTE: most recent commit touched a known iPad-fragile file:"
        printf '%s\n' "$recent_files" \
          | grep -E '(WorkoutBuilderView\.swift|WorkoutPreview\.swift)' \
          | sed 's/^/    /'
        echo "    For landscape coverage, rotate the iPad simulator manually"
        echo "    (Hardware > Rotate Left, Cmd+Left) and re-run. simctl cannot"
        echo "    rotate the device programmatically — landscape is a separate,"
        echo "    user-initiated verification step."
      fi
    fi
  done < <(cat "$ipad_pairs_file" "$iphone_pairs_file")

  # A phase that did nothing must never report OK.
  #
  # This is the defect that hid a broken PHASE 4 for five slices: a stray
  # trailing space in `simctl list devices booted` output ("(Booted) \n")
  # defeated the sed `$` anchor, so the udid|name pairs file came out empty,
  # the loop body ran ZERO times, and the unconditional "PHASE 4 OK" printed
  # anyway. The app was never installed, never launched, and no screenshot
  # was captured -- while the script reported all three and exited SHIPS.
  #
  # `processed` is incremented inside the loop. `done < <(...)` uses process
  # substitution rather than a pipe, so the loop runs in THIS shell and the
  # increment survives -- a `cat ... | while` would have put the loop in a
  # subshell and silently reset the count to 0, reintroducing the same class
  # of bug in the guard meant to catch it.
  if [[ "$processed" -eq 0 ]]; then
    echo 'BLOCKED in PHASE 4: parsed 0 devices from the booted list.' >&2
    echo '  The install/launch/screenshot loop never executed.' >&2
    echo '  Raw simctl output was:' >&2
    printf '%s\n' "$booted_raw" | sed 's/^/    /' >&2
    return 1
  fi

  # Every device that reached the loop must have left a screenshot on THIS
  # machine. Anything less and the phase is reporting evidence it doesn't have.
  local captured
  captured=$(find "$LOCAL_SCREENSHOT_DIR" -name 'hydrolyze-*.png' -newermt '-10 minutes' 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$captured" -lt "$processed" ]]; then
    echo "BLOCKED in PHASE 4: processed ${processed} device(s) but only ${captured} fresh screenshot(s) landed in ${LOCAL_SCREENSHOT_DIR}." >&2
    return 1
  fi

  echo
  echo "PHASE 4 OK: installed, launched, and captured ${captured} screenshot(s) across ${processed} simulator(s)."
  echo "  screenshots in: ${LOCAL_SCREENSHOT_DIR}"
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
