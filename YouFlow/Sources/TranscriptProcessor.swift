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

        Log.app.info("CorrectionEngine self-check passed")
        if CommandLine.arguments.contains("--self-check") {
            print("CorrectionEngine self-check: PASS")
        }
    }
}
