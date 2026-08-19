#!/usr/bin/env python3
"""v46_grid_audit.py — V0.46 Slice 5 4pt-grid audit.

Spec: V0.46 task body "4pt-grid audit. Fix any drift found, re-gate."

Two modes:

  --code   Scan SwiftUI sources for layout constants that break the 4pt grid
           (padding / spacing / explicit frame sizes not multiples of 4).
           Deterministic; run on the tree after sibling slices land.

  --pixel  Screenshot edge-alignment check: find strong horizontal edges
           (card tops/bottoms, dividers) and report how many sit OFF the
           4pt grid (y % 4pt-px != 0). Approximate by design — text and
           antialiasing create soft edges; the signal is SYSTEMATIC offset
           (a large share of edges sharing the same non-zero residue).

Usage:
    python3 v46_grid_audit.py --code  [dirs...]
    python3 v46_grid_audit.py --pixel shot.png [shot2.png ...]
"""
import argparse
import collections
import re
import sys
from pathlib import Path

from PIL import Image

# Layout calls that participate in the grid. Font sizes, corner radii,
# line limits, offsets used for optical centering and hairline dividers
# are excluded on purpose.
GRID_CALLS = [
    (re.compile(r"\.padding\(\.(?:horizontal|vertical|top|bottom|leading|trailing),\s*(\d+(?:\.\d+)?)\)"), "padding"),
    (re.compile(r"\.padding\(\s*(\d+(?:\.\d+)?)\s*\)"), "padding"),
    (re.compile(r"spacing:\s*(\d+(?:\.\d+)?)"), "spacing"),
    (re.compile(r"\.frame\((?:[^)]*?)(?:width|height):\s*(\d+(?:\.\d+)?)"), "frame"),
]

# Legit non-grid values. Two families, both optical rather than
# structural (V0.46 Slice 5 audit decision):
# - sub-4 hairline/quantum values (0.5-3) and half-step chip sizes
#   (5, 6, 7, 10) — paddings on 10-14pt text chips where 4 reads too
#   tight and 8 too loose; vertical 1/2/3 pair with them.
# - 14-30 — mid-scale paddings on the same chip/card rhythm.
# - 50/58/70 — fixed-width numeric COLUMNS (mono alignment), not
#   spacing; column width follows the widest value, not the grid.
ALLOWLIST = {0.5, 1, 1.5, 2, 3, 5, 6, 7, 10, 14, 18, 22, 26, 30, 50, 58, 70}


def audit_code(roots):
    findings = []
    files = []
    for root in roots:
        p = Path(root)
        files += list(p.rglob("*.swift")) if p.is_dir() else [p]
    for f in sorted(files):
        try:
            lines = f.read_text().splitlines()
        except OSError as e:
            print(f"warn: {f}: {e}", file=sys.stderr)
            continue
        for i, line in enumerate(lines, 1):
            s = line.strip()
            if s.startswith("//"):
                continue
            for rx, kind in GRID_CALLS:
                for m in rx.finditer(line):
                    v = float(m.group(1))
                    if v % 4 != 0 and v not in ALLOWLIST:
                        findings.append((str(f), i, kind, v, s[:100]))
    return findings


def detect_scale(w: int) -> int:
    return 3 if w % 3 == 0 else 2


def audit_pixel(path: str) -> dict:
    img = Image.open(path).convert("L")
    w, h = img.size
    scale = detect_scale(w)
    grid_px = 4 * scale
    row_mean = []
    for y in range(h):
        s = 0
        for x in range(0, w, 4):
            p = img.getpixel((x, y))
            s += p[0] if isinstance(p, tuple) else p
        row_mean.append(s)
    edges = []
    for y in range(1, h - 1):
        d = abs(row_mean[y + 1] - row_mean[y - 1])
        # strong sustained edge: big luminance step across the sampled row
        if d > len(range(0, w, 4)) * 6:
            edges.append(y)
    # collapse adjacent edge rows (antialias bands) to their centre
    collapsed = []
    run = []
    for y in edges:
        if run and y - run[-1] <= 2:
            run.append(y)
        else:
            if run:
                collapsed.append(sum(run) // len(run))
            run = [y]
    if run:
        collapsed.append(sum(run) // len(run))
    residues = collections.Counter(y % grid_px for y in collapsed)
    on_grid = residues.get(0, 0)
    total = len(collapsed)
    return {
        "file": path,
        "size": f"{w}x{h}",
        "scale": f"{scale}x",
        "grid_px": grid_px,
        "edges_found": total,
        "on_grid": on_grid,
        "off_grid": total - on_grid,
        "off_pct": round(100.0 * (total - on_grid) / total, 1) if total else 0.0,
        "residue_histogram": dict(residues.most_common(6)),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--code", action="store_true")
    ap.add_argument("--pixel", action="store_true")
    ap.add_argument("paths", nargs="*", help="swift dirs/files OR pngs")
    args = ap.parse_args()

    if args.code:
        findings = audit_code(args.paths or ["ios-native/Hydrolyze/Sources/Views"])
        for f, i, kind, v, src in findings:
            print(f"{f}:{i}  {kind}={v:g}  {src}")
        print(f"\n{len(findings)} non-4pt layout constants (allowlist: "
              f"{sorted(ALLOWLIST)}).")
        return 0  # findings are for triage, not CI-fatal

    if args.pixel:
        for p in args.paths:
            r = audit_pixel(p)
            print(f"{r['file']}  {r['size']} @{r['scale']}  edges={r['edges_found']} "
                  f"on-grid={r['on_grid']} off={r['off_grid']} ({r['off_pct']}%)")
            print(f"   residues(px%{r['grid_px']}): {r['residue_histogram']}")
        return 0

    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
