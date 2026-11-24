# Clean-up evaluation

The reference for UFlow's on-device clean-up step. A local model suggests
cleaned text (stutters, restarts and corrections removed, punctuation added).
`guard.py` then decides what is kept. The model can only delete words when the
deletion is proven, add punctuation and change casing. A word it changed or
added is reverted. An English list or paragraph layout is rebuilt from the
spoken words, never copied from the model.

The Swift version in the app has to pass these same cases.

## Test sets

| File | Cases | What it covers |
|:--|:--|:--|
| `cases.json` | 20 | Bangla/Banglish stutters, restarts, corrections, rhetorical `?`. The rules were tuned on these. |
| `heldout.json` | 36 | Fresh Bangla + English cases, written after the rules |
| `english_format.json` | 28 | English lists, paragraphs, email layout (partly tuned) |
| `english_format_heldout.json` | 13 | Fresh layout cases |

Each case is `{kind, said, want}`. The "said" text is unpunctuated, as the
speech model writes it. Bangla goes in as Bangla script, because clean-up runs
before romanization.

## Running

Needs [Ollama](https://ollama.com) with the models pulled
(`ollama pull gemma4:e2b gemma4:e4b`).

```sh
cd tools/cleanup-eval
python3 -I guard.py gemma4:e2b gemma4:e4b                                   # cases.json
CASES=heldout.json OUT=/tmp/heldout_results.json python3 -I guard.py gemma4:e2b
```

The grades are **right**, **partial** (only proven deletions, but not all of
them), **unchanged** (only punctuation added) and **WRONG**. WRONG must stay at
0 for every model and every set.

Results on 2026-11-24:

| Model | Right | WRONG |
|:--|:--|:--|
| gemma4:e2b | 43/56 | 0 |
| gemma4:e4b | 46/56 | 0 |
| gemma4:12b | 53/56 | 0 |

The 56 cases are `cases.json` plus `heldout.json`.
