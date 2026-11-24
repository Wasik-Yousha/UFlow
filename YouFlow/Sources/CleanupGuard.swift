// UFlow clean-up guard: the model suggests, the guard decides.
//
// A line-for-line port of tools/cleanup-eval/guard.py. The model's text is
// projected back onto the words actually spoken, so it can only
// (1) delete words, with proof, and (2) add punctuation / sentence capitals.
// English list / paragraph layout is rebuilt from the pass-1 words, never
// copied from the model.
//
// Parity with Python is byte-for-byte (see `--cleanup-replay`). To get there,
// all text is handled as a sequence of Unicode code points (`PyStr`), exactly
// like a Python `str`:
//   - Swift `String ==` and `Set<String>` use canonical equivalence; Python
//     compares code points. Bangla "য়" is U+09AF U+09BC in NFC but U+09DF is
//     canonically equal, so the two must stay different words here.
//   - Python `len`, `w[-2:]`, `w[:1]` count code points, not graphemes, so a
//     Bangla vowel sign is its own unit (len("না") == 2).
//   - `split()`, `strip()` and regex `\s` use Python's whitespace set,
//     `\d` is any Unicode decimal digit (Bangla ০-৯ too), `\w` is
//     letters/numbers/underscore (Bangla vowel signs are not `\w`).
//   - `lower()` / `upper()` use the full Unicode case mappings, with Python's
//     final-sigma rule.
// Nothing in this file depends on Foundation.

/// A Python `str`: a plain sequence of Unicode code points, compared and
/// hashed code point by code point (no canonical equivalence).
fileprivate struct PyStr: Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
    var u: [Unicode.Scalar]

    init(_ u: [Unicode.Scalar]) { self.u = u }
    init<S: Sequence>(scalars: S) where S.Element == Unicode.Scalar { u = Array(scalars) }
    init(_ s: String) { u = Array(s.unicodeScalars) }
    init(stringLiteral value: String) { self.init(value) }

    var string: String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: u)
        return String(view)
    }
    var description: String { string }
    var count: Int { u.count }
    var isEmpty: Bool { u.isEmpty }
    var last: Unicode.Scalar? { u.last }

    static func + (a: PyStr, b: PyStr) -> PyStr { PyStr(a.u + b.u) }
    static func += (a: inout PyStr, b: PyStr) { a.u += b.u }

    /// `s[:n]` for n >= 0
    func prefix(_ n: Int) -> PyStr { PyStr(scalars: u.prefix(n)) }
    /// `s[-n:]` for n > 0
    func suffix(_ n: Int) -> PyStr { PyStr(scalars: u.suffix(n)) }
    /// `s[:-1]`
    func dropLast() -> PyStr { PyStr(scalars: u.dropLast()) }

    func hasSuffix(_ x: PyStr) -> Bool { x.count <= count && u.suffix(x.count).elementsEqual(x.u) }

    /// `str.split()`: runs of Python whitespace, no empty pieces.
    func split() -> [PyStr] {
        var out: [PyStr] = [], cur: [Unicode.Scalar] = []
        for c in u {
            if PyStr.isSpace(c) {
                if !cur.isEmpty { out.append(PyStr(cur)); cur = [] }
            } else {
                cur.append(c)
            }
        }
        if !cur.isEmpty { out.append(PyStr(cur)) }
        return out
    }

    /// `str.split(sep)` for a one-character separator: keeps empty pieces.
    func split(_ sep: Unicode.Scalar) -> [PyStr] {
        var out: [PyStr] = [], cur: [Unicode.Scalar] = []
        for c in u {
            if c == sep { out.append(PyStr(cur)); cur = [] } else { cur.append(c) }
        }
        out.append(PyStr(cur))
        return out
    }

    /// `str.strip(chars)`
    func strip(_ chars: PyStr) -> PyStr { lstrip(chars).rstrip(chars) }
    /// `str.lstrip(chars)`
    func lstrip(_ chars: PyStr) -> PyStr {
        let set = Set(chars.u)
        return PyStr(scalars: u.drop(while: { set.contains($0) }))
    }
    /// `str.rstrip(chars)`
    func rstrip(_ chars: PyStr) -> PyStr {
        let set = Set(chars.u)
        var end = u.count
        while end > 0 && set.contains(u[end - 1]) { end -= 1 }
        return PyStr(scalars: u[..<end])
    }
    /// `str.strip()`: Python whitespace.
    func strip() -> PyStr {
        var s = 0, e = u.count
        while s < e && PyStr.isSpace(u[s]) { s += 1 }
        while e > s && PyStr.isSpace(u[e - 1]) { e -= 1 }
        return PyStr(scalars: u[s..<e])
    }

    /// `str.replace(c, "")`
    func removing(_ c: Unicode.Scalar) -> PyStr { PyStr(scalars: u.filter { $0 != c }) }

    /// `str.lower()`: full lowercase mapping, with Python's final-sigma rule.
    func lower() -> PyStr {
        var out: [Unicode.Scalar] = []
        for (i, c) in u.enumerated() {
            if c.value == 0x03A3 {
                out.append(Unicode.Scalar(isFinalSigma(at: i) ? 0x03C2 : 0x03C3)!)
            } else {
                out.append(contentsOf: c.properties.lowercaseMapping.unicodeScalars)
            }
        }
        return PyStr(out)
    }

    /// CPython's handle_capital_sigma:
    /// \p{cased}\p{case-ignorable}* U+03A3 !(\p{case-ignorable}* \p{cased})
    private func isFinalSigma(at i: Int) -> Bool {
        var j = i - 1
        while j >= 0 && u[j].properties.isCaseIgnorable { j -= 1 }
        var final = j >= 0 && u[j].properties.isCased
        if final && i + 1 < u.count {
            var k = i + 1
            while k < u.count && u[k].properties.isCaseIgnorable { k += 1 }
            final = k == u.count || !u[k].properties.isCased
        }
        return final
    }

    /// `str.upper()`: full uppercase mapping.
    func upper() -> PyStr {
        PyStr(u.flatMap { Array($0.properties.uppercaseMapping.unicodeScalars) })
    }

    /// Python `str.isspace()` for one code point (also regex `\s`).
    static func isSpace(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A,
             0x2028, 0x2029, 0x202F, 0x205F, 0x3000: return true
        default: return false
        }
    }

    /// Python regex `\d` (str patterns): any Unicode decimal digit.
    static func isDecimal(_ c: Unicode.Scalar) -> Bool { c.properties.numericType == .decimal }

    /// Python regex `\w` (str patterns): `isalnum()` or "_".
    /// Letters are categories L*, numbers anything with a numeric type.
    /// Combining marks (Bangla vowel signs, virama) are not `\w`.
    static func isWordChar(_ c: Unicode.Scalar) -> Bool {
        if c == "_" { return true }
        switch c.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return c.properties.numericType != nil
        }
    }

    /// Bangla block, `re.search(r"[ঀ-৿]", s)`.
    var hasBangla: Bool { u.contains { (0x0980...0x09FF).contains($0.value) } }
}

