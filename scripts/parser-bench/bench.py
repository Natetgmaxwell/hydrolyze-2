#!/usr/bin/env python3
"""
bench.py — V0.52 Slice 3 (2026-09-23): unified parse-fidelity benchmark.

Runs the regex engine (and the live deployed LLM edge function for the
Jodie corpus) against every corpus family and scores on five axes:

  A. set-structure accuracy     reps×distance×interval×stroke at rg level
  B. fragment fidelity          fragment count vs parent set expectation
  C. per-fragment intensity     non-null + type match where asserted
  D. noise (unmapped_terms)     exact-set match vs expected Tier-1 words
  E. section-vs-set             notes-vs-rgs classification (free-text stays
                                as notes; "summary lines" must NOT become
                                zero-distance rgs)

Corpus families covered:
  - real-input-{1..21}.txt   → regex engine + expected.json
  - commit-jodie-{1..8}-*.txt, commit-jodie-09-purposethreshold.txt
                            → LIVE deployed parse-workout edge function
                              (cached at /tmp/jodie-parse-*.json)
                              + expected.jodie.json
  - stress-input.txt         → regex engine + expected.stress.json

Outputs:
  - scripts/parser-bench/runs/<date>-<commit>.json (run snapshot)
  - console: per-file table + per-axis aggregate

Usage:
  python3 scripts/parser-bench/bench.py                  # full run
  python3 scripts/parser-bench/bench.py --corpus=real    # only real-inputs
  python3 scripts/parser-bench/bench.py --corpus=jodie   # only Jodie
  python3 scripts/parser-bench/bench.py --corpus=stress  # only stress
  python3 scripts/parser-bench/bench.py --diff <prev>.json
"""

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Optional

BENCH_DIR = Path(__file__).resolve().parent
EXPECTED_REAL = BENCH_DIR / "expected.json"
EXPECTED_JODIE = BENCH_DIR / "expected.jodie.json"
EXPECTED_STRESS = BENCH_DIR / "expected.stress.json"
RUNS_DIR = BENCH_DIR / "runs"
TMP_DIR = Path("/tmp")
EDGE_FN_URL = "https://flidjtldfvrrntzwtnsq.supabase.co/functions/v1/parse-workout"

# ─── Corpus plumbing ──────────────────────────────────────────────────────────

def _norm_interval(s: Optional[str]) -> str:
    if s is None: return ""
    return s.replace(".", ":").replace(" ", "")


def rg_sig(rg: dict) -> tuple:
    """(reps, distance, interval) — the cheap match key."""
    return (rg.get("reps"), rg.get("distance"), _norm_interval(rg.get("interval")))


def rg_stroke_sig(rg: dict) -> tuple:
    return rg_sig(rg) + (rg.get("stroke"),)


def _call_edge_fn(text: str) -> tuple[dict, float]:
    """POST to the deployed parse-workout edge function. No auth = no vocab."""
    body = json.dumps({"workoutText": text}).encode("utf-8")
    req = urllib.request.Request(
        EDGE_FN_URL,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    t0 = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read().decode("utf-8")), time.monotonic() - t0
    except urllib.error.HTTPError as e:
        return {"_http_error": e.code, "_body": e.read().decode("utf-8")[:500]}, time.monotonic() - t0
    except Exception as e:
        return {"_exception": str(e)}, time.monotonic() - t0


def _call_regex_engine(input_file: Path) -> dict:
    """Spawn `npx tsx measure.ts <file>` and parse the JSON output."""
    proc = subprocess.run(
        ["npx", "tsx", str(BENCH_DIR / "measure.ts"), str(input_file)],
        cwd=str(BENCH_DIR),
        capture_output=True,
        text=True,
        timeout=30,
    )
    if proc.returncode != 0:
        return {"_error": proc.stderr[:500]}
    return json.loads(proc.stdout)


def _flat_rgs(parsed: dict) -> list[dict]:
    """Document-order flatten: sections → namedSets → repGroups."""
    out: list[dict] = []
    for sec in parsed.get("sections", []):
        for ns in sec.get("namedSets", []):
            for rg in ns.get("repGroups", []):
                out.append(rg)
    return out


