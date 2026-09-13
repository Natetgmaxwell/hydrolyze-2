#!/usr/bin/env bash
# V0.55 S1 screenshot capture for the Mode 3 ladder fix.
#
# Run this AFTER xcodebuild succeeds on macstudio-tailnet.
# Captures two screenshots:
#   1. The details page (with displayMode = .structured) for the
#      "4 x 25: 12.5 strong / 12.5 easy, descend 1-4" set.
#      Expected: 4 ladder cards (one per rep) with "↘ 1-4" chevron +
#      per-rep target labels (e.g. "1", "2", "3", "4" or "70%/75%/80%/~85%").
#      The "12.5 strong / 12.5 easy" fragments appear as a SUB-LINE
#      under each ladder card (NOT as a connected pair-track spanning
#      the rep card).
#   2. The same workout in the builder preview.
#
# Usage: ./scripts/capture-v055-s1-screenshots.sh
#
# Output:
#   /Users/nathanmaxwell/Documents/VS Code/hydrolyze-2/screenshots/v055-s1/details-page.png
#   /Users/nathanmaxwell/Documents/VS Code/hydrolyze-2/screenshots/v055-s1/builder-preview.png
#
# Requires the V0.54 details-tidy rich-test seed (jodie-09 purposeful
# threshold seed) — the "4x25 12.5 strong / 12.5 easy, descend 1-4,
# race rhythm" set is in that seed.

set -e

SCREENSHOTS_DIR="/Users/nathanmaxwell/Documents/VS Code/hydrolyze-2/screenshots/v055-s1"
mkdir -p "$SCREENSHOTS_DIR"

DEVICE="iPhone 17 Pro"

echo "→ Booting simulator ($DEVICE)…"
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b

echo "→ Installing + launching app…"
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData -name "Hydrolyze.app" -path "*/Debug-iphonesimulator/*" 2>/dev/null | head -1)
if [ -z "$APP_PATH" ]; then
  echo "ERROR: Hydrolyze.app not found in DerivedData. Run xcodebuild first."
  exit 1
fi
xcrun simctl install "$DEVICE" "$APP_PATH"
xcrun simctl launch "$DEVICE" com.hydrolyze.app

echo ""
echo "→ STEP 1: details-page screenshot"
echo "  Manually open the 'jodie-09 purposeful threshold' workout in the"
echo "  details view. Find the '4x25 12.5 strong / 12.5 easy, descend 1-4'"
echo "  set, scroll to centre it, and tap the device's side button + volume"
echo "  up (or use Cmd+S in the simulator) to capture."
echo "  Expected: 4 ladder cards under a ↘ 1-4 chevron, with the"
echo "  within-rep split rendered as a SUB-LINE, NOT as a connected pair-track."
echo ""
echo "  Press ENTER when ready…"
read -r

xcrun simctl io "$DEVICE" screenshot "$SCREENSHOTS_DIR/details-page.png"
echo "  ✓ $SCREENSHOTS_DIR/details-page.png"

echo ""
echo "→ STEP 2: builder-preview screenshot"
echo "  Navigate back to the workouts list, tap + to create, paste the"
echo "  workout text '4 x 25: 12.5 strong / 12.5 easy, descend 1-4, race rhythm'"
echo "  into the builder. The preview should show the SAME ladder layout."
echo ""
echo "  Press ENTER when ready…"
read -r

xcrun simctl io "$DEVICE" screenshot "$SCREENSHOTS_DIR/builder-preview.png"
echo "  ✓ $SCREENSHOTS_DIR/builder-preview.png"

echo ""
echo "Both screenshots captured. Compare side-by-side:"
echo "  open \"$SCREENSHOTS_DIR/details-page.png\" \"$SCREENSHOTS_DIR/builder-preview.png\""