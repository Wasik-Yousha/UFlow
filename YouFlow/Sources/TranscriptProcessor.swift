import Foundation

/// One correction that actually fired, recorded so the history can show what
/// the dictionary changed. `heard` is the text as the engine produced it —
/// not the stored pattern — so "claude-code -> Claude Code" reads truthfully.
struct AppliedCorrection: Codable, Hashable, Identifiable {
    var heard: String
    var written: String
    var count: Int

    var id: String { "\(heard)\u{1F}\(written)" }
}

/// The post-transcription correction pass.
///
/// This is the guaranteed half of the dictionary. Biasing the engine before it
/// listens is only a nudge; this pass is what actually makes the text right.
///
/// Rules, in order of importance:
/// - **Whole word only.** A rule for "Claude Code" can never touch "Cloudflare"
///   or the ordinary word "cloud": both halves of the phrase must be present.
/// - **Case-insensitive**, and the replacement is written in its canonical form.
/// - **Longest pattern wins.** Rules are ordered longest-first inside one
///   alternation, and ICU alternation is leftmost-first, so the longest rule
///   that can match at a position is the one that does.
/// - **Exactly one pass.** Text produced by a replacement is never re-examined,
///   so rules cannot cascade into each other and no rule can undo another.
/// - **Elastic separators.** The words of a phrase may be joined by any run of
///   whitespace or hyphens, or by nothing at all — "cloud code" also catches
///   "cloudcode", "Cloud-Code" and "CloudCode", which is exactly how these
///   models glue words together.
enum CorrectionEngine {

    /// A compiled dictionary. Building costs one regex compile; applying it is
    /// a single scan, so it is built once per dictionary change and reused.
    struct Ruleset {
        fileprivate let regex: NSRegularExpression?
        fileprivate let replacements: [String]

        var isEmpty: Bool { regex == nil }
    }

    // MARK: - Building

    /// Compiles enabled entries into one alternation, longest pattern first.
    static func build(from entries: [DictionaryEntry]) -> Ruleset {
        let usable = entries
            .filter(\.isEnabled)
            .compactMap { entry -> (pattern: String, replacement: String)? in
                guard let p = pattern(for: entry.match) else { return nil }
                return (p, entry.replacement)
            }
            // Longest source phrase first. Leftmost-first alternation then
            // yields longest-match semantics.
            .sorted { $0.pattern.count > $1.pattern.count }

        guard !usable.isEmpty else { return Ruleset(regex: nil, replacements: []) }

        // One capture group per rule, so the winning rule is identified by
        // which group matched rather than by re-testing the matched text.
        let combined = usable.map { "(\($0.pattern))" }.joined(separator: "|")
        let regex = try? NSRegularExpression(pattern: combined, options: [.caseInsensitive])
        if regex == nil {
            Log.app.error("Dictionary produced an invalid pattern; correction pass disabled")
        }
        return Ruleset(regex: regex, replacements: usable.map(\.replacement))
    }

    /// Turns a stored phrase into a whole-word, glue-tolerant pattern.
    ///
    /// Boundaries are lookarounds rather than `\b` because a phrase may legally
    /// end in punctuation ("GO!"), where `\b` would demand a word character
    /// immediately after and the entry would silently never match.
    static func pattern(for phrase: String) -> String? {
        let parts = phrase.split { $0.isWhitespace || $0 == "-" || $0 == "\u{2010}" }
        guard !parts.isEmpty else { return nil }

        let body = parts
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: "[\\s\\-]*")

