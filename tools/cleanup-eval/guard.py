"""UFlow clean-up prototype: the model suggests, the guard decides.
The model's text is projected back onto the words actually spoken, so it can only
(1) delete words, with proof, and (2) add punctuation / sentence capitals."""
import os, json, re, time, urllib.request, sys, statistics

SYSTEM = """You add punctuation to dictated speech and remove stumbles. Output only the result.
Remove ONLY: a word said twice by accident; a phrase the speaker abandoned and restarted; a value the speaker corrected ("five, no sorry, six" -> "six").
Keep everything else exactly: same words, same order, same script. English words stay in English letters. Never translate. Never remove names.
Add commas, । or . at sentence ends, and ? for questions, including rhetorical ones."""
SHOTS = [
 ("আমি আমি বলতে চাচ্ছিলাম যে মানে আমি কালকে অফিসে যাবো না", "আমি বলতে চাচ্ছিলাম যে, আমি কালকে অফিসে যাবো না।"),
 ("শোনো রাফি তোমাকে একটা জিনিস বলার ছিল মানে আসলে আচ্ছা যেটা বলছিলাম আজকে মিটিং টা পাঁচটায় হবে", "শোনো রাফি, আজকে মিটিং টা পাঁচটায় হবে।"),
 ("এভাবে কাজ করলে তুই টাকা পাবি কোনোদিন আগে প্ল্যান টা ঠিক কর", "এভাবে কাজ করলে তুই টাকা পাবি কোনোদিন? আগে প্ল্যান টা ঠিক কর।"),
 ("My name is Yusha মানে আমার নাম ইউশা", "My name is Yusha, মানে আমার নাম ইউশা।"),
 ("সে সে আজকে আসবে না", "সে আজকে আসবে না।"),
 ("call him at three no wait at four", "Call him at four."),
 ("ছোট ছোট কাজ গুলো আগে শেষ করো", "ছোট ছোট কাজ গুলো আগে শেষ করো।"),
 ("presentation টা কালকে দিবো নাকি আজকেই দিবো", "presentation টা কালকে দিবো নাকি আজকেই দিবো?"),
]

PUNCT = ",.।?!;:"
MARKERS = {"মানে", "আচ্ছা", "না", "sorry", "wait", "mean", "সরি", "নাহ"}
CALL_WORDS = {"শোনো", "শুনো", "ভাই", "আপা", "আপু", "দোস্ত", "hey", "hi", "hello", "listen"}

def norm(w): return w.strip(PUNCT + "\"'").lower().replace("'", "").replace("\u2019", "")

def protected(words):
    """Indices never deletable: the name after a call word ('শোনো ইউশা', 'ভাই রাকিব'),
    and English words with a capital mid-sentence (names, products)."""
    keep = set()
    for i, w in enumerate(words):
        if norm(w) in CALL_WORDS and i + 1 < len(words) and norm(words[i + 1]) not in CALL_WORDS:
            keep.add(i + 1)
        if i > 0 and w[:1].isupper() and w[:1].isascii():
            keep.add(i)
    return keep