fileprivate extension Array where Element == PyStr {
    /// `sep.join(self)`
    func joined(_ sep: PyStr) -> PyStr {
        var out: [Unicode.Scalar] = []
        for (n, s) in enumerated() {
            if n > 0 { out += sep.u }
            out += s.u
        }
        return PyStr(out)
    }
}

/// Python `s[-1:] in chars` — substring semantics, so an empty `s` counts as "in".
fileprivate func tailIn(_ s: PyStr, _ chars: PyStr) -> Bool {
    guard let c = s.last else { return true }
    return chars.u.contains(c)
}

/// Python `range(a, b)`: empty when b <= a.
fileprivate func pyRange(_ a: Int, _ b: Int) -> [Int] { a < b ? Array(a..<b) : [] }

/// Python `xs[a:b]` for non-negative a, b.
fileprivate func pySlice<T>(_ xs: [T], _ a: Int, _ b: Int) -> [T] {
    let s = Swift.min(Swift.max(a, 0), xs.count), e = Swift.min(Swift.max(b, 0), xs.count)
    return s < e ? Array(xs[s..<e]) : []
}

// MARK: - Guard

/// The deterministic clean-up guard. The model only suggests; these functions
/// decide what is kept. See tools/cleanup-eval/guard.py and README.md.
enum CleanupGuard {

    // MARK: Pipeline

    /// The final text for one dictation, in guard.py's `clean()` order:
    /// pass 1 → `project` → spoken commands ("new line" / "new paragraph",
    /// split first so each line gets its own `?` check) → otherwise
    /// `fix_questions` → pass 2 `layout` when `needsLayout` gates it.
    ///
    /// `cleanRaw` is the pass-1 model output (first line, see
    /// `CleanupPrompts.pass1Output`); `layoutRaw` is the pass-2 output, needed
    /// only when `layoutRequest` returned text. Without it the flat text is used.
    static func finalize(spoken: String, cleanRaw: String, layoutRaw: String?) -> String {
        finalize(PyStr(spoken), PyStr(cleanRaw), layoutRaw.map { PyStr($0) }).string
    }

    /// The text to send to the layout prompt (pass 2), or nil when guard.py
    /// would not run pass 2 (a spoken command was used, or the gate is closed).
    static func layoutRequest(spoken: String, cleanRaw: String) -> String? {
        let projected = project(PyStr(spoken), PyStr(cleanRaw))
        if applyCommands(projected) != projected { return nil }
        let flat = fixQuestions(projected)
        return needsLayout(flat) ? flat.string : nil
    }

    /// Pass-1 result without layout: `fix_questions(project(spoken, model))`.
    /// guard.py records this as `flat`.
    static func flat(spoken: String, cleanRaw: String) -> String {
        fixQuestions(project(PyStr(spoken), PyStr(cleanRaw))).string
    }

    fileprivate static func finalize(_ said: PyStr, _ raw: PyStr, _ layoutRaw: PyStr?) -> PyStr {
        let projected = project(said, raw)
        let flat = fixQuestions(projected)
        let cmd = applyCommands(projected)          // split first, so each line gets its own ? check
        if cmd != projected {
            return cmd.split("\n").map { $0.isEmpty ? $0 : fixQuestions($0) }.joined("\n")
        }
        if needsLayout(flat), let layoutRaw {
            return layout(flat, layoutRaw).text
        }
        return flat
    }

    // MARK: Words

    fileprivate static func norm(_ w: PyStr) -> PyStr {
        w.strip(punct + "\"'").lower().removing("'").removing("\u{2019}")
    }

    /// Indices never deletable: the name after a call word ('শোনো ইউশা', 'ভাই রাকিব'),
    /// and English words with a capital mid-sentence (names, products).
    fileprivate static func protected(_ words: [PyStr]) -> Set<Int> {
        var keep = Set<Int>()
        for (i, w) in words.enumerated() {
            if callWords.contains(norm(w)) && i + 1 < words.count && !callWords.contains(norm(words[i + 1])) {
                keep.insert(i + 1)
            }
            if i > 0, let f = w.u.first, f.isASCII, f.properties.isUppercase {
                keep.insert(i)
            }
        }
        return keep
    }

    fileprivate enum Op { case keep(Int, Int), del(Int), ins(Int) }