        let word = CharacterSet.alphanumerics
        let lead = phrase.unicodeScalars.first.map(word.contains) == true ? "(?<![0-9A-Za-z_])" : ""
        let tail = phrase.unicodeScalars.last.map(word.contains) == true ? "(?![0-9A-Za-z_])" : ""
        return lead + body + tail
    }

    // MARK: - Applying

    /// Rewrites `text` and reports every correction that fired.
    static func apply(_ ruleset: Ruleset, to text: String) -> (text: String, corrections: [AppliedCorrection]) {
        guard let regex = ruleset.regex, !text.isEmpty else { return (text, []) }

        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return (text, []) }

        var out = ""
        var cursor = 0
        var tally: [String: AppliedCorrection] = [:]
        var order: [String] = []

        for match in matches {
            // Which alternation branch won?
            guard let ruleIndex = (1...ruleset.replacements.count)
                .first(where: { match.range(at: $0).location != NSNotFound }) else { continue }

            let heard = ns.substring(with: match.range)
            let written = ruleset.replacements[ruleIndex - 1]

            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            out += written
            cursor = match.range.location + match.range.length

            // Only report a real change; a rule that matched text already in
            // its canonical form is not news.
            guard heard != written else { continue }
            let key = "\(heard)\u{1F}\(written)"
            if tally[key] == nil {
                tally[key] = AppliedCorrection(heard: heard, written: written, count: 1)
                order.append(key)
            } else {
                tally[key]?.count += 1
            }
        }
        out += ns.substring(from: cursor)

        return (out, order.compactMap { tally[$0] })
    }

    // MARK: - Self check

    /// One runnable check covering every guarantee above. Runs on debug
    /// launches; a broken regex fails here loudly instead of quietly
    /// corrupting somebody's transcript.
    static func selfCheck() {
        func rules(_ pairs: [(String, String)]) -> Ruleset {
            build(from: pairs.map {
                DictionaryEntry(kind: .fix, match: $0.0, replacement: $0.1)
            })
        }

        let claude = rules([("cloud code", "Claude Code"), ("clawed code", "Claude Code")])

        // Glue tolerance: spaced, hyphenated, and fully glued all match.
        for input in ["cloud code", "Cloud-Code", "CloudCode", "cloud  code"] {
            assert(apply(claude, to: input).text == "Claude Code", "glue failed for \(input)")
        }

        // Never corrupt a real word that merely starts the same way.
        for safe in ["Cloudflare", "the cloud", "cloudy", "code cloud"] {
            assert(apply(claude, to: safe).text == safe, "corrupted \(safe)")
        }

        // Whole-word: no match inside a longer word.
        assert(apply(claude, to: "mycloudcodex").text == "mycloudcodex")

        // Longest match wins over a shorter overlapping rule.
        let overlap = rules([("cloud", "CLOUD"), ("cloud code", "Claude Code")])
        assert(apply(overlap, to: "cloud code").text == "Claude Code")

        // One pass only: the output of a rule is never re-matched by another.
        let cascade = rules([("a b", "b c"), ("b c", "WRONG")])
        assert(apply(cascade, to: "a b").text == "b c", "rules cascaded")

        // Terms normalise their own casing and report what was heard.
        let term = build(from: [DictionaryEntry(kind: .term, match: "Claude Code", replacement: "Claude Code")])
        let result = apply(term, to: "saying claude-code twice: claude-code")
        assert(result.text == "saying Claude Code twice: Claude Code")
        assert(result.corrections == [AppliedCorrection(heard: "claude-code", written: "Claude Code", count: 2)])

        // Punctuation-terminated phrases still match.
        let bang = rules([("youtube go!", "YouTube GO!")])
        assert(apply(bang, to: "our youtube go! is working").text == "our YouTube GO! is working")

        // Trailing possessives survive.
        let flow = rules([("wispr flow", "Wispr Flow")])
        assert(apply(flow, to: "wispr flow's speed").text == "Wispr Flow's speed")

        // The dictionary file is the format of record, so a round trip
        // through it has to be lossless — including disabled entries.
        let written = DictionaryStore.serialize([
            DictionaryEntry(kind: .term, match: "Anthropic"),
            DictionaryEntry(kind: .fix, match: "cloud code", replacement: "Claude Code"),
            DictionaryEntry(kind: .term, match: "Supabase", isEnabled: false),
        ])
        let readBack = DictionaryStore.parse(written)
        assert(readBack.count == 3, "dictionary round trip lost entries")
        assert(readBack[0].kind == .term && readBack[0].match == "Anthropic")
        assert(readBack[1].kind == .fix && readBack[1].match == "cloud code"
               && readBack[1].replacement == "Claude Code")
        assert(readBack[2].match == "Supabase" && !readBack[2].isEnabled, "disabled flag lost")
        // "->" is accepted as well as "=>", because people type it.
        assert(DictionaryStore.parse("vercell -> Vercel").first?.replacement == "Vercel")

        // Filler removal: fillers go, punctuation and capitals are repaired.
        for (input, expected) in [
            ("So, um, I think", "So I think"),
            ("The build is, uh, ready", "The build is ready"),
            ("Um, hello", "Hello"),
            ("I think, um.", "I think."),
            ("Uhhh, ummm, yes", "Yes"),
            ("Yes. Hmm. Okay", "Yes. Okay"),
            ("Wait... uh, what?", "Wait... what?"),
            ("Ah, I see", "I see"),
            ("Aa, I mean it, aah", "I mean it"),
            ("Um.", ""),
        ] {
            let got = FillerFilter.apply(to: input)
            assert(got == expected, "filler: \(input) -> \(got)")
        }
        // Real words that look like fillers survive untouched.
        for safe in ["uh-huh that's right", "The ER doctor, err on it", "5 mm and AA batteries",
                     "Ahmed said aha", "an umbrella, a hum", "Hello there. Okay"] {
            assert(FillerFilter.apply(to: safe) == safe, "filler corrupted: \(safe)")
        }

        // Whisper output filter: invented text goes, real speech stays.
        let prompt = "আমি কালকে office এ যাবো, then I will send the report. Supabase, Vercel"
        for (input, expected) in [
            ("[BLANK_AUDIO]", ""),
            ("hello (music) world ♪", "hello world"),
            ("আমি\u{FFFD} যাবো", "আমি যাবো"),
            ("ami jabo ami jabo ami jabo ami jabo", "ami jabo"),
            ("the the the end", "the end"),
            ("very very good, thank you thank you", "very very good, thank you thank you"),
            ("then I will send the report.", ""),
            ("Supabase, Vercel", "Supabase, Vercel"),
            ("আমি", "আমি"),
            ("I will send the report tomorrow", "I will send the report tomorrow"),
        ] {
            let got = WhisperOutputFilter.apply(to: input, prompt: prompt)
            assert(got == expected, "whisper filter: \(input) -> \(got)")
        }

        // Mixed sentences: English words take Apple's spelling, Bangla stays put.
        func words(_ pairs: [(String, Double)]) -> [AppleWord] { pairs.map { AppleWord(text: $0.0, confidence: $0.1) } }
        let mixed = EnglishSpelling.apply(
            to: "may name is yusha মানে আমার নাম ইউশা",
            apple: words([("My", 0.95), ("name", 0.97), ("is", 0.96), ("Yusha,", 0.7),
                          ("Mane", 0.3), ("amar", 0.2), ("nam", 0.3), ("Usha.", 0.4)]))
        assert(mixed == "My name is Yusha মানে আমার নাম ইউশা", "english spelling: \(mixed)")
        assert(EnglishSpelling.apply(to: "আমি ভালো আছি", apple: words([("Ami", 0.9), ("bhalo", 0.9), ("achi", 0.9)]))
               == "আমি ভালো আছি", "bangla word replaced")
        assert(EnglishSpelling.apply(to: "send the reprt", apple: words([("Send", 0.3), ("the", 0.3), ("report", 0.3)]))
               == "send the reprt", "unsure apple word used")
        assert(EnglishSpelling.apply(to: "please send the reprt.", apple: words([("Please", 0.9), ("send", 0.9), ("the", 0.9), ("report", 0.9)]))
               == "Please send the report.", "sentence punctuation lost")

        // Silence gate: a short phrase in a long hold is speech; faint hiss is not.
        var longHold = [Float](repeating: 0, count: 16_000 * 10)
        for i in 0..<1600 { longHold[i] = 0.05 }
        assert(SpeechEngine.loudestWindowRMS(longHold) > 0.0018, "short phrase in long hold read as silence")
        assert(SpeechEngine.loudestWindowRMS([Float](repeating: 0.0005, count: 16_000)) < 0.0018, "hiss read as speech")

        // Banglish: Bangla script romanized the way people type it; English untouched.
        for (input, expected) in [
            ("আমি ভালো আছি, তুমি কেমন আছো?", "ami bhalo achi, tumi kemon acho?"),
            ("আমরা কালকে অফিসে যাবো", "amra kalke ofishe jabo"),
            ("ধন্যবাদ ভাই", "dhonnobad bhai"),
            ("This project টা আজকে শেষ করতে হবে, okay?", "This project ta ajke shesh korte hobe, okay?"),
            ("আমি একটু পরে কল করবো।", "ami ektu pore kol korbo."),
            ("কেন হবে না", "keno hobe na"),
            ("১২৩ টাকা", "123 taka"),
            ("meeting-এ যাচ্ছি", "meeting-e jachchi"),
            ("সময় নেই, আমি আসবো", "shomoy nei, ami ashbo"),
            ("স্কুলের রাস্তা", "skuler rasta"),
            ("পরীক্ষা", "porikha"),
            ("Please send the report.", "Please send the report."),
        ] {
            let got = BanglaRomanizer.apply(to: input)
            assert(got == expected, "banglish: \(input) -> \(got)")
        }

        Log.app.info("CorrectionEngine self-check passed")
        if CommandLine.arguments.contains("--self-check") {
            print("CorrectionEngine self-check: PASS")
        }
    }
}