def _best_match(actual: list[dict], expected: dict, used: set, require_stroke: bool = False) -> Optional[int]:
    exp_sig = (
        expected.get("reps"),
        expected.get("distance"),
        _norm_interval(expected.get("interval")),
    )
    # Pass 1: exact triple + stroke match
    for i, rg in enumerate(actual):
        if i in used: continue
        if rg_stroke_sig(rg) == exp_sig + (expected.get("stroke"),):
            return i
    # Pass 2: exact triple, any stroke
    for i, rg in enumerate(actual):
        if i in used: continue
        if rg_sig(rg) == exp_sig:
            return i
    # Pass 3: relax interval (tolerate `2:30-2:45` vs `2:30–2:45`)
    if exp_sig[2]:
        for i, rg in enumerate(actual):
            if i in used: continue
            if (rg.get("reps"), rg.get("distance")) == (exp_sig[0], exp_sig[1]):
                return i
    return None


# ─── Axis scorers ─────────────────────────────────────────────────────────────

def axis_structure(actual: list[dict], expected: dict) -> dict:
    """A. set-structure accuracy. Returns matched/total + score."""
    exp_rgs = expected.get("repGroups", [])
    expected_count = sum(1 for e in exp_rgs if not e.get("exclude"))
    used: set[int] = set()
    matched: list[int] = []
    rg_findings: list[dict] = []
    for exp in exp_rgs:
        if exp.get("exclude"):
            for i, rg in enumerate(actual):
                if i in used: continue
                if (rg.get("reps"), rg.get("distance")) == (exp.get("reps"), exp.get("distance")):
                    used.add(i)
                    break
            continue
        idx = _best_match(actual, exp, used)
        if idx is None:
            rg_findings.append({"expected": exp, "actual": None, "status": "MISSING"})
            continue
        used.add(idx)
        actual_rg = actual[idx]
        matched.append(idx)
        rg_findings.append({
            "expected": exp,
            "actual": {k: actual_rg.get(k) for k in ("reps", "distance", "interval", "stroke")},
            "status": "matched",
        })
    return {
        "matched": len(matched),
        "expected": expected_count,
        "score": len(matched) / max(1, expected_count) if expected_count > 0 else None,
        "applicable": expected_count > 0,
        "rg_findings": rg_findings,
    }


def axis_fragments(actual: list[dict], expected: dict, used_indices: set[int]) -> dict:
    """B. fragment-fidelity for each matched rg: count match + sum-match.

    Two schemas: real-inputs use `fragments: number` (count assertion),
    Jodie uses `fragments: [{distance, expectsIntensity, ...}]` (array).
    """
    findings: list[dict] = []
    matched_count = 0
    total_count = 0
    for exp in expected.get("repGroups", []):
        if exp.get("exclude"): continue
        exp_frags_raw = exp.get("fragments")
        if exp_frags_raw is None: continue
        # Schema dispatch
        if isinstance(exp_frags_raw, int):
            # real-inputs: assert count == exp_frags_raw
            exp_frag_count = exp_frags_raw
            exp_sum = None
        elif isinstance(exp_frags_raw, list):
            # Jodie / stress: array of {distance, ...}
            exp_frags = exp_frags_raw
            exp_frag_count = len(exp_frags)
            exp_sum = sum(f["distance"] for f in exp_frags)
        else:
            continue
        total_count += 1
        idx = None
        for i, rg in enumerate(actual):
            if i in used_indices: continue
            if (rg.get("reps"), rg.get("distance"), _norm_interval(rg.get("interval"))) == (
                exp.get("reps"), exp.get("distance"), _norm_interval(exp.get("interval"))
            ):
                idx = i
                used_indices.add(i)
                break
        if idx is None:
            findings.append({"expected_rg": exp, "status": "RG_NOT_MATCHED"})
            continue
        actual_rg = actual[idx]
        actual_frags = actual_rg.get("fragments") or []
        actual_frag_count = len(actual_frags)
        actual_sum = sum(f.get("distance") or 0 for f in actual_frags)
        ok = actual_frag_count == exp_frag_count and (exp_sum is None or actual_sum == exp_sum)
        findings.append({
            "expected_frag_count": exp_frag_count,
            "actual_frag_count": actual_frag_count,
            "expected_frag_sum": exp_sum,
            "actual_frag_sum": actual_sum,
            "status": "matched" if ok else "MISMATCH",
        })
        if ok: matched_count += 1
    return {
        "matched": matched_count,
        "total": total_count,
        "score": matched_count / max(1, total_count) if total_count > 0 else None,
        "applicable": total_count > 0,
        "findings": findings,
    }


