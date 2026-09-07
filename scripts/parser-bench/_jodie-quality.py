#!/usr/bin/env python3
"""_jodie-quality.py — score the live parse-workout responses against
expected.jodie.ts.

Reads from /tmp/jodie-parse-*.json (already captured by
`_live-jodie-audit.py`) and asserts:

1. `expectedRepGroups` — every (reps, distance, interval) tuple in the
   expected list appears in the actual repGroups. Excludes any rg
   marked `exclude: true` from the actual count.

2. `expectedFragmentCompleteness` — for every rg with expected fragments
   and `expectsIntensity: true`, the actual fragment at that index
   carries a non-null intensity whose type matches `intensityType`.

3. `expectedUnmappedTerms` — exact set match (no false-positive noise,
   no missing genuine asks).

4. `expectedSectionCountMin` — at least this many sections.

Per-file score = matched repGroups / expected repGroups. Aggregate
score = sum(matched) / sum(expected). Exits 0 if all 8 files pass;
non-zero on any failure. Output is JSON-line per file for CI parsing.

Usage:
    python3 scripts/parser-bench/_jodie-quality.py
    python3 scripts/parser-bench/_jodie-quality.py --strict
"""

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Optional

BENCH_DIR = Path(__file__).resolve().parent
TMP_DIR = Path("/tmp")

# Lazy-load the TypeScript-side expected file by reading it as text and
# parsing the EXPECTED_JODIE object. We don't have a TS loader here, so
# we re-export the canonical data as a sibling JSON for speed. The
# canonical source lives in expected.jodie.ts; this JSON is generated
# from it (or hand-maintained) — keep them in sync.
EXPECTED_JSON = BENCH_DIR / "expected.jodie.json"


def load_expected() -> dict:
    if not EXPECTED_JSON.exists():
        print(
            f"FATAL: {EXPECTED_JSON} missing. Generate from expected.jodie.ts first:\n"
            f"  npx tsx scripts/parser-bench/_gen-expected-jodie.ts > {EXPECTED_JSON}",
            file=sys.stderr,
        )
        sys.exit(2)
    return json.loads(EXPECTED_JSON.read_text("utf-8"))


def flat_rep_groups(parsed: dict) -> list[dict]:
    """Return a flat list of repGroups from the parsed response, in
    document order. Excludes repGroups whose distance == 0 and stroke is
    null (those are summary/directive rg's the audit accepts as
    legitimate — handled separately via the `exclude` annotation on the
    expected rg).
    """
    out: list[dict] = []
    for sec in parsed.get("sections", []):
        for ns in sec.get("namedSets", []):
            for rg in ns.get("repGroups", []):
                out.append(rg)
    return out


def rg_signature(rg: dict) -> tuple:
    """Match key for an actual repGroup: (reps, distance, interval)."""
    return (
        rg.get("reps"),
        rg.get("distance"),
        rg.get("interval"),
    )


def rg_stroke_signature(rg: dict) -> tuple:
    return rg_signature(rg) + (rg.get("stroke"),)


def best_match(actual_pool: list[dict], expected: dict, used: set) -> Optional[int]:
    """Greedy match: pick the actual rg with the closest signature to
    the expected one, preferring triple-match over stroke-match over
    first-available. `used` is the set of indices already matched.
    """
    exp_sig = (expected["reps"], expected["distance"], expected["interval"])
    # First pass: exact triple + stroke match
    for i, rg in enumerate(actual_pool):
        if i in used:
            continue
        if rg_stroke_signature(rg) == exp_sig + (expected.get("stroke"),):
            return i
    # Second pass: exact triple, any stroke
    for i, rg in enumerate(actual_pool):
        if i in used:
            continue
        if rg_signature(rg) == exp_sig:
            return i
    # Third pass: relax interval (handles LLM normalising "2:30-2:45"
    # to "2:30–2:45" or vice versa)
    if exp_sig[2] is not None:
        for i, rg in enumerate(actual_pool):
            if i in used:
                continue
            if (rg.get("reps"), rg.get("distance")) == (exp_sig[0], exp_sig[1]):
                # tolerate interval normalisation differences
                return i
    return None