// MARK: - Filler words

/// Strips hesitation sounds ("um", "uh", "ah", "aa", "hmm") before the
/// dictionary pass. Written as patterns rather than a word list, so stretched
/// forms ("ummm", "uhhh", "aaah") need no entries of their own.
///
/// Approach follows VoiceInk / Handy / FluidVoice, minus their known misses:
/// stray commas, lost capitals, "uh-huh" becoming "-huh", and "mm" eating
/// millimetres. Deliberately left alone because they are real words:
/// "er"/"err", "mm", "uh-huh", capital "AA" (batteries), and "ah" inside a
/// word ("Ahmed", "aha").
enum FillerFilter {
    private static let filler = try! NSRegularExpression(
        // The comma on either side goes too: the engine writes fillers as
        // ", uh," so "the build is, uh, ready" must not keep one of them.
        pattern: #"(?:[,;]\s*)?(?<![\w'-])(?:u+h+|u+h*m+|e+r+m+|h+m+|m{3,}|a+h+|(?-i:[Aa]a+h*))(?![\w'-])[,;]?\s*"#,
        options: [.caseInsensitive]
    )

    /// Punctuation orphaned by a removal, repaired in this order.
    private static let tidy: [(NSRegularExpression, String)] = [
        (#"([.!?])\s+[.!?](?=\s|$)"#, "$1"), // "Yes. . Okay" -> "Yes. Okay"
        (#"\s+([,.;:!?])"#, "$1"),           // "think ."     -> "think."
        (#"[,;]+([.!?])"#, "$1"),            // "think,."     -> "think."
        (#"^[\s,;.!?]+"#, ""),               // ". Hello"     -> "Hello"
        (#"[\s,;]+$"#, ""),                  // "mean it, "   -> "mean it"
        (#" {2,}"#, " "),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    static func apply(to text: String) -> String {
        let ns = text as NSString
        let matches = filler.matches(in: text, range: NSRange(location: 0, length: ns.length))
        // No filler, no rewrite: tidying is never applied to clean text.
        guard !matches.isEmpty else { return text }

        var out = ""
        var cursor = 0
        var capitalizeNext = false
        for match in matches {
            append(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)),
                   to: &out, capitalizing: &capitalizeNext)
            // A filler that opened a sentence hands its capital to the next
            // word. An ellipsis ("Wait... um, what?") does not end a sentence.
            let before = out.trimmingCharacters(in: .whitespaces)
            if before.isEmpty || (".!?".contains(before.last!) && !before.hasSuffix("..")) {
                capitalizeNext = true
            }
            // A space stands in for the removed filler; the tidy pass collapses doubles.
            out += " "
            cursor = NSMaxRange(match.range)
        }
        append(ns.substring(from: cursor), to: &out, capitalizing: &capitalizeNext)

        return tidy.reduce(out) { text, rule in
            rule.0.stringByReplacingMatches(
                in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: rule.1)
        }.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func append(_ segment: String, to out: inout String, capitalizing flag: inout Bool) {
        guard flag, let i = segment.firstIndex(where: \.isLetter) else { out += segment; return }
        out += String(segment[..<i]) + segment[i].uppercased() + String(segment[segment.index(after: i)...])
        flag = false
    }
}

// MARK: - Whisper output filter

/// Drops what Whisper writes that nobody said. Three known failure modes,
/// each seen in the open-source dictation apps' issue trackers:
/// - non-speech annotations: "[BLANK_AUDIO]", "(music)", "♪" (VoiceInk strips these);
/// - repetition loops on short clips, which whisper.cpp's own entropy check
///   skips below 32 tokens ("ami jabo ami jabo ami jabo…");
/// - prompt echo: on near-silence Whisper can return its initial prompt,
///   dictionary terms included (OpenWhispr #1454).
enum WhisperOutputFilter {
    static func apply(to text: String, prompt: String) -> String {
        let stripped = text
            .replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)|[♪♫\x{FFFD}]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+([,.!?।])"#, with: "$1", options: .regularExpression)
        let out = collapseRepeats(stripped.split(whereSeparator: \.isWhitespace).map(String.init))
            .joined(separator: " ")
        // Three words or more found verbatim in the prompt is an echo; a lone
        // "ভাই" that happens to be in it is just the user talking.
        let core = out.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        if core.split(separator: " ").count >= 3, prompt.contains(core) { return "" }
        return out
    }

    /// Any run of 1–8 words repeated three or more times in a row keeps one copy.
    /// ponytail: a deliberate "no no no" also becomes "no"; raise `minRepeats`
    /// if real speech gets trimmed.
    static func collapseRepeats(_ words: [String], minRepeats: Int = 3) -> [String] {
        let key = words.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        var words = words, keys = key
        for n in 1...8 {
            var i = 0
            while i + n * minRepeats <= keys.count {
                var reps = 1
                while i + (reps + 1) * n <= keys.count,
                      keys[(i + reps * n)..<(i + (reps + 1) * n)] == keys[i..<(i + n)] {
                    reps += 1
                }
                if reps >= minRepeats {
                    words.removeSubrange((i + n)..<(i + reps * n))
                    keys.removeSubrange((i + n)..<(i + reps * n))
                }
                i += 1
            }
        }
        return words
    }
}

// MARK: - English spelling in mixed sentences

/// The code-switch model writes English words in English letters, but by ear
/// ("fridy afternoune"); Apple's English model hears the same recording and
/// spells them properly. Each English (Latin-letter) word the code-switch
/// model wrote takes Apple's spelling when the two line up in order, sound
/// alike, and Apple was confident. Bangla-script words are never touched.
///
/// Measured on 150 Bengali-English code-mixed clips (MUCS 2021) and the
/// English set: code-mixed WER 35.0% → 34.6%, English stretches 30.9% → 4.3%,
/// pure Bangla unchanged (it has no Latin words to replace).
enum EnglishSpelling {
    /// Tuned on those sets; confidence below this is Apple guessing.
    static let minConfidence = 0.6
    static let minSimilarity = 0.4

    static func apply(to heard: String, apple: [AppleWord]) -> String {
        let h = heard.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !h.isEmpty, !apple.isEmpty, h.contains(where: isLatinWord) else { return heard }
        let hk = h.map { key(BanglaRomanizer.apply(to: $0)) }
        let ak = apple.map { key($0.text) }
        let n = h.count, m = apple.count

        // Monotonic alignment by sound. Skipping a word on either side costs
        // 0.6, so Apple's noise over Bangla speech is skipped, not matched.
        struct Step { var i, j: Int; var span: (h: Int, a: Int, sim: Double)? }
        var cost = Array(repeating: Array(repeating: Double.infinity, count: m + 1), count: n + 1)
        var back = Array(repeating: Array(repeating: Step?.none, count: m + 1), count: n + 1)
        cost[0][0] = 0
        for i in 0...n {
            for j in 0...m where cost[i][j] < .infinity {
                func relax(_ ni: Int, _ nj: Int, _ c: Double, _ span: (Int, Int, Double)?) {
                    if cost[i][j] + c < cost[ni][nj] {
                        cost[ni][nj] = cost[i][j] + c
                        back[ni][nj] = Step(i: i, j: j, span: span)
                    }
                }
                if i < n { relax(i + 1, j, 0.6, nil) }
                if j < m { relax(i, j + 1, 0.6, nil) }
                for (hn, an) in [(1, 1), (2, 1), (1, 2), (3, 1), (1, 3)] where i + hn <= n && j + an <= m {
                    let s = similarity(hk[i..<i + hn].joined(), ak[j..<j + an].joined())
                    relax(i + hn, j + an, (1 - s) * Double(max(hn, an)), (hn, an, s))
                }
            }
        }

        var out = h.map(Optional.some)
        var i = n, j = m
        while i > 0 || j > 0, let step = back[i][j] {
            if let span = step.span,
               span.sim >= minSimilarity,
               h[step.i..<step.i + span.h].allSatisfy(isLatinWord),
               apple[step.j..<step.j + span.a].allSatisfy({ $0.confidence >= minConfidence }) {
                let words = apple[step.j..<step.j + span.a].map { $0.text.trimmingCharacters(in: .punctuationCharacters) }
                if !words.contains(where: \.isEmpty) {
                    // Keep the sentence's own punctuation, not Apple's.
                    let last = h[step.i + span.h - 1]
                    let trail = String(last.reversed().prefix { ".,!?;:।".contains($0) }.reversed())
                    out[step.i] = words.joined(separator: " ") + trail
                    for k in 1..<span.h { out[step.i + k] = nil }
                }
            }
            i = step.i
            j = step.j
        }
        return out.compactMap { $0 }.joined(separator: " ")
    }

    private static func isLatinWord(_ word: String) -> Bool {
        word.unicodeScalars.contains { ("A"..."Z").contains($0) || ("a"..."z").contains($0) }
            && !word.unicodeScalars.contains { (0x0980...0x09FF).contains($0.value) }
    }

    /// Crude phonetic key shared by English spellings and romanized Bangla,
    /// so "may nem ij" and "My name is" compare by sound.
    static func key(_ word: String) -> String {
        var w = String(word.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII })
        for (a, b) in [("tion", "shon"), ("ph", "f"), ("sh", "s"), ("ch", "c"), ("th", "t"), ("dh", "d"),
                       ("bh", "b"), ("kh", "k"), ("gh", "g"), ("jh", "j"), ("ck", "k"), ("q", "k"), ("x", "ks"),
                       ("z", "j"), ("v", "b"), ("w", "o"), ("y", "i"), ("c", "k"), ("ee", "i"), ("oo", "u"),
                       ("e", "i"), ("a", "o")] {
            w = w.replacingOccurrences(of: a, with: b)
        }
        return w.reduce(into: "") { if $0.last != $1 { $0.append($1) } }
    }

    /// 1 − edit distance / longer length.
    static func similarity(_ a: String, _ b: String) -> Double {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i]
            for j in 1...b.count {
                cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)))
            }
            prev = cur
        }
        return 1 - Double(prev[b.count]) / Double(max(a.count, b.count))
    }
}

