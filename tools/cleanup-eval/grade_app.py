"""Grades `UFlow --cleanup-run` output with guard.py's own grade(), so the app's
real pipeline (llama.cpp + Swift guard) is held to the same bar: WRONG must be 0.

    UFlow --cleanup-run e2b /tmp/app_e2b.json tools/cleanup-eval/*.json   (the four case files)
    python3 -I tools/cleanup-eval/grade_app.py /tmp/app_e2b.json
"""
import json, os, statistics, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from guard import grade

for path in sys.argv[1:]:
    rows = json.load(open(path))
    by_set = {}
    for r in rows:
        by_set.setdefault(r["set"], []).append((grade(r, r["final"]), r))
    print(f"== {path}")
    for name, graded in sorted(by_set.items()):
        counts = {g: sum(1 for x, _ in graded if x == g) for g in ("right", "partial", "unchanged", "WRONG")}
        print(f"  {name:30} " + "  ".join(f"{k} {v}" for k, v in counts.items()))
        for g, r in graded:
            if g == "WRONG":
                print(f"    WRONG  said: {r['said']!r}\n           want: {r['want']!r}\n           got:  {r['final']!r}")
    ms = [r["ms"] for r in rows]
    print(f"  time per dictation: median {statistics.median(ms)} ms, max {max(ms)} ms")