    /// Edit-distance alignment of spoken words a and model words b (normalised).
    /// Deleting a marker word (মানে, sorry, ...) costs 0.9, so a deletion is
    /// preferred over a substitution there. Ties: keep, then delete, then insert.
    fileprivate static func align(_ a: [PyStr], _ b: [PyStr]) -> [Op] {
        let n = a.count, m = b.count
        var D = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: n + 1)
        func dc(_ i: Int) -> Double { markers.contains(a[i - 1]) ? 0.9 : 1 }
        func sub(_ i: Int, _ j: Int) -> Double { a[i - 1] == b[j - 1] ? 0 : 1 }
        if n >= 1 { for i in 1...n { D[i][0] = D[i - 1][0] + dc(i) } }
        for j in 0...m { D[0][j] = Double(j) }
        if n >= 1 && m >= 1 {
            for i in 1...n {
                for j in 1...m {
                    D[i][j] = Swift.min(D[i - 1][j] + dc(i), D[i][j - 1] + 1, D[i - 1][j - 1] + sub(i, j))
                }
            }
        }
        var ops: [Op] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && abs(D[i][j] - (D[i - 1][j - 1] + sub(i, j))) < 1e-9 {
                ops.append(.keep(i - 1, j - 1)); i -= 1; j -= 1
            } else if i > 0 && abs(D[i][j] - (D[i - 1][j] + dc(i))) < 1e-9 {
                ops.append(.del(i - 1)); i -= 1
            } else {
                ops.append(.ins(j - 1)); j -= 1
            }
        }
        return ops.reversed()
    }

    fileprivate enum Proof { case stutter, strong, weak }

    /// Why deleting words[s..<e] is justified: stutter, strong, weak or nil.
    fileprivate static func proof(_ words: [PyStr], _ s: Int, _ e: Int) -> Proof? {
        let span = pySlice(words, s, e).map(norm)
        let after = pySlice(words, e, words.count).map(norm)
        if after.isEmpty { return nil }                                   // nothing to restart into
        if Array(after.prefix(span.count)) == span && Set(span).isDisjoint(with: neverStutter) { return .stutter }
        let text = span.joined(" ")
        if span.count >= 2 {
            for m in strong {                                             // "... Rafi no wait"
                if text.hasSuffix(m) && span.count > m.split().count { return .strong }
            }
            // restart that resumes: something abandoned, then আচ্ছা/মানে + "যেটা বলছিলাম"
            for r in resume where text.hasSuffix(r) {
                let cut = span.count - r.split().count
                let head = Array(span.prefix(cut >= 0 ? cut : Swift.max(span.count + cut, 0)))
                let tail = Array(head.dropFirst())
                if (["আচ্ছা", "মানে", "okay", "anyway"] as [PyStr]).contains(where: { tail.contains($0) }) { return .strong }
            }
            // "মানে" proves a restart only when the speaker then repeats or says আচ্ছা
            if let lastWord = span.last, lastWord == "মানে" || lastWord == "আচ্ছা",
               span.contains(after[0]) || after[0] == "আচ্ছা" {
                return .weak
            }
            if span.last == "না" && span.count >= 2 {                     // "তিনটা না চারটা": parallel words
                let a = span[span.count - 2], b = after[0]
                if a.count > 2 && a != b && a.suffix(2) == b.suffix(2) { return .weak }
            }
        }
        return nil
    }

    fileprivate static func spanOK(_ words: [PyStr], _ s: Int, _ e: Int) -> Bool { proof(words, s, e) != nil }

    // MARK: Pass 1 projection

    /// Projects the model's text onto the spoken words. A word the model kept
    /// (or changed) is the spoken word, with the model's trailing punctuation
    /// and, if only casing differs, the model's casing. A run the model deleted
    /// must be proven by `proof`, otherwise it comes back.
    static func project(spoken: String, model: String) -> String {
        project(PyStr(spoken), PyStr(model)).string
    }

    fileprivate static func project(_ spoken: PyStr, _ modelOut: PyStr) -> PyStr {
        let words = spoken.split()
        let out = modelOut.split()
        let ops = align(words.map(norm), out.map(norm))
        var kept: [Int: PyStr] = [:]       // spoken index -> punctuation/casing taken from the model
        for op in ops {
            guard case let .keep(i, j) = op else { continue }
            // same word or the model changed it: the spoken word stays
            let mw = out[j]
            let trail = PyStr(scalars: mw.u.reversed().prefix(while: { punct.u.contains($0) }).reversed())
            var core = words[i].strip(punct)
            if norm(mw) == norm(core) { core = mw.strip(punct) }     // casing only
            kept[i] = core + trail
        }
        // Deleted runs must be proven; otherwise they come back.
        let prot = protected(words)
        var restored = Set<Int>()
        var i = 0
        while i < words.count {
            if kept[i] != nil { i += 1; continue }
            var e = i
            while e < words.count && kept[e] == nil { e += 1 }
            let s = i
            while e > s && e < words.count && norm(words[e - 1]) == norm(words[e]) && !neverStutter.contains(norm(words[e])) {
                e -= 1                 // a stutter at the end of the run is proven on its own
            }
            let why: Proof? = e > s ? proof(words, s, e) : .stutter
            if why == nil || (why != .strong && pyRange(s, e).contains(where: prot.contains)) {
                for k in pyRange(s, e) { kept[k] = words[k]; restored.insert(k) }
            }
            i = Swift.max(e, i + 1)
        }
        // an end mark the model put just before words we put back moves to after them
        let order = kept.keys.sorted()
        for n in 0..<Swift.max(order.count - 1, 0) {
            let k = order[n], nxt = order[n + 1]
            if restored.contains(nxt) && tailIn(kept[k]!, ".।?!") {
                // Python raises IndexError on an empty word here; skip instead.
                guard let mark = kept[k]!.last else { continue }
                kept[k] = kept[k]!.dropLast()
                var runEnd = nxt
                while restored.contains(runEnd + 1) { runEnd += 1 }
                if !tailIn(kept[runEnd]!, ".।?!") { kept[runEnd]! += PyStr([mark]) }
            }
        }
        let text = removeSpaceBeforePunct(kept.keys.sorted().map { kept[$0]! }.joined(" "))
        if text.isEmpty || text.u[0].isASCII {
            return text.prefix(1).upper() + PyStr(scalars: text.u.dropFirst())
        }
        return text
    }

    /// `re.sub(r"\s+([" + PUNCT + r"])", r"\1", text)`
    fileprivate static func removeSpaceBeforePunct(_ text: PyStr) -> PyStr {
        var out: [Unicode.Scalar] = []
        var i = 0
        let u = text.u
        while i < u.count {
            if PyStr.isSpace(u[i]) {
                var e = i
                while e < u.count && PyStr.isSpace(u[e]) { e += 1 }
                if e < u.count && punct.u.contains(u[e]) { i = e; continue }
                out += u[i..<e]; i = e
                continue
            }
            out.append(u[i]); i += 1
        }
        return PyStr(out)
    }

    /// `re.split(r"(?<=[marks])\s+", text)`: split at whitespace runs that
    /// follow one of `marks`.
    fileprivate static func splitAfter(_ text: PyStr, marks: PyStr) -> [PyStr] {
        var parts: [PyStr] = []
        var cur: [Unicode.Scalar] = []
        let u = text.u
        var i = 0
        while i < u.count {
            if PyStr.isSpace(u[i]) && i > 0 && marks.u.contains(u[i - 1]) {
                parts.append(PyStr(cur)); cur = []
                while i < u.count && PyStr.isSpace(u[i]) { i += 1 }
                continue
            }
            cur.append(u[i]); i += 1
        }
        parts.append(PyStr(cur))
        return parts
    }

    // MARK: Question marks

    /// The model may only ask when the sentence asks: a `?` without a question
    /// word (Bangla anywhere, English first word) or a tag ("right", "okay")
    /// becomes `।` (Bangla) or `.`; a `।` in a sentence with no Bangla becomes `.`.
    static func fixQuestions(_ text: String) -> String { fixQuestions(PyStr(text)).string }

    fileprivate static func fixQuestions(_ text: PyStr) -> PyStr {
        var out: [PyStr] = []
        for part in splitAfter(text, marks: ".।?!") {
            var p = part
            if p.last == "?" {
                let ws = p.split().map(norm)
                let asks = !Set(ws).isDisjoint(with: qBN)
                    || (!ws.isEmpty && qENStart.contains(ws[0]))
                    || ws.last == "right" || ws.last == "okay"
                if !asks {
                    p = p.dropLast() + (p.hasBangla ? "।" : ".")
                }
            }
            if p.last == "।" && !p.hasBangla {
                p = p.dropLast() + "."
            }
            out.append(p)
        }
        return out.joined(" ")
    }

    // MARK: English layout
    // The model proposes line structure, the guard decides.
    // Pass 2 runs only on English text the gate flags (an ordinal sequence, an email, or long dictation).
    // The model's layout is mapped onto the pass-1 words. It may only insert line breaks and list markers
    // and delete the ordinal words that became list markers. The guard then renders the layout itself
    // from the pass-1 words; any break it cannot justify is dropped, any word change rejects the layout.

    fileprivate enum Rank: Equatable, CustomStringConvertible {
        case n(Int), mid, last
        var description: String {        // Python repr inside a list
            switch self {
            case .n(let k): return String(k)
            case .mid: return "'mid'"
            case .last: return "'last'"
            }
        }
    }

    /// (rank, length) of an enumeration marker at ws[i]; rank is 1..n, mid (next/then) or last.
    fileprivate static func marker(_ ws: [PyStr], _ i: Int) -> (rank: Rank, len: Int)? {
        let w: PyStr = i < ws.count ? ws[i] : ""
        let nx: PyStr = i + 1 < ws.count ? ws[i + 1] : ""
        if w == "number", let c = card[nx] { return (.n(c), 2) }
        if let o = ordinal[w] {
            if nx == "of" && i + 2 < ws.count && ws[i + 2] == "all" { return (.n(o), 3) }
            return (.n(o), 1)
        }
        if lastW.contains(w) { return (.last, 1) }
        if w == "next" || w == "then" {
            if lastW.contains(nx) { return (.last, 2) }                  // "then finally"
            return (.mid, 1)
        }
        if w == "after" && nx == "that" { return (.mid, 2) }
        return nil
    }

    /// An item span must open with [connectors] marker: returns (rank, marker_pos, content_start).
    fileprivate static func leadMarker(_ ws: [PyStr], _ s: Int, _ e: Int) -> (rank: Rank, mpos: Int, cs: Int)? {
        var i = s
        while i < e {
            if let m = marker(ws, i) { return (m.rank, i, i + m.len) }
            if connect.contains(ws[i]) { i += 1; continue }
            return nil
        }
        return nil
    }

    fileprivate static func validSequence(_ ranks: [Rank]) -> Bool {
        let n = ranks.count
        if n < 2 || ranks[0] != .n(1) { return false }
        for k in 1..<n {
            let r = ranks[k]
            if !(r == .n(k + 1) || (r == .mid && k < n - 1) || (r == .last && k == n - 1)) { return false }
        }
        return ranks.contains(.n(2)) || (n >= 3 && ranks[n - 1] == .last)
    }

    /// `len(re.findall(r"[.?!](?=\s|$)", text))`
    fileprivate static func sentences(_ text: PyStr) -> Int {
        let u = text.u
        var n = 0
        for i in u.indices where end.u.contains(u[i]) {
            if i + 1 == u.count || PyStr.isSpace(u[i + 1]) { n += 1 }
        }
        return n
    }
    fileprivate static func isLong(_ text: PyStr) -> Bool { sentences(text) >= 4 && text.split().count >= 40 }
    fileprivate static func isGreeting(_ ws: [PyStr]) -> Bool { (2...4).contains(ws.count) && greetWords.contains(ws[0]) }
    fileprivate static func isSignoff(_ ws: [PyStr]) -> Bool {
        (1...4).contains(ws.count) && signoffWords.contains(ws[0]) && (ws[0] != "thank" || (ws.count > 1 && ws[1] == "you"))
    }

    /// Cheap gate: only these texts are sent to the layout prompt; everything else stays one line.
    static func needsLayout(_ text: String) -> Bool { needsLayout(PyStr(text)) }

    fileprivate static func needsLayout(_ text: PyStr) -> Bool {
        if text.hasBangla { return false }
        let ws = text.split().map(norm)
        let ranks = ws.indices.map { marker(ws, $0)?.rank }
        if let first = ranks.firstIndex(of: .n(1)) {
            let rest = ranks[(first + 1)...].compactMap { $0 }
            if rest.contains(.n(2)) || (rest.contains(.last) && rest.count >= 2) { return true }
        }
        let tail = splitAfter(text, marks: end).last!
        if !ws.isEmpty && greetWords.contains(ws[0]) && isSignoff(tail.split().map(norm)) && ws.count >= 20 { return true }
        return isLong(text)
    }

    /// `re.match(r"^\s*(?:\d+[.)]|[-*•])\s+", ln)`: the length of the list
    /// marker at the start of the line, or nil.
    fileprivate static func listMark(_ ln: PyStr) -> Int? {
        let u = ln.u
        var i = 0
        while i < u.count && PyStr.isSpace(u[i]) { i += 1 }
        if i < u.count && PyStr.isDecimal(u[i]) {
            while i < u.count && PyStr.isDecimal(u[i]) { i += 1 }
            guard i < u.count && (u[i] == "." || u[i] == ")") else { return nil }
            i += 1
        } else if i < u.count && (u[i] == "-" || u[i] == "*" || u[i] == "•") {
            i += 1
        } else {
            return nil
        }
        guard i < u.count && PyStr.isSpace(u[i]) else { return nil }
        while i < u.count && PyStr.isSpace(u[i]) { i += 1 }
        return i
    }

    /// `re.sub(LIST_MARK, "", ln)`
    fileprivate static func dropListMark(_ ln: PyStr) -> PyStr {
        guard let n = listMark(ln) else { return ln }
        return PyStr(scalars: ln.u.dropFirst(n))
    }

    fileprivate struct Line { var item: Bool; var toks: [PyStr] }

    fileprivate static func parseLayout(_ text: PyStr) -> [Line] {
        var lines: [Line] = []
        for ln in text.split("\n") {
            let item = listMark(ln) != nil
            let toks = dropListMark(ln).split().filter { $0.u.contains(where: PyStr.isWordChar) }
            if !toks.isEmpty { lines.append(Line(item: item, toks: toks)) }
        }
        return lines
    }

    /// guard.py `words()`: lowercased words without punctuation (grading helper).
    fileprivate static func gradeWords(_ s: PyStr) -> [PyStr] {
        let lowered = s.lower().removing("'").removing("\u{2019}")
        return PyStr(lowered.u.map { punct.u.contains($0) ? " " : $0 }).split()
    }

    /// Line structure: one (is_list_item, words) per non-empty line.
    static func structure(_ s: String) -> [(isListItem: Bool, words: [String])] {
        PyStr(s).split("\n").filter { !$0.strip().isEmpty }.map { ln in
            (listMark(ln) != nil, gradeWords(dropListMark(ln)).map(\.string))
        }
    }

    /// All words of `structure(s)`, in order.
    static func flatWords(_ s: String) -> [String] { structure(s).flatMap(\.words) }

    /// Capitalises the first letter unless the first word is mixed-case ("iPhone").
    fileprivate static func cap(_ s: PyStr) -> PyStr {
        guard let f = s.u.first, f.properties.isLowercase else { return s }
        if s.split()[0].u.dropFirst().contains(where: { $0.properties.isUppercase }) { return s }
        return PyStr([f]).upper() + PyStr(scalars: s.u.dropFirst())
    }

    fileprivate final class Seg {
        var line: Int, s: Int, e: Int, item: Bool
        var cs = 0, ce = 0
        init(line: Int, s: Int, e: Int, item: Bool) { self.line = line; self.s = s; self.e = e; self.item = item }
    }

    /// Returns (text, note). Falls back to `flat` whenever the proposed layout is not provably safe.
    static func layout(flat: String, modelLayout: String) -> (text: String, note: String) {
        let r = layout(PyStr(flat), PyStr(modelLayout))
        return (r.text.string, r.note)
    }

    fileprivate static func layout(_ flat: PyStr, _ modelOut: PyStr) -> (text: PyStr, note: String) {
        let toks = flat.split()
        let cw = toks.map(norm)
        let lines = parseLayout(modelOut)
        if lines.count < 2 { return (flat, "one line") }
        var mt: [PyStr] = [], owner: [Int] = []
        for (k, L) in lines.enumerated() { for t in L.toks { mt.append(t); owner.append(k) } }
        let lineEndMark = lines.map { tailIn($0.toks.last!, end + ":") }
        var lineOf = [Int?](repeating: nil, count: toks.count)
        var deleted = Set<Int>()
        for op in align(cw, mt.map(norm)) {
            switch op {
            case .ins: return (flat, "word changed")
            case let .keep(i, j):
                if cw[i] != norm(mt[j]) { return (flat, "word changed") }
                lineOf[i] = owner[j]
            case let .del(i): deleted.insert(i)
            }
        }
        var nxt: Int? = nil                                   // a deleted word belongs to the next line
        for i in stride(from: toks.count - 1, through: 0, by: -1) {
            if lineOf[i] == nil { lineOf[i] = nxt } else { nxt = lineOf[i] }
        }
        var last: Int? = nil
        for i in 0..<toks.count {
            if lineOf[i] == nil { lineOf[i] = last }
            last = lineOf[i]
        }
        var segs: [Seg] = []
        for (i, k) in lineOf.enumerated() {
            guard let k else { return (flat, "no line") }     // unreachable (Python would raise)
            if let g = segs.last, g.line == k { g.e = i + 1 }
            else { segs.append(Seg(line: k, s: i, e: i + 1, item: lines[k].item)) }
        }
        if segs.isEmpty { return (flat, "no words") }         // unreachable (Python would raise)
        if !segs.contains(where: { $0.item }) {               // "First, ...\nSecond, ..." without numbers
            let cand = segs.filter { leadMarker(cw, $0.s, $0.e) != nil }
            if cand.count >= 2 { for g in cand { g.item = true } }
        }
        // --- the list ---
        var items = segs.indices.filter { segs[$0].item }
        if let first = items.first, first > 0 {               // "Preheat the oven,\n1. Mix ..." : item 1 left unnumbered
            let prev = segs[first - 1]
            if let lm = leadMarker(cw, prev.s, prev.e), lm.rank == .n(1), lm.mpos == prev.s {
                prev.item = true; items.insert(first - 1, at: 0)
            }
        }
        var hasList = false
        if !items.isEmpty {
            if items != Array(items[0]...items[items.count - 1]) { return (flat, "list not contiguous") }
            var ranks: [Rank] = []
            for (n, k) in items.enumerated() {
                let g = segs[k]
                guard let lm = leadMarker(cw, g.s, g.e) else { return (flat, "item without ordinal") }
                let (rank, mpos, cs) = lm
                var ce = g.e
                if n + 1 < items.count {
                    while ce > cs && connect.contains(cw[ce - 1]) { ce -= 1 }
                }
                if ce <= cs { return (flat, "empty item") }
                if notItemStart.contains(cw[cs]) { return (flat, "ordinal is part of the sentence") }
                var p = mpos - 1
                while p >= 0 && connect.contains(cw[p]) { p -= 1 }
                if p >= 0 && det.contains(cw[p]) { return (flat, "ordinal after a determiner") }
                g.cs = cs; g.ce = ce
                ranks.append(rank)
            }
            if !validSequence(ranks) {
                return (flat, "bad sequence [" + ranks.map(\.description).joined(separator: ", ") + "]")
            }
            if items[0] > 0 {                                 // "three things" must mean three items
                let introSeg = segs[items[0] - 1]
                let intro = pySlice(cw, introSeg.s, introSeg.e)
                let counts = intro.compactMap { card[$0] }.filter { $0 >= 2 }
                if let c = counts.last, c != items.count { return (flat, "count mismatch") }
            }
            hasList = true
        }
        var allowedDel = Set<Int>()
        for k in items {
            let g = segs[k]
            allowedDel.formUnion(pyRange(g.s, g.cs))
            allowedDel.formUnion(pyRange(g.ce, g.e))
        }
        let gone = deleted.subtracting(allowedDel)
        var rest = gone.sorted()                              // any other deletion needs pass-1 proof
        let prot = protected(toks)
        while let s = rest.first {
            var e = s
            while gone.contains(e + 1) { e += 1 }
            let why = proof(toks, s, e + 1)
            if why == nil || (why != .strong && pyRange(s, e + 1).contains(where: prot.contains)) {
                return (flat, "unproven deletion")
            }
            rest = rest.filter { $0 > e }
        }
        // --- the other breaks: keep only those the guard can justify ---
        let longOK = isLong(flat)
        let lastSeg = segs[segs.count - 1]
        let sign = isSignoff(pySlice(cw, lastSeg.s, lastSeg.e)) && !lastSeg.item
        let g0 = segs[0]
        if (hasList || longOK || sign) && !g0.item && !isGreeting(pySlice(cw, g0.s, g0.e)) {
            for k in pyRange(g0.s + 1, Swift.min(g0.s + 4, g0.e - 1)) {   // "Hello team, quick update ..."
                if toks[k].last == "," && isGreeting(pySlice(cw, g0.s, k + 1)) {
                    segs.insert(Seg(line: g0.line, s: g0.s, e: k + 1, item: false), at: 0)
                    g0.s = k + 1
                    break
                }
            }
        }
        let greet = isGreeting(pySlice(cw, segs[0].s, segs[0].e)) && !segs[0].item
        let email = greet && sign
        var merged = [segs[0]]
        for k in 1..<segs.count {
            let g = segs[k], prev = merged[merged.count - 1]
            let atEnd = tailIn(toks[prev.e - 1], end)
            let introNext = k + 1 < segs.count && segs[k + 1].item
            let ok = g.item
                || (prev.item && (atEnd || lineEndMark[prev.line]))           // closing after a list
                || (k == 1 && greet && (email || hasList || longOK))          // "Hi Rafi,"
                || (k == segs.count - 1 && sign && (email || hasList || longOK)) // "Thanks."
                || (atEnd && (longOK || (introNext && hasList)))              // paragraph
            if ok { merged.append(g) } else { prev.e = g.e }
        }
        if merged.count < 2 { return (flat, "no break justified") }
        // --- render from the pass-1 words ---
        func span(_ a: Int, _ b: Int) -> PyStr { pyRange(a, b).filter { !gone.contains($0) }.map { toks[$0] }.joined(" ") }
        var text: PyStr = ""
        var n = 0
        for (k, g) in merged.enumerated() {
            if g.item {
                var t = span(g.cs, g.ce).rstrip(",;:")
                if !tailIn(t, end) { t += "." }
                n += 1
                text += (k > 0 ? "\n" : "") + PyStr("\(n). ") + cap(t)
                continue
            }
            var t = span(g.s, g.e)
            let nxtItem = k + 1 < merged.count && merged[k + 1].item
            if k == 0 && greet && !nxtItem {
                t = t.rstrip(",.;:!") + ","
            } else if nxtItem {
                if !tailIn(t, "?!") { t = t.rstrip(",.;:") + ":" }
            } else if k + 1 < merged.count && !tailIn(t, end) {
                t = t.rstrip(",;:") + "."
            }
            text += (k > 0 ? "\n\n" : "") + cap(t)
        }
        return (text, "layout")
    }

    // MARK: Spoken commands: "new line" / "new paragraph"

    /// Splits at a spoken "new line" / "new paragraph" unless it is part of
    /// the sentence ("a new line of code", "the new paragraph is"). Returns
    /// the input unchanged when no command was used.
    static func applyCommands(_ flat: String) -> String { applyCommands(PyStr(flat)).string }

    fileprivate static func applyCommands(_ flat: PyStr) -> PyStr {
        let toks = flat.split()
        let cw = toks.map(norm)
        var out: [(ws: [PyStr], sep: PyStr)] = []
        var seg: [PyStr] = []
        var i = 0
        var used = false
        while i < toks.count {
            if cw[i] == "new" && i + 1 < toks.count && (cw[i + 1] == "line" || cw[i + 1] == "paragraph") && !seg.isEmpty
                && i + 2 < toks.count && !cmdBlockBefore.contains(cw[i - 1]) && !cmdBlockAfter.contains(cw[i + 2]) {
                out.append((seg, cw[i + 1] == "line" ? "\n" : "\n\n")); seg = []; i += 2; used = true
                continue
            }
            seg.append(toks[i]); i += 1
        }
        if !used { return flat }
        out.append((seg, ""))
        var text: PyStr = ""
        for (n, (ws, sep)) in out.enumerated() {
            var t = ws.joined(" ").strip(",;: ")
            if n == 0 && isGreeting(ws.map(norm)) { t = t.rstrip(",.!") + "," }
            else if !sep.isEmpty && !tailIn(t, end) { t += "." }
            text += cap(t) + sep
        }
        return text
    }
}