// MARK: - Banglish romanization

/// Turns Bangla script into the romanized Banglish people actually type
/// ("আমরা কালকে যাবো" → "amra kalke jabo"). Everything that is not Bangla
/// script — the English words Whisper already writes in English, digits,
/// punctuation — passes through untouched, so a code-switched sentence keeps
/// its English exactly as spoken.
///
/// Colloquial values rather than a scholarly transliteration: শ/ষ/স → sh,
/// য → j, অ → o. The inherent vowel is dropped where speech drops it: at the
/// end of a word, and between two syllables that already carry a vowel
/// ("kal-ke", not "kalake"; "kor-bo", not "karabo").
/// ponytail: rules plus a short exception list, not a lexicon — a loanword
/// Whisper spells in Bangla script comes out phonetic ("miting").
enum BanglaRomanizer {
    private static let virama: Unicode.Scalar = "\u{09CD}"

    private static let consonants: [Unicode.Scalar: String] = [
        "\u{0995}": "k", "\u{0996}": "kh", "\u{0997}": "g", "\u{0998}": "gh", "\u{0999}": "ng",
        "\u{099A}": "ch", "\u{099B}": "ch", "\u{099C}": "j", "\u{099D}": "jh", "\u{099E}": "n",
        "\u{099F}": "t", "\u{09A0}": "th", "\u{09A1}": "d", "\u{09A2}": "dh", "\u{09A3}": "n",
        "\u{09A4}": "t", "\u{09A5}": "th", "\u{09A6}": "d", "\u{09A7}": "dh", "\u{09A8}": "n",
        "\u{09AA}": "p", "\u{09AB}": "f", "\u{09AC}": "b", "\u{09AD}": "bh", "\u{09AE}": "m",
        "\u{09AF}": "j", "\u{09B0}": "r", "\u{09B2}": "l", "\u{09B6}": "sh", "\u{09B7}": "sh",
        "\u{09B8}": "sh", "\u{09B9}": "h", "\u{09DC}": "r", "\u{09DD}": "r", "\u{09DF}": "y",
        "\u{09CE}": "t",
    ]
    private static let independentVowels: [Unicode.Scalar: String] = [
        "\u{0985}": "o", "\u{0986}": "a", "\u{0987}": "i", "\u{0988}": "i", "\u{0989}": "u",
        "\u{098A}": "u", "\u{098B}": "ri", "\u{098F}": "e", "\u{0990}": "oi", "\u{0993}": "o",
        "\u{0994}": "ou",
    ]
    private static let vowelSigns: [Unicode.Scalar: String] = [
        "\u{09BE}": "a", "\u{09BF}": "i", "\u{09C0}": "i", "\u{09C1}": "u", "\u{09C2}": "u",
        "\u{09C3}": "ri", "\u{09C7}": "e", "\u{09C8}": "oi", "\u{09CB}": "o", "\u{09CC}": "ou",
    ]
    /// Anusvara and visarga voice the vowel before them; chandrabindu (nasal) is dropped.
    private static let modifiers: [Unicode.Scalar: String] = [
        "\u{0982}": "ng", "\u{0983}": "h", "\u{0981}": "",
    ]
    /// High-frequency words whose final vowel is spoken, which no simple
    /// schwa rule gets right.
    private static let exceptions: [String: String] = [
        "কেন": "keno", "কত": "koto", "এত": "eto", "যত": "joto", "তত": "toto",
        "মত": "moto", "বড়": "boro", "ছোট": "choto", "ভাল": "bhalo", "হ্যাঁ": "ha",
    ]