def align(a, b):
    """Edit-distance alignment of spoken words a and model words b (normalised)."""
    n, m = len(a), len(b)
    D = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(1, n + 1): D[i][0] = D[i-1][0] + (0.9 if a[i-1] in MARKERS else 1)
    for j in range(m + 1): D[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            dc = 0.9 if a[i-1] in MARKERS else 1
            D[i][j] = min(D[i-1][j] + dc, D[i][j-1] + 1, D[i-1][j-1] + (0 if a[i-1] == b[j-1] else 1))
    ops, i, j = [], n, m
    while i or j:
        if i and j and abs(D[i][j] - (D[i-1][j-1] + (0 if a[i-1] == b[j-1] else 1))) < 1e-9:
            ops.append(("keep", i-1, j-1)); i, j = i-1, j-1
        elif i and abs(D[i][j] - (D[i-1][j] + (0.9 if a[i-1] in MARKERS else 1))) < 1e-9:
            ops.append(("del", i-1, None)); i -= 1
        else:
            ops.append(("ins", None, j-1)); j -= 1
    return ops[::-1]

STRONG = {"no wait", "i mean", "না না", "sorry", "সরি", "no sorry", "না সরি", "wait"}
RESUME = ["যেটা বলছিলাম", "যেটা বলতেছিলাম", "যেটা বলতেছি", "যেটা বলতে চাচ্ছিলাম", "যা বলছিলাম",
          "what i was saying", "as i was saying"]
NEVER_STUTTER = {"না", "no", "very", "অনেক", "খুব"}   # "না না" is emphasis or a correction, never a slip

def proof(words, s, e):
    """Why deleting words[s:e] is justified: 'stutter', 'strong', 'weak' or None."""
    span = [norm(w) for w in words[s:e]]
    after = [norm(w) for w in words[e:]]
    if not after: return None                                   # nothing to restart into
    if after[:len(span)] == span and not (set(span) & NEVER_STUTTER): return "stutter"
    text = " ".join(span)
    if len(span) >= 2:
        for m in STRONG:                                           # "... Rafi no wait"
            if text.endswith(m) and len(span) > len(m.split()): return "strong"
        # restart that resumes: something abandoned, then আচ্ছা/মানে + "যেটা বলছিলাম"
        for r in RESUME:
            if text.endswith(r):
                head = span[:len(span) - len(r.split())]
                if any(m in head[1:] for m in ("আচ্ছা", "মানে", "okay", "anyway")): return "strong"
        # "মানে" proves a restart only when the speaker then repeats or says আচ্ছা
        if span[-1] in ("মানে", "আচ্ছা") and (after[0] in span or after[0] == "আচ্ছা"): return "weak"
        if span[-1] == "না" and len(span) >= 2:                 # "তিনটা না চারটা": parallel words
            a, b = span[-2], after[0]
            if len(a) > 2 and a != b and a[-2:] == b[-2:]: return "weak"
    return None

def span_ok(words, s, e): return proof(words, s, e) is not None

def project(spoken, model_out):
    words = spoken.split()
    out = model_out.split()
    ops = align([norm(w) for w in words], [norm(w) for w in out])
    kept = {}                      # spoken index -> punctuation/casing taken from the model
    for op, i, j in ops:
        if op == "keep":           # same word or the model changed it: the spoken word stays
            mw = out[j]
            trail = re.sub(r"^.*?([" + PUNCT + r"]*)$", r"\1", mw)
            core = words[i].strip(PUNCT)
            if norm(mw) == norm(core): core = mw.strip(PUNCT)    # casing only
            kept[i] = core + trail
    # Deleted runs must be proven; otherwise they come back.
    prot = protected(words)
    restored = set()
    i = 0
    while i < len(words):
        if i in kept: i += 1; continue
        e = i
        while e < len(words) and e not in kept: e += 1
        s = i
        while e > s and e < len(words) and norm(words[e-1]) == norm(words[e]) and norm(words[e]) not in NEVER_STUTTER:
            e -= 1                 # a stutter at the end of the run is proven on its own
        why = proof(words, s, e) if e > s else "stutter"
        if why is None or (why != "strong" and any(k in prot for k in range(s, e))):
            for k in range(s, e): kept[k] = words[k]; restored.add(k)
        i = max(e, i + 1)
    # an end mark the model put just before words we put back moves to after them
    order = sorted(kept)
    for n, k in enumerate(order[:-1]):
        nxt = order[n + 1]
        if nxt in restored and kept[k][-1:] in ".।?!":
            mark = kept[k][-1]; kept[k] = kept[k][:-1]
            run_end = nxt
            while run_end + 1 in restored: run_end += 1
            if kept[run_end][-1:] not in ".।?!": kept[run_end] += mark
    text = " ".join(kept[k] for k in sorted(kept))
    text = re.sub(r"\s+([" + PUNCT + r"])", r"\1", text)
    return text[:1].upper() + text[1:] if text[:1].isascii() else text

def ask(model, text, system=None, shots=None, multiline=False):
    msgs = [{"role": "system", "content": system or SYSTEM}]
    for a, b in (shots or SHOTS): msgs += [{"role": "user", "content": a}, {"role": "assistant", "content": b}]
    msgs.append({"role": "user", "content": text})
    body = json.dumps({"model": model, "stream": False, "think": False, "keep_alive": "10m",
                       "options": {"temperature": 0}, "messages": msgs}).encode()
    r = urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:11434/api/chat", body, {"Content-Type": "application/json"}))
    out = json.load(r)["message"]["content"].strip()
    return out if multiline else out.splitlines()[0]

def words(s): return re.sub(r"[" + PUNCT + r"]", " ", s.lower().replace("'", "").replace("\u2019", "")).split()
def qs(s): return [words(p)[-1] if words(p) else "" for p in s.split("?")[:-1]]

def struct(s):
    """Line structure: one (is_list_item, words) per non-empty line."""
    return [(bool(re.match(LIST_MARK, ln)), tuple(words(re.sub(LIST_MARK, "", ln))))
            for ln in s.split("\n") if ln.strip()]
def flatwords(s): return [w for _, ws in struct(s) for w in ws]

def grade(c, out):
    """right: words AND line structure match. A layout the case does not want (lines in a one-line
    case, or list items that differ from the wanted ones) is WRONG even if the words are right;
    a missing layout or differently placed paragraph breaks is only partial."""
    wo, ww, ws = flatwords(out), flatwords(c["want"]), flatwords(c["said"])
    so, sw = struct(out), struct(c["want"])
    items_o, items_w = [w for i, w in so if i], [w for i, w in sw if i]
    bad_layout = (len(so) > 1 and len(sw) == 1) or (items_o and (len(items_o) != len(items_w) or (wo == ww and items_o != items_w)))
    if wo == ww:
        if so == sw: return "right"
        return "WRONG" if bad_layout else "partial"
    if bad_layout: return "WRONG"
    if wo == ws: return "unchanged"     # safe: nothing removed, nothing wrong
    def subseq(a, b):
        it = iter(b); return all(x in it for x in a)
    if subseq(wo, ws) and subseq(ww, wo): return "partial"
    return "WRONG"

def main():
    cases = json.load(open(os.environ.get("CASES", "cases.json")))
    results = {}
    for model in sys.argv[1:]:
        ask(model, "আমি ভালো আছি")
        rows = []
        for c in cases:
            t = time.time(); final, info = clean(model, c["said"]); dt = time.time() - t
            raw = info["raw"]
            rows.append({**c, **info, "final": final, "sec": round(dt, 2),
                         "raw_grade": grade(c, raw), "grade": grade(c, final), "q_ok": qs(final) == qs(c["want"])})
        results[model] = rows
        def count(key, g): return sum(r[key] == g for r in rows)
        print(f"{model:16} model alone: right {count('raw_grade','right')}, WRONG {count('raw_grade','WRONG')} | "
              f"with guard: right {count('grade','right')}, partial {count('grade','partial')}, unchanged {count('grade','unchanged')}, WRONG {count('grade','WRONG')} | "
              f"? right {sum(r['q_ok'] for r in rows)}/{len(rows)} | median {statistics.median(r['sec'] for r in rows):.2f}s")
    json.dump(results, open(os.environ.get("OUT", "guard_results.json"), "w"), ensure_ascii=False, indent=1)

# --- question marks: the model may only ask when the sentence asks ---
Q_BN = {"কি", "কী", "কেন", "কোথায়", "কখন", "কে", "কাকে", "কার", "কেমন", "কত", "কিভাবে", "কীভাবে", "কোন",
        "কোনটা", "কোনো", "নাকি", "কোনোদিন", "জীবনে", "তাই", "কেনো", "কই", "ক্যান", "কিসের", "কয়টা"}
Q_EN_START = {"who", "what", "when", "where", "why", "how", "which", "can", "could", "would", "will", "should",
              "do", "does", "did", "is", "are", "was", "were", "have", "has", "may", "shall", "am", "isn't", "aren't",
              "don't", "doesn't", "didn't", "won't", "can't", "shouldn't", "wouldn't", "couldn't"}
def fix_questions(text):
    parts = re.split(r"(?<=[.।?!])\s+", text)
    out = []
    for p in parts:
        if p.endswith("?"):
            ws = [norm(w) for w in p.split()]
            asks = bool(set(ws) & Q_BN) or (ws and ws[0] in Q_EN_START) or "right" in ws[-1:] or "okay" in ws[-1:]
            if not asks:
                p = p[:-1] + ("।" if re.search(r"[ঀ-৿]", p) else ".")
        if p.endswith("।") and not re.search(r"[\u0980-\u09FF]", p):
            p = p[:-1] + "."
        out.append(p)
    return " ".join(out)

# --- English layout: the model proposes line structure, the guard decides ---
# Pass 2 runs only on English text the gate flags (an ordinal sequence, an email, or long dictation).
# The model's layout is mapped onto the pass-1 words. It may only insert line breaks and list markers
# and delete the ordinal words that became list markers. The guard then renders the layout itself
# from the pass-1 words; any break it cannot justify is dropped, any word change rejects the layout.
LAYOUT_SYSTEM = """You lay out dictated English text. Output only the result.
Never change, add, remove or reorder words, except the ordinal words that become list numbers. You may only insert line breaks and list numbers.
- If the speaker enumerates items with first/second/third, firstly/secondly, number one/number two, next or finally: end the sentence before the items with a colon, put each item on its own line as "1.", "2.", ... and drop the ordinal word.
- An ordinal that is part of the sentence ("first of all", "the second time", "came first", "my number one priority") is not a list: leave the text as it is.
- An email: greeting line, blank line, body, blank line, sign-off.
- Long text that changes topic: put a blank line between the topics.
- Otherwise return the text unchanged on one line."""
LAYOUT_SHOTS = [
 ("We have two options, first we rent a bigger office and second we let people work from home.",
  "We have two options:\n1. We rent a bigger office.\n2. We let people work from home."),
 ("Here are the steps. Firstly, open the settings, secondly choose privacy and finally turn off tracking. That should fix it.",
  "Here are the steps:\n1. Open the settings.\n2. Choose privacy.\n3. Turn off tracking.\n\nThat should fix it."),
 ("Two things for today, number one, call the landlord, number two, pay the electricity bill.",
  "Two things for today:\n1. Call the landlord.\n2. Pay the electricity bill."),
 ("The first car we bought was red, and the second one was blue.",
  "The first car we bought was red, and the second one was blue."),
 ("Hello Maya, thanks for sending the draft. I read it last night and it looks good. I left a few small comments on the second page. Best regards.",
  "Hello Maya,\n\nThanks for sending the draft. I read it last night and it looks good. I left a few small comments on the second page.\n\nBest regards."),
 ("We moved into the new flat on Saturday. The kitchen is bigger than we expected and the kids love their rooms. The internet is still not connected. At work, the audit starts next week. I have to prepare the expense reports by Wednesday. My manager wants a summary on Friday.",
  "We moved into the new flat on Saturday. The kitchen is bigger than we expected and the kids love their rooms. The internet is still not connected.\n\nAt work, the audit starts next week. I have to prepare the expense reports by Wednesday. My manager wants a summary on Friday."),
]

ORDINAL = {"first": 1, "firstly": 1, "second": 2, "secondly": 2, "third": 3, "thirdly": 3, "fourth": 4,
           "fourthly": 4, "fifth": 5, "fifthly": 5, "sixth": 6, "sixthly": 6, "seventh": 7}
CARD = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10}
CARD.update({str(k): k for k in range(1, 11)})
LAST_W = {"finally", "lastly"}
CONNECT = {"and", "also"}
DET = {"the", "a", "an", "my", "our", "your", "his", "her", "their", "its", "this", "that", "these", "those"}
# after a list marker the item must read on its own: an ordinal followed by these is part of the sentence
# ("number one on my list is", "first place went", "the second time")
NOT_ITEM_START = {"is", "was", "are", "were", "will", "would", "has", "had", "on", "in", "at", "of", "for",
                  "to", "from", "with", "by", "about", "than", "time", "times", "place", "person", "thing",
                  "one", "ones", "priority", "and", "or", "but"}