// MARK: - Model output

extension CleanupPrompts {
    /// guard.py `ask()` for pass 1: `out.strip().splitlines()[0]`
    /// (empty when the model returned nothing).
    static func pass1Output(_ raw: String) -> String {
        let s = PyStr(raw).strip()
        let breaks: Set<UInt32> = [0x0A, 0x0B, 0x0C, 0x0D, 0x1C, 0x1D, 0x1E, 0x85, 0x2028, 0x2029]
        return PyStr(scalars: s.u.prefix(while: { !breaks.contains($0.value) })).string
    }

    /// guard.py `ask(..., multiline=True)` for pass 2: `out.strip()`.
    static func layoutOutput(_ raw: String) -> String { PyStr(raw).strip().string }
}

// MARK: - Constants (generated from tools/cleanup-eval/guard.py; keep in sync)

extension CleanupGuard {
    /// PUNCT
    fileprivate static let punct: PyStr = ",.।?!;:"
    /// END
    fileprivate static let end: PyStr = ".?!"
    /// MARKERS: words whose deletion costs 0.9 in `align`.
    fileprivate static let markers: Set<PyStr> = ["mean", "sorry", "wait", "আচ্ছা", "না", "নাহ", "মানে", "সরি"]
    /// CALL_WORDS: the word after one of these is a name and never deleted.
    fileprivate static let callWords: Set<PyStr> = ["hello", "hey", "hi", "listen", "আপা", "আপু", "দোস্ত", "ভাই", "শুনো", "শোনো"]
    /// STRONG: a span ending in one of these is a proven self-correction.
    fileprivate static let strong: Set<PyStr> = ["i mean", "no sorry", "no wait", "sorry", "wait", "না না", "না সরি", "সরি"]
    /// RESUME: "যেটা বলছিলাম" after an abandoned phrase.
    fileprivate static let resume: [PyStr] = ["যেটা বলছিলাম", "যেটা বলতেছিলাম", "যেটা বলতেছি", "যেটা বলতে চাচ্ছিলাম", "যা বলছিলাম", "what i was saying", "as i was saying"]
    /// NEVER_STUTTER: "না না" is emphasis or a correction, never a slip.
    fileprivate static let neverStutter: Set<PyStr> = ["no", "very", "অনেক", "খুব", "না"]
    /// Q_BN: Bangla question words (anywhere in the sentence).
    fileprivate static let qBN: Set<PyStr> = ["কই", "কখন", "কত", "কয়টা", "কাকে", "কার", "কি", "কিভাবে", "কিসের", "কী", "কীভাবে", "কে", "কেন", "কেনো", "কেমন", "কোথায়", "কোন", "কোনটা", "কোনো", "কোনোদিন", "ক্যান", "জীবনে", "তাই", "নাকি"]
    /// Q_EN_START: English question openers (first word).
    fileprivate static let qENStart: Set<PyStr> = ["am", "are", "aren't", "can", "can't", "could", "couldn't", "did", "didn't", "do", "does", "doesn't", "don't", "has", "have", "how", "is", "isn't", "may", "shall", "should", "shouldn't", "was", "were", "what", "when", "where", "which", "who", "why", "will", "won't", "would", "wouldn't"]
    /// ORDINAL
    fileprivate static let ordinal: [PyStr: Int] = ["first": 1, "firstly": 1, "second": 2, "secondly": 2, "third": 3, "thirdly": 3, "fourth": 4, "fourthly": 4, "fifth": 5, "fifthly": 5, "sixth": 6, "sixthly": 6, "seventh": 7]
    /// CARD
    fileprivate static let card: [PyStr: Int] = ["1": 1, "one": 1, "2": 2, "two": 2, "3": 3, "three": 3, "4": 4, "four": 4, "5": 5, "five": 5, "6": 6, "six": 6, "7": 7, "seven": 7, "8": 8, "eight": 8, "9": 9, "nine": 9, "10": 10, "ten": 10]
    /// LAST_W
    fileprivate static let lastW: Set<PyStr> = ["finally", "lastly"]
    /// CONNECT
    fileprivate static let connect: Set<PyStr> = ["also", "and"]
    /// DET
    fileprivate static let det: Set<PyStr> = ["a", "an", "her", "his", "its", "my", "our", "that", "the", "their", "these", "this", "those", "your"]
    /// NOT_ITEM_START: after a list marker the item must read on its own: an ordinal followed by these
    /// is part of the sentence ("number one on my list is", "first place went", "the second time").
    fileprivate static let notItemStart: Set<PyStr> = ["about", "and", "are", "at", "but", "by", "for", "from", "had", "has", "in", "is", "of", "on", "one", "ones", "or", "person", "place", "priority", "than", "thing", "time", "times", "to", "was", "were", "will", "with", "would"]
    /// GREET
    fileprivate static let greetWords: Set<PyStr> = ["dear", "hello", "hey", "hi"]
    /// SIGNOFF
    fileprivate static let signoffWords: Set<PyStr> = ["best", "cheers", "kind", "many", "regards", "sincerely", "thank", "thanks", "warm", "warmest"]
    /// CMD_BLOCK_BEFORE: "a new line", "the new paragraph" are not commands.
    fileprivate static let cmdBlockBefore: Set<PyStr> = ["a", "an", "another", "any", "each", "every", "her", "his", "its", "my", "new", "no", "one", "our", "some", "that", "the", "their", "these", "this", "those", "your"]
    /// CMD_BLOCK_AFTER: "new line of code", "new paragraph is" are not commands.
    fileprivate static let cmdBlockAfter: Set<PyStr> = ["are", "at", "for", "in", "is", "of", "on", "that", "to", "was", "were", "which"]
}

