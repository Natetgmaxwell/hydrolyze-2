#!/usr/bin/env python3
"""v46_coral_audit.py — V0.46 Slice 5 coral-budget pixel audit.

Spec: V0.46_SPEC.md §Verification — "Coral ≤20%: screenshot pixel-audit per
surface (quick script; approximate is fine — the point is catching drift)".

Coral family = accentAction #FF6B4A and accentActionDim #D9583C (pressed /
border states). Amber #F5B34B and success #4ADE80 are NOT coral — but they're
also budget accents, so they're reported alongside for eyeballing.

Method: classify each pixel by nearest neighbour in RGB space against the
locked token values, with a tolerance gate (distance > tol → "other").
Approximate by design: catches drift, ignores antialiasing.

Usage:
    python3 v46_coral_audit.py shot1.png [shot2.png ...]
    python3 v46_coral_audit.py --json shots/*.png     # one JSON blob
"""
import argparse
import json
import sys

from PIL import Image

# Locked V0.46 tokens (V0.46_SPEC.md §Design tokens).
CORAL = (0xFF, 0x6B, 0x4A)      # accentAction
CORAL_DIM = (0xD9, 0x58, 0x3C)  # accentActionDim
AMBER = (0xF5, 0xB3, 0x4B)      # accentAmber — reported, not coral
SUCCESS = (0x4A, 0xDE, 0x80)    # statusSuccess — reported, not coral
ERROR_RED = (0xF8, 0x71, 0x71)  # statusError — reported, not coral

BUDGET_PCT = 20.0
NEAREST_TOL = 60  # euclidean RGB distance; beyond this, "close" is noise

PALETTE = {
    "coral": CORAL,
    "coral_dim": CORAL_DIM,
    "amber": AMBER,
    "success": SUCCESS,
    "error": ERROR_RED,
}


def classify(px) -> str:
    r, g, b = px[0], px[1], px[2]
    best, best_d = "other", NEAREST_TOL
    for name, (tr, tg, tb) in PALETTE.items():
        d = ((r - tr) ** 2 + (g - tg) ** 2 + (b - tb) ** 2) ** 0.5
        if d < best_d:
            best, best_d = name, d
    return best


def audit(path: str) -> dict:
    img = Image.open(path).convert("RGB")
    w, h = img.size
    counts = {}
    # Downsample >=3px stride on large simulator screenshots (1179x2556):
    # ~9x fewer pixels, coral blobs are large (buttons), drift unaffected.
    stride = 3 if w >= 1000 else 1
    total = 0
    for y in range(0, h, stride):
        for x in range(0, w, stride):
            c = classify(img.getpixel((x, y)))
            counts[c] = counts.get(c, 0) + 1
            total += 1
    coral = counts.get("coral", 0) + counts.get("coral_dim", 0)
    pct = 100.0 * coral / total
    return {
        "file": path,
        "size": f"{w}x{h}",
        "sampled_px": total,
        "coral_px": coral,
        "coral_pct": round(pct, 2),
        "budget_pct": BUDGET_PCT,
        "within_budget": pct <= BUDGET_PCT,
        "breakdown": {k: round(100.0 * v / total, 3)
                      for k, v in sorted(counts.items()) if v},
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("shots", nargs="+", help="screenshot PNG paths")
    ap.add_argument("--json", action="store_true", help="emit JSON only")
    args = ap.parse_args()

    results = [audit(p) for p in args.shots]
    rc = 0
    for r in results:
        if not r["within_budget"]:
            rc = 1
    if args.json:
        print(json.dumps(results, indent=2))
    else:
        for r in results:
            flag = "OK " if r["within_budget"] else "OVER"
            print(f"[{flag}] {r['file']}  coral {r['coral_pct']}% "
                  f"(budget {r['budget_pct']}%)  {r['size']}")
            print(f"       {r['breakdown']}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
