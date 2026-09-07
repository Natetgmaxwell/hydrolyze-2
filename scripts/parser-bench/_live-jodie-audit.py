#!/usr/bin/env python3
"""_live-jodie-audit.py — live parse-workout audit on the 8 Jodie corpus files.

Sends each commit-jodie-NN file to the deployed edge function with NO auth
header (so coachVocabulary=[] — baseline, worst case for unmapped_terms
detection) and writes the response JSONs to /tmp/jodie-parse-NN.json plus a
combined summary to stdout.

Usage:
    python3 scripts/parser-bench/_live-jodie-audit.py
"""

import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

PROJECT_REF = "flidjtldfvrrntzwtnsq"
URL = f"https://{PROJECT_REF}.supabase.co/functions/v1/parse-workout"
BENCH_DIR = Path(__file__).resolve().parent

FILES = sorted(BENCH_DIR.glob("commit-jodie-*.txt"))


def call_parse(text: str) -> tuple[dict, float]:
    body = json.dumps({"workoutText": text}).encode("utf-8")
    req = urllib.request.Request(
        URL,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    t0 = os.times()[4] if hasattr(os.times(), "__getitem__") else 0
    import time
    t0 = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            return data, time.monotonic() - t0
    except urllib.error.HTTPError as e:
        return {"_http_error": e.code, "_body": e.read().decode("utf-8")[:500]}, time.monotonic() - t0
    except Exception as e:
        return {"_exception": str(e)}, time.monotonic() - t0


def summarize(file: Path, parsed: dict, dt: float) -> dict:
    sections = parsed.get("sections", [])
    rg_count = 0
    frag_count = 0
    unmapped = parsed.get("unmapped_terms", []) or []
    for sec in sections:
        for ns in sec.get("namedSets", []):
            for rg in ns.get("repGroups", []):
                rg_count += 1
                for f in rg.get("fragments") or []:
                    frag_count += 1
    return {
        "file": file.name,
        "http_status": parsed.get("_http_error", 200),
        "elapsed_s": round(dt, 2),
        "sections": len(sections),
        "repGroups": rg_count,
        "fragments": frag_count,
        "unmapped_terms": sorted(set(unmapped)),
        "session_type": parsed.get("session_type"),
    }


def main() -> int:
    if not FILES:
        print("NO FILES FOUND", file=sys.stderr)
        return 1
    results = []
    print(f"=== LIVE AUDIT: {len(FILES)} Jodie files → {URL} (no-auth baseline) ===\n")
    for file in FILES:
        text = file.read_text("utf-8")
        parsed, dt = call_parse(text)
        out_file = Path(f"/tmp/jodie-parse-{file.stem}.json")
        out_file.write_text(json.dumps(parsed, indent=2), "utf-8")
        s = summarize(file, parsed, dt)
        results.append(s)
        print(
            f"  {file.name:30s}  HTTP {s['http_status']}  {s['elapsed_s']:5.2f}s"
            f"  sec={s['sections']:2d} rg={s['repGroups']:3d} frag={s['fragments']:2d}"
            f"  unmapped={s['unmapped_terms']}"
        )
    print()
    Path("/tmp/jodie-audit-summary.json").write_text(json.dumps(results, indent=2), "utf-8")
    print("Summary written to /tmp/jodie-audit-summary.json")
    print("Per-file responses in /tmp/jodie-parse-*.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
