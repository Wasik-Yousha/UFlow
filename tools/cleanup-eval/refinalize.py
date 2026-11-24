"""Recomputes `flat`/`final` in recorded/*.json from each row's recorded model
outputs with the current guard.py, so the Swift parity replay tracks guard.py
after a guard change. Model outputs are never touched."""
import glob, json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import guard

changed = 0
for path in sorted(glob.glob(os.path.join(os.path.dirname(os.path.abspath(__file__)), "recorded", "*.json"))):
    data = json.load(open(path))
    for model, rows in data.items():
        for r in rows:
            answers = iter([r["raw"]] + ([r["layout_raw"]] if r.get("layout_raw") is not None else []))
            guard.ask = lambda *a, **k: next(answers)
            final, info = guard.clean(model, r["said"])
            if final != r["final"] or info.get("flat", r.get("flat")) != r.get("flat"):
                changed += 1
                print(f"{os.path.basename(path)} [{model}] {r['said']!r}\n   was {r['final']!r}\n   now {final!r}")
            r["final"] = final
            if "flat" in info: r["flat"] = info["flat"]
    json.dump(data, open(path, "w"), ensure_ascii=False, indent=1)
print(f"{changed} rows changed")