def axis_fragment_intensity(parsed: dict, expected: dict) -> dict:
    """C. per-fragment intensity completeness + type-match. Used only for
    Jodie (real-inputs don't assert fragment intensity)."""
    if "expectedFragmentCompleteness" not in expected:
        # For Jodie the assertions are embedded inside expectedRepGroups.
        pass
    findings: list[dict] = []
    matched = 0
    total = 0
    # Walk the live response's repGroups in document order; match against
    # expected rg with same triple.
    actual_rgs = _flat_rgs(parsed)
    used: set[int] = set()
    for exp in expected.get("expectedRepGroups", expected.get("repGroups", [])):
        if exp.get("exclude"): continue
        exp_frags = exp.get("fragments") or []
        if not exp_frags: continue
        idx = _best_match(actual_rgs, exp, used)
        if idx is None: continue
        used.add(idx)
        actual_rg = actual_rgs[idx]
        actual_frags = actual_rg.get("fragments") or []
        for fi, exp_frag in enumerate(exp_frags):
            total += 1
            if fi >= len(actual_frags):
                findings.append({"frag_idx": fi, "status": "MISSING_FRAGMENT"})
                continue
            af = actual_frags[fi]
            if not exp_frag.get("expectsIntensity"):
                matched += 1
                continue
            intensity = af.get("intensity")
            if not intensity or not intensity.get("type"):
                findings.append({"frag_idx": fi, "status": "MISSING_INTENSITY"})
                continue
            if intensity.get("type") != exp_frag.get("intensityType"):
                findings.append({"frag_idx": fi, "status": "WRONG_INTENSITY_TYPE", "got": intensity.get("type"), "expected": exp_frag.get("intensityType")})
                continue
            matched += 1
    return {
        "matched": matched,
        "total": total,
        "score": matched / max(1, total) if total > 0 else None,
        "applicable": total > 0,
        "findings": findings,
    }


def axis_noise(parsed: dict, expected: dict) -> dict:
    """D. unmapped_terms exact-set match. Jodie only (LLM path)."""
    if "expectedUnmappedTerms" not in expected:
        return {"applicable": False}
    actual = sorted(set(parsed.get("unmapped_terms") or []))
    expected_list = sorted(expected.get("expectedUnmappedTerms", []))
    noise_leaks = sorted(set(actual) - set(expected_list))
    missing_asks = sorted(set(expected_list) - set(actual))
    return {
        "applicable": True,
        "actual": actual,
        "expected": expected_list,
        "match": actual == expected_list,
        "noise_leaks": noise_leaks,
        "missing_asks": missing_asks,
        "score": 1.0 if actual == expected_list else 0.0,
    }


def axis_section(parsed: dict, expected: dict) -> dict:
    """E. section-vs-set classification. Two sub-checks:
       (i) section count >= min; (ii) notes (free-text) vs rgs not inverted.
    """
    actual_sections = parsed.get("sections", [])
    section_count = len(actual_sections)
    min_required = expected.get("expectedSectionCountMin", 1)
    section_ok = section_count >= min_required

    notes_expected = expected.get("notes", expected.get("expectedNotes", []))
    # For Jodie we don't track notes explicitly; skip the inversion check.
    notes_inversion_ok = True
    if notes_expected:
        notes_actual = sum(1 for rg in _flat_rgs(parsed) if rg.get("note"))
        notes_inversion_ok = notes_actual <= 2 * len(notes_expected) + 5  # heuristic: don't over-attach

    return {
        "section_count": section_count,
        "section_min": min_required,
        "section_ok": section_ok,
        "notes_inversion_ok": notes_inversion_ok,
        "applicable": True,
        "score": (1.0 if section_ok else 0.0) * (1.0 if notes_inversion_ok else 0.0),
    }


# ─── Per-corpus runners ───────────────────────────────────────────────────────

def run_real_input(input_file: Path, expected: dict) -> dict:
    parsed = _call_regex_engine(input_file)
    actual = _flat_rgs(parsed)
    used: set[int] = set()
    a = axis_structure(actual, expected)
    b = axis_fragments(actual, expected, used)
    c = {"applicable": False}  # real-inputs don't assert intensity per-frag
    d = {"applicable": False}  # regex path has no unmapped_terms
    e = axis_section(parsed, expected)
    return {
        "corpus": "real",
        "file": input_file.name,
        "axes": {"A_structure": a, "B_fragments": b, "C_intensity": c, "D_noise": d, "E_section": e},
        "aggregate_score": _aggregate({
            "A": a["score"], "B": b["score"], "C": None, "D": None, "E": e["score"],
        }),
    }