GREET = {"hi", "hello", "hey", "dear"}
SIGNOFF = {"thanks", "thank", "cheers", "regards", "best", "sincerely", "many", "kind", "warm", "warmest"}
END = ".?!"

def marker(ws, i):
    """(rank, length) of an enumeration marker at ws[i]; rank is 1..n, 'mid' (next/then) or 'last'."""
    w = ws[i] if i < len(ws) else ""
    nx = ws[i + 1] if i + 1 < len(ws) else ""
    if w == "number" and nx in CARD: return CARD[nx], 2
    if w in ORDINAL:
        if nx == "of" and ws[i + 2:i + 3] == ["all"]: return ORDINAL[w], 3
        return ORDINAL[w], 1
    if w in LAST_W: return "last", 1
    if w in ("next", "then"):
        if nx in LAST_W: return "last", 2                    # "then finally"
        return "mid", 1
    if w == "after" and nx == "that": return "mid", 2
    return None

def lead_marker(ws, s, e):
    """An item span must open with [connectors] marker: returns (rank, marker_pos, content_start)."""
    i = s
    while i < e:
        m = marker(ws, i)
        if m: return m[0], i, i + m[1]
        if ws[i] in CONNECT: i += 1; continue
        return None
    return None

def valid_sequence(ranks):
    n = len(ranks)
    if n < 2 or ranks[0] != 1: return False
    for k, r in enumerate(ranks[1:], 1):
        if not (r == k + 1 or (r == "mid" and k < n - 1) or (r == "last" and k == n - 1)): return False
    return 2 in ranks or (n >= 3 and ranks[-1] == "last")