// MARK: - Prompts (generated from tools/cleanup-eval/guard.py; keep in sync)

/// The exact prompts guard.py sends (Ollama /api/chat, temperature 0, no thinking).
/// Messages: system, then each shot as a user/assistant pair, then the user text.
/// Pass 1 takes the raw transcript and its reply goes through `pass1Output`;
/// pass 2 takes `CleanupGuard.layoutRequest(...)` and its reply goes through `layoutOutput`.
enum CleanupPrompts {
    /// SYSTEM: pass 1, words + punctuation.
    static let system = """
        You add punctuation to dictated speech and remove stumbles. Output only the result.
        Remove ONLY: a word said twice by accident; a phrase the speaker abandoned and restarted; a value the speaker corrected ("five, no sorry, six" -> "six").
        Keep everything else exactly: same words, same order, same script. English words stay in English letters. Never translate. Never remove names.
        Add commas, । or . at sentence ends, and ? for questions, including rhetorical ones.
        """

    /// SHOTS: pass-1 examples, (user, assistant).
    static let shots: [(user: String, assistant: String)] = [
        ("আমি আমি বলতে চাচ্ছিলাম যে মানে আমি কালকে অফিসে যাবো না",
         "আমি বলতে চাচ্ছিলাম যে, আমি কালকে অফিসে যাবো না।"),
        ("শোনো রাফি তোমাকে একটা জিনিস বলার ছিল মানে আসলে আচ্ছা যেটা বলছিলাম আজকে মিটিং টা পাঁচটায় হবে",
         "শোনো রাফি, আজকে মিটিং টা পাঁচটায় হবে।"),
        ("এভাবে কাজ করলে তুই টাকা পাবি কোনোদিন আগে প্ল্যান টা ঠিক কর",
         "এভাবে কাজ করলে তুই টাকা পাবি কোনোদিন? আগে প্ল্যান টা ঠিক কর।"),
        ("My name is Yusha মানে আমার নাম ইউশা",
         "My name is Yusha, মানে আমার নাম ইউশা।"),
        ("সে সে আজকে আসবে না",
         "সে আজকে আসবে না।"),
        ("call him at three no wait at four",
         "Call him at four."),
        ("ছোট ছোট কাজ গুলো আগে শেষ করো",
         "ছোট ছোট কাজ গুলো আগে শেষ করো।"),
        ("presentation টা কালকে দিবো নাকি আজকেই দিবো",
         "presentation টা কালকে দিবো নাকি আজকেই দিবো?"),
    ]