def run_jodie(input_file: Path, expected: dict, refresh: bool = True) -> dict:
    """Jodie uses the LIVE edge function. Refresh cached /tmp/jodie-parse-*.json
    if the cache is missing or older than --max-age-min."""
    cache_file = TMP_DIR / f"jodie-parse-{input_file.stem}.json"
    if refresh or not cache_file.exists():
        text = input_file.read_text("utf-8")
        parsed, elapsed = _call_edge_fn(text)
        cache_file.write_text(json.dumps(parsed, indent=2), "utf-8")
    else:
        parsed = json.loads(cache_file.read_text("utf-8"))
        elapsed = 0
    actual = _flat_rgs(parsed)
    used: set[int] = set()
    a = axis_structure(actual, expected)
    b = axis_fragments(actual, expected, used)
    c = axis_fragment_intensity(parsed, expected)
    d = axis_noise(parsed, expected)
    e = axis_section(parsed, expected)
    return {
        "corpus": "jodie",
        "file": input_file.name,
        "elapsed_s": round(elapsed, 2),
        "axes": {"A_structure": a, "B_fragments": b, "C_intensity": c, "D_noise": d, "E_section": e},
        "aggregate_score": _aggregate({
            "A": a["score"],
            "B": b["score"],
            "C": c.get("score"),
            "D": d.get("score") if d.get("applicable") else None,
            "E": e["score"],
        }),
    }


def run_stress(input_file: Path, expected: dict) -> dict:
    parsed = _call_regex_engine(input_file)
    actual = _flat_rgs(parsed)
    used: set[int] = set()
    a = axis_structure(actual, expected)
    b = axis_fragments(actual, expected, used)
    c = {"applicable": False}
    d = {"applicable": False}
    e = axis_section(parsed, expected)
    return {
        "corpus": "stress",
        "file": input_file.name,
        "axes": {"A_structure": a, "B_fragments": b, "C_intensity": c, "D_noise": d, "E_section": e},
        "aggregate_score": _aggregate({
            "A": a["score"], "B": b["score"], "C": None, "D": None, "E": e["score"],
        }),
    }


def _aggregate(axis_scores: dict[str, Optional[float]]) -> float:
    """Weighted mean of applicable axes. None scores are skipped (axis not
    asserted for this corpus). Structure is the load-bearing axis."""
    weights = {"A": 0.45, "B": 0.15, "C": 0.15, "D": 0.10, "E": 0.15}
    total_w = 0.0
    total_v = 0.0
    for k, w in weights.items():
        v = axis_scores.get(k)
        if v is None:
            continue
        total_v += v * w
        total_w += w
    return total_v / total_w if total_w > 0 else 0.0


# ─── Diff against a previous run ──────────────────────────────────────────────

def diff_against(prev_file: Path, current_results: list[dict]) -> dict:
    """Compare current run against a previous run JSON. Returns the set of
    files where any axis regressed (current < prev by more than 0.05)."""
    prev = json.loads(prev_file.read_text("utf-8"))
    prev_by_file = {r["file"]: r for r in prev.get("results", [])}
    regressions: list[dict] = []
    for cur in current_results:
        prev_r = prev_by_file.get(cur["file"])
        if not prev_r: continue
        for axis in ("A_structure", "B_fragments", "C_intensity", "D_noise", "E_section"):
            prev_score = prev_r["axes"].get(axis, {}).get("score")
            cur_score = cur["axes"].get(axis, {}).get("score")
            if prev_score is None or cur_score is None:
                continue
            if cur_score + 0.05 < prev_score:
                regressions.append({
                    "file": cur["file"], "axis": axis,
                    "prev": prev_score, "current": cur_score,
                })
    return {"regressions": regressions, "prev_file": str(prev_file)}