def sentences(text): return len(re.findall(r"[" + END + r"](?=\s|$)", text))
def is_long(text): return sentences(text) >= 4 and len(text.split()) >= 40
def is_greeting(ws): return 2 <= len(ws) <= 4 and ws[0] in GREET
def is_signoff(ws): return 1 <= len(ws) <= 4 and ws[0] in SIGNOFF and (ws[0] != "thank" or ws[1:2] == ["you"])

def needs_layout(text):
    """Cheap gate: only these texts are sent to the layout prompt; everything else stays one line."""
    if re.search(r"[ঀ-৿]", text): return False
    ws = [norm(w) for w in text.split()]
    ranks = [m[0] if (m := marker(ws, i)) else None for i in range(len(ws))]
    if 1 in ranks:
        rest = [r for r in ranks[ranks.index(1) + 1:] if r]
        if 2 in rest or ("last" in rest and len(rest) >= 2): return True
    tail = re.split(r"(?<=[" + END + r"])\s+", text)[-1]
    if ws and ws[0] in GREET and is_signoff([norm(w) for w in tail.split()]) and len(ws) >= 20: return True
    return is_long(text)

LIST_MARK = r"^\s*(?:\d+[.)]|[-*•])\s+"
def parse_layout(text):
    lines = []
    for ln in text.split("\n"):
        item = bool(re.match(LIST_MARK, ln))
        toks = [t for t in re.sub(LIST_MARK, "", ln).split() if re.search(r"\w", t)]
        if toks: lines.append({"item": item, "toks": toks})
    return lines