    private enum Vowel { case inherent, none, sign(String) }
    private enum Unit {
        case vowel(String)
        case consonant(sound: String, vowel: Vowel, joined: Bool)
        case modifier(String)
    }

    static func apply(to text: String) -> String {
        // Nukta forms arrive decomposed (NFC keeps them apart), so fold them first.
        let folded = text
            .replacingOccurrences(of: "\u{09AF}\u{09BC}", with: "\u{09DF}")
            .replacingOccurrences(of: "\u{09A1}\u{09BC}", with: "\u{09DC}")
            .replacingOccurrences(of: "\u{09A2}\u{09BC}", with: "\u{09DD}")
        guard folded.unicodeScalars.contains(where: isBangla) else { return text }

        var out = ""
        var word = String.UnicodeScalarView()
        func flush() {
            guard !word.isEmpty else { return }
            out += romanize(word: String(word))
            word.removeAll()
        }
        for scalar in folded.unicodeScalars {
            switch scalar.value {
            case 0x09E6...0x09EF: flush(); out.unicodeScalars.append(Unicode.Scalar(scalar.value - 0x09E6 + 0x30)!)
            case 0x0964, 0x0965: flush(); out += "."
            case 0x200C, 0x200D, 0x09BC: continue
            default:
                if isBangla(scalar) { word.append(scalar) } else { flush(); out.unicodeScalars.append(scalar) }
            }
        }
        flush()
        return out
    }