# ─── Main ──────────────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", choices=["real", "jodie", "stress", "all"], default="all")
    parser.add_argument("--refresh-jodie", action="store_true",
                        help="Re-POST Jodie files to the live edge function (otherwise use /tmp cache)")
    parser.add_argument("--diff", type=str, help="Path to a previous run JSON to diff against")
    parser.add_argument("--quiet", action="store_true")
    parser.add_argument("--strict", action="store_true",
                        help="Exit 1 if any file scores < 0.85 OR has unmapped_terms noise leaks. For CI.")
    args = parser.parse_args()

    RUNS_DIR.mkdir(parents=True, exist_ok=True)

    expected_real = json.loads(EXPECTED_REAL.read_text("utf-8")) if EXPECTED_REAL.exists() else {}
    expected_jodie = json.loads(EXPECTED_JODIE.read_text("utf-8")) if EXPECTED_JODIE.exists() else {}
    expected_stress = json.loads(EXPECTED_STRESS.read_text("utf-8")) if EXPECTED_STRESS.exists() else {}

    results: list[dict] = []

    if args.corpus in ("real", "all"):
        for name in sorted(expected_real):
            f = BENCH_DIR / name
            if not f.exists(): continue
            results.append(run_real_input(f, expected_real[name]))

    if args.corpus in ("jodie", "all"):
        for name in sorted(expected_jodie):
            f = BENCH_DIR / name
            if not f.exists(): continue
            results.append(run_jodie(f, expected_jodie[name], refresh=args.refresh_jodie))

    if args.corpus in ("stress", "all"):
        for name in sorted(expected_stress):
            f = BENCH_DIR / name
            if not f.exists(): continue
            results.append(run_stress(f, expected_stress[name]))

    # Aggregate
    n = len(results)
    if n == 0:
        print("no files scored — check expected.*.json exists", file=sys.stderr)
        return 1
    agg = {
        "files": n,
        "mean_aggregate": sum(r["aggregate_score"] for r in results) / n,
        "axis_means": {},
    }
    for axis in ("A_structure", "B_fragments", "C_intensity", "D_noise", "E_section"):
        scores = [r["axes"].get(axis, {}).get("score") for r in results
                  if r["axes"].get(axis, {}).get("applicable", True) and r["axes"].get(axis, {}).get("score") is not None]
        agg["axis_means"][axis] = sum(scores) / max(1, len(scores)) if scores else None

    # Save run
    date = time.strftime("%Y-%m-%d")
    commit = subprocess.run(
        ["git", "-C", str(BENCH_DIR.parent.parent), "rev-parse", "--short", "HEAD"],
        capture_output=True, text=True,
    ).stdout.strip() or "no-commit"
    run_path = RUNS_DIR / f"{date}-{commit}.json"
    payload = {
        "date": date,
        "commit": commit,
        "corpus": args.corpus,
        "aggregate": agg,
        "results": results,
    }
    run_path.write_text(json.dumps(payload, indent=2), "utf-8")

    if not args.quiet:
        # Print per-file table
        print(f"=== BENCH {date} @ {commit} — {n} files ===\n")
        print(f"{'corpus':<8} {'file':<40} {'A':>5} {'B':>5} {'C':>5} {'D':>5} {'E':>5}  {'agg':>5}")
        for r in results:
            axes = r["axes"]
            def s(k):
                v = axes.get(k, {})
                if not v.get("applicable", True) or v.get("score") is None:
                    return "—"
                return f"{v['score']:.2f}"
            print(f"{r['corpus']:<8} {r['file']:<40} {s('A_structure'):>5} {s('B_fragments'):>5} {s('C_intensity'):>5} {s('D_noise'):>5} {s('E_section'):>5}  {r['aggregate_score']:.2f}")
        print(f"\n=== AGGREGATE ===")
        print(f"  files:           {agg['files']}")
        print(f"  mean_aggregate:  {agg['mean_aggregate']:.3f}")
        for k, v in agg["axis_means"].items():
            print(f"  {k:<16} {v:.3f}" if v is not None else f"  {k:<16} —")
        print(f"\nRun saved: {run_path}")

    if args.diff:
        diff = diff_against(Path(args.diff), results)
        if diff["regressions"]:
            print(f"\n!!! REGRESSIONS vs {diff['prev_file']}:")
            for r in diff["regressions"]:
                print(f"   {r['file']:<40} {r['axis']:<14}  prev={r['prev']:.2f}  current={r['current']:.2f}")
            return 2
        else:
            print(f"\n[OK] no regressions vs {diff['prev_file']}")

    if args.strict:
        # Per-file gate: any file with aggregate < 0.85 OR noise leaks → fail.
        failing: list[tuple[str, str, float]] = []
        for r in results:
            if r["aggregate_score"] < 0.85:
                failing.append((r["file"], "aggregate", r["aggregate_score"]))
            d = r["axes"].get("D_noise", {})
            if d.get("applicable") and d.get("noise_leaks"):
                failing.append((r["file"], "noise_leaks", 0.0))
        if failing:
            print(f"\n!!! STRICT MODE FAIL ({len(failing)} files below threshold):")
            for f, axis, score in failing:
                print(f"   {f:<40} {axis:<14}  score={score:.2f}")
            return 3
        else:
            print(f"\n[OK] all {n} files ≥ 0.85 aggregate + zero noise leaks")
    return 0


if __name__ == "__main__":
    sys.exit(main())