    /// LAYOUT_SYSTEM: pass 2, English line structure.
    static let layoutSystem = """
        You lay out dictated English text. Output only the result.
        Never change, add, remove or reorder words, except the ordinal words that become list numbers. You may only insert line breaks and list numbers.
        - If the speaker enumerates items with first/second/third, firstly/secondly, number one/number two, next or finally: end the sentence before the items with a colon, put each item on its own line as "1.", "2.", ... and drop the ordinal word.
        - An ordinal that is part of the sentence ("first of all", "the second time", "came first", "my number one priority") is not a list: leave the text as it is.
        - An email: greeting line, blank line, body, blank line, sign-off.
        - Long text that changes topic: put a blank line between the topics.
        - Otherwise return the text unchanged on one line.
        """

    /// LAYOUT_SHOTS: pass-2 examples, (user, assistant).
    static let layoutShots: [(user: String, assistant: String)] = [
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

    /// The chat messages for one request, as guard.py's `ask()` builds them.
    static func messages(for text: String, layout: Bool = false) -> [(role: String, content: String)] {
        var msgs = [(role: "system", content: layout ? layoutSystem : system)]
        for (a, b) in layout ? layoutShots : shots {
            msgs.append((role: "user", content: a))
            msgs.append((role: "assistant", content: b))
        }
        msgs.append((role: "user", content: text))
        return msgs
    }
}