def cap(s): return s[:1].upper() + s[1:] if s[:1].islower() and not any(c.isupper() for c in s.split()[0][1:]) else s

def layout(flat, model_out):
    """Returns (text, note). Falls back to `flat` whenever the proposed layout is not provably safe."""
    toks = flat.split()
    cw = [norm(t) for t in toks]
    lines = parse_layout(model_out)
    if len(lines) < 2: return flat, "one line"
    mt = [t for L in lines for t in L["toks"]]
    owner = [k for k, L in enumerate(lines) for _ in L["toks"]]
    line_end_mark = {}
    for k, L in enumerate(lines): line_end_mark[k] = L["toks"][-1][-1:] in END + ":"
    line_of, deleted = [None] * len(toks), set()
    for op, i, j in align(cw, [norm(t) for t in mt]):
        if op == "ins" or (op == "keep" and cw[i] != norm(mt[j])): return flat, "word changed"
        if op == "keep": line_of[i] = owner[j]
        else: deleted.add(i)
    nxt = None                                         # a deleted word belongs to the next line
    for i in reversed(range(len(toks))):
        if line_of[i] is None: line_of[i] = nxt
        else: nxt = line_of[i]
    last = None
    for i in range(len(toks)):
        if line_of[i] is None: line_of[i] = last
        last = line_of[i]
    segs = []
    for i, k in enumerate(line_of):
        if segs and segs[-1]["line"] == k: segs[-1]["e"] = i + 1
        else: segs.append({"line": k, "s": i, "e": i + 1, "item": lines[k]["item"]})
    if not any(g["item"] for g in segs):               # "First, ...\nSecond, ..." without numbers
        cand = [g for g in segs if lead_marker(cw, g["s"], g["e"])]
        if len(cand) >= 2:
            for g in cand: g["item"] = True
    # --- the list ---
    items = [k for k, g in enumerate(segs) if g["item"]]
    if items and items[0] > 0:                         # "Preheat the oven,\n1. Mix ..." : item 1 left unnumbered
        lm = lead_marker(cw, segs[items[0] - 1]["s"], segs[items[0] - 1]["e"])
        if lm and lm[0] == 1 and lm[1] == segs[items[0] - 1]["s"]:
            segs[items[0] - 1]["item"] = True; items.insert(0, items[0] - 1)
    has_list = False
    if items:
        if items != list(range(items[0], items[-1] + 1)): return flat, "list not contiguous"
        ranks = []
        for n, k in enumerate(items):
            g = segs[k]
            lm = lead_marker(cw, g["s"], g["e"])
            if not lm: return flat, "item without ordinal"
            rank, mpos, cs = lm
            ce = g["e"]
            if n + 1 < len(items):
                while ce > cs and cw[ce - 1] in CONNECT: ce -= 1
            if ce <= cs: return flat, "empty item"
            if cw[cs] in NOT_ITEM_START: return flat, "ordinal is part of the sentence"
            p = mpos - 1
            while p >= 0 and cw[p] in CONNECT: p -= 1
            if p >= 0 and cw[p] in DET: return flat, "ordinal after a determiner"
            g["cs"], g["ce"] = cs, ce
            ranks.append(rank)
        if not valid_sequence(ranks): return flat, f"bad sequence {ranks}"
        if items[0] > 0:                               # "three things" must mean three items
            intro = cw[segs[items[0] - 1]["s"]:segs[items[0] - 1]["e"]]
            counts = [CARD[w] for w in intro if w in CARD and CARD[w] >= 2]
            if counts and counts[-1] != len(items): return flat, "count mismatch"
        has_list = True
    allowed_del = set()
    for k in items:
        g = segs[k]
        allowed_del |= set(range(g["s"], g["cs"])) | set(range(g["ce"], g["e"]))
    rest = sorted(deleted - allowed_del)              # any other deletion needs pass-1 proof
    prot = protected(toks)
    while rest:
        s = e = rest[0]
        while e + 1 in deleted - allowed_del: e += 1
        why = proof(toks, s, e + 1)
        if why is None or (why != "strong" and any(k in prot for k in range(s, e + 1))):
            return flat, "unproven deletion"
        rest = [k for k in rest if k > e]
    # --- the other breaks: keep only those the guard can justify ---
    long_ok = is_long(flat)
    sign = is_signoff(cw[segs[-1]["s"]:segs[-1]["e"]]) and not segs[-1]["item"]
    g0 = segs[0]
    if (has_list or long_ok or sign) and not g0["item"] and not is_greeting(cw[g0["s"]:g0["e"]]):
        for k in range(g0["s"] + 1, min(g0["s"] + 4, g0["e"] - 1)):   # "Hello team, quick update ..."
            if toks[k].endswith(",") and is_greeting(cw[g0["s"]:k + 1]):
                segs.insert(0, {"line": g0["line"], "s": g0["s"], "e": k + 1, "item": False})
                g0["s"] = k + 1
                break
    greet = is_greeting(cw[segs[0]["s"]:segs[0]["e"]]) and not segs[0]["item"]
    email = greet and sign
    merged = [segs[0]]
    for k in range(1, len(segs)):
        g, prev = segs[k], merged[-1]
        at_end = toks[prev["e"] - 1][-1:] in END
        intro_next = k + 1 < len(segs) and segs[k + 1]["item"]
        ok = (g["item"]
              or prev["item"] and (at_end or line_end_mark[prev["line"]])          # closing after a list
              or k == 1 and greet and (email or has_list or long_ok)              # "Hi Rafi,"
              or k == len(segs) - 1 and sign and (email or has_list or long_ok)   # "Thanks."
              or at_end and (long_ok or intro_next and has_list))                 # paragraph
        if ok: merged.append(g)
        else: prev["e"] = g["e"]
    if len(merged) < 2: return flat, "no break justified"
    # --- render from the pass-1 words ---
    gone = deleted - allowed_del
    def span(a, b): return " ".join(toks[i] for i in range(a, b) if i not in gone)
    text, n = "", 0
    for k, g in enumerate(merged):
        if g["item"]:
            t = span(g["cs"], g["ce"]).rstrip(",;:")
            if t[-1:] not in END: t += "."
            n += 1
            text += ("\n" if k else "") + f"{n}. " + cap(t)
            continue
        t = span(g["s"], g["e"])
        nxt_item = k + 1 < len(merged) and merged[k + 1]["item"]
        if k == 0 and greet and not nxt_item: t = t.rstrip(",.;:!") + ","
        elif nxt_item:
            if t[-1:] not in "?!": t = t.rstrip(",.;:") + ":"
        elif k + 1 < len(merged) and t[-1:] not in END: t = t.rstrip(",;:") + "."
        text += ("\n\n" if k else "") + cap(t)
    return text, "layout"