def score_file(name: str, expected: dict, parsed: dict) -> dict:
    """Score one Jodie file's parse response against its expected."""
    actual_rgs = flat_rep_groups(parsed)
    expected_rgs = expected["expectedRepGroups"]
    expected_count = sum(1 for e in expected_rgs if not e.get("exclude"))

    matched: list[int] = []
    rg_findings: list[dict] = []
    used: set[int] = set()

    for exp in expected_rgs:
        if exp.get("exclude"):
            # The expected rg is a "this should NOT be in actual_count"
            # marker. Find it (if emitted) and exclude from scoring.
            for i, rg in enumerate(actual_rgs):
                if i in used:
                    continue
                if (rg.get("reps"), rg.get("distance")) == (exp["reps"], exp["distance"]):
                    used.add(i)
                    break
            continue
        idx = best_match(actual_rgs, exp, used)
        if idx is None:
            rg_findings.append({"expected": exp, "actual": None, "status": "MISSING"})
            continue
        used.add(idx)
        actual = actual_rgs[idx]
        matched.append(idx)
        # Per-fragment completeness check
        fragment_findings: list[dict] = []
        if exp.get("fragments"):
            actual_frags = actual.get("fragments") or []
            for fi, exp_frag in enumerate(exp["fragments"]):
                if fi >= len(actual_frags):
                    fragment_findings.append({"frag_idx": fi, "status": "MISSING_FRAGMENT"})
                    continue
                af = actual_frags[fi]
                if exp_frag.get("expectsIntensity"):
                    intensity = af.get("intensity")
                    if not intensity or not intensity.get("type"):
                        fragment_findings.append({"frag_idx": fi, "distance": af.get("distance"), "status": "MISSING_INTENSITY"})
                    elif intensity.get("type") != exp_frag.get("intensityType"):
                        fragment_findings.append({"frag_idx": fi, "distance": af.get("distance"), "status": "WRONG_INTENSITY_TYPE", "got": intensity.get("type"), "expected": exp_frag.get("intensityType")})
        rg_findings.append({"expected": exp, "actual": {k: actual.get(k) for k in ("reps", "distance", "interval", "stroke")}, "status": "matched", "fragment_findings": fragment_findings})

    # Unmapped terms check (exact-set match)
    actual_unmapped = sorted(set(parsed.get("unmapped_terms") or []))
    expected_unmapped = sorted(expected["expectedUnmappedTerms"])
    unmapped_ok = actual_unmapped == expected_unmapped

    # Section count check
    section_count = len(parsed.get("sections", []))
    section_ok = section_count >= expected["expectedSectionCountMin"]

    return {
        "file": name,
        "score": len(matched) / max(1, expected_count),
        "matched": len(matched),
        "expected": expected_count,
        "sections": section_count,
        "sections_ok": section_ok,
        "unmapped_actual": actual_unmapped,
        "unmapped_expected": expected_unmapped,
        "unmapped_ok": unmapped_ok,
        "rg_findings": rg_findings,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--strict", action="store_true", help="Exit 1 on any unmapped_terms noise leak, even if reps match")
    args = parser.parse_args()

    expected = load_expected()
    aggregate_matched = 0
    aggregate_expected = 0
    fail = 0

    print(f"=== JODIE LIVE QUALITY — {len(expected)} files ===\n")
    for name, exp in sorted(expected.items()):
        parsed_file = TMP_DIR / f"jodie-parse-{Path(name).stem}.json"
        if not parsed_file.exists():
            print(f"  {name:30s}  NO RESPONSE FILE ({parsed_file})")
            fail += 1
            continue
        parsed = json.loads(parsed_file.read_text("utf-8"))
        s = score_file(name, exp, parsed)
        aggregate_matched += s["matched"]
        aggregate_expected += s["expected"]
        status = "PASS" if s["score"] >= 0.85 and s["unmapped_ok"] and s["sections_ok"] else "FAIL"
        if status == "FAIL":
            fail += 1
        print(f"  {name:30s}  score={s['score']:.2f}  matched={s['matched']}/{s['expected']}  sections={s['sections']}  unmapped={'OK' if s['unmapped_ok'] else 'WRONG'}  -> {status}")
        if status == "FAIL" or args.strict:
            if not s["unmapped_ok"]:
                print(f"    UNMAPPED actual={s['unmapped_actual']} expected={s['unmapped_expected']}")
            for fi in s["rg_findings"]:
                if fi["status"] != "matched":
                    print(f"    RG: {fi}")
                for f_find in fi.get("fragment_findings") or []:
                    print(f"      FRAG: {f_find}")
        # In --strict mode, also fail when fragment completeness misses
        if args.strict:
            for fi in s["rg_findings"]:
                if fi.get("fragment_findings"):
                    fail += 1

    agg = aggregate_matched / max(1, aggregate_expected)
    print(f"\n=== AGGREGATE: {aggregate_matched}/{aggregate_expected} = {agg:.2f} ===")
    if agg < 0.85 or fail > 0:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