    private static func isBangla(_ s: Unicode.Scalar) -> Bool { (0x0980...0x09FF).contains(s.value) }

    private static func romanize(word: String) -> String {
        if let known = exceptions[word] { return known }

        // Pass 1: letters into units.
        var units: [Unit] = []
        var afterVirama = false
        let scalars = Array(word.unicodeScalars)
        for (i, s) in scalars.enumerated() {
            if var sound = consonants[s] {
                var joined = false
                if afterVirama, case .consonant(let prev, _, _)? = units.last {
                    joined = true
                    let clusterStartsWord = units.count == 1
                    switch s {
                    case "\u{09B7}" where prev == "k":                  // ক্ষ
                        units[units.count - 1] = .consonant(sound: "kh", vowel: .none, joined: false)
                        units.append(.consonant(sound: "", vowel: .inherent, joined: true))
                        afterVirama = false
                        continue
                    case "\u{09AF}":                                     // ya-phala
                        let nextIsAa = i + 1 < scalars.count && scalars[i + 1] == "\u{09BE}"
                        sound = clusterStartsWord ? (nextIsAa ? "" : "y") : (prev.count == 1 ? prev : "")
                    case "\u{09AC}":                                     // ba-phala
                        sound = clusterStartsWord ? "" : (prev.count == 1 ? prev : "")
                    default: break
                    }
                }
                // স before a virama starts a cluster ("school", "rasta"): plain s.
                if s == "\u{09B8}", i + 1 < scalars.count, scalars[i + 1] == virama { sound = "s" }
                units.append(.consonant(sound: sound, vowel: s == "\u{09CE}" ? .none : .inherent, joined: joined))
                afterVirama = false
            } else if s == virama {
                if case .consonant(let sound, _, let joined)? = units.last {
                    units[units.count - 1] = .consonant(sound: sound, vowel: .none, joined: joined)
                }
                afterVirama = true
            } else if let sign = vowelSigns[s] {
                if case .consonant(let sound, _, let joined)? = units.last {
                    units[units.count - 1] = .consonant(sound: sound, vowel: .sign(sign), joined: joined)
                } else {
                    units.append(.vowel(sign))
                }
                afterVirama = false
            } else if let vowel = independentVowels[s] {
                units.append(.vowel(vowel)); afterVirama = false
            } else if let mod = modifiers[s] {
                units.append(.modifier(mod)); afterVirama = false
            }
        }

        // Pass 2: decide each inherent vowel and render.
        let letterIndices = units.indices.filter { if case .modifier = units[$0] { return false }; return true }
        var out = ""
        var previousVoiced = false
        for (position, index) in letterIndices.enumerated() {
            let modifierFollows: Bool = {
                guard index + 1 < units.count, case .modifier(let m) = units[index + 1] else { return false }
                return !m.isEmpty
            }()
            switch units[index] {
            case .vowel(let v):
                out += v; previousVoiced = true
            case .consonant(let sound, .sign(let v), _):
                out += sound + v; previousVoiced = true
            case .consonant(let sound, .none, _):
                out += sound; previousVoiced = false
            case .consonant(let sound, .inherent, let joined):
                let isLast = position == letterIndices.count - 1
                let nextHasSign: Bool = {
                    guard !isLast, case .consonant(_, .sign, false) = units[letterIndices[position + 1]] else { return false }
                    return true
                }()
                let voiced: Bool
                if modifierFollows || letterIndices.count == 1 {
                    voiced = true
                } else if isLast {
                    voiced = joined                     // "shob-do", "jach-cho"; else silent
                } else if position == 0 {
                    voiced = true
                } else {
                    voiced = !(previousVoiced && nextHasSign && !joined)
                }
                out += sound + (voiced ? "o" : "")
                previousVoiced = voiced
            case .modifier:
                break
            }
            if index + 1 < units.count, case .modifier(let m) = units[index + 1] { out += m }
        }
        return out
    }
}