# --- spoken commands: "new line" / "new paragraph" ---
CMD_BLOCK_BEFORE = DET | {"another", "each", "every", "one", "no", "any", "some", "new"}
CMD_BLOCK_AFTER = {"of", "for", "to", "in", "on", "at", "is", "was", "are", "were", "that", "which"}
def apply_commands(flat):
    toks = flat.split()
    cw = [norm(t) for t in toks]
    out, seg, i, used = [], [], 0, False
    while i < len(toks):
        if (cw[i] == "new" and i + 1 < len(toks) and cw[i + 1] in ("line", "paragraph") and seg
                and i + 2 < len(toks) and cw[i - 1] not in CMD_BLOCK_BEFORE and cw[i + 2] not in CMD_BLOCK_AFTER):
            out.append((seg, "\n" if cw[i + 1] == "line" else "\n\n")); seg = []; i += 2; used = True
            continue
        seg.append(toks[i]); i += 1
    if not used: return flat
    out.append((seg, ""))
    text = ""
    for n, (ws, sep) in enumerate(out):
        t = " ".join(ws).strip(",;: ")
        if n == 0 and is_greeting([norm(w) for w in ws]): t = t.rstrip(",.!") + ","
        elif sep and t[-1:] not in END: t += "."
        text += cap(t) + sep
    return text

def clean(model, said):
    """Pass 1 (words + punctuation), spoken commands, then pass 2 (layout) when gated."""
    raw = ask(model, said)
    projected = project(said, raw)
    flat = fix_questions(projected)
    info = {"raw": raw, "flat": flat, "layout_raw": None, "layout_note": "not gated"}
    cmd = apply_commands(projected)                 # split first, so each line gets its own ? check
    if cmd != projected:
        info["layout_note"] = "spoken command"
        return "\n".join(fix_questions(ln) if ln else ln for ln in cmd.split("\n")), info
    if needs_layout(flat):
        info["layout_raw"] = ask(model, flat, LAYOUT_SYSTEM, LAYOUT_SHOTS, multiline=True)
        final, info["layout_note"] = layout(flat, info["layout_raw"])
        return final, info
    return flat, info


if __name__ == "__main__":
    main()
