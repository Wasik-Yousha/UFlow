import AppKit
import Carbon.HIToolbox
import Foundation
import ServiceManagement

// =============================================================================
// MARK: - Where things live
// =============================================================================

/// The app is not sandboxed, so this is a real path the user can open, edit in
/// any text editor, and keep in version control if they want to.
///
///     ~/Library/Application Support/UFlow/
///         dictionary.txt      plain text, hand-editable
///         transcripts.json    history
enum Store {
    static let directory: URL = {
        // A snapshot or test run points this somewhere disposable so it can
        // never write over somebody's real dictionary or history.
        let base = ProcessInfo.processInfo.environment["UFLOW_STORE_DIR"].map { URL(filePath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("UFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static var dictionaryFile: URL { directory.appendingPathComponent("dictionary.txt") }
    static var transcriptsFile: URL { directory.appendingPathComponent("transcripts.json") }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// =============================================================================
// MARK: - Dictionary
// =============================================================================

/// One thing the user has taught the app.
///
/// - `.term` is a word or phrase it should know: "Anthropic", "Supabase".
///   It is fed to the engine as bias, and it also normalises its own spelling
///   afterwards (so "anthropic" and "Anthropic" both land as "Anthropic").
/// - `.fix` is a correction pair: when you hear X, write Y.
struct DictionaryEntry: Identifiable, Hashable, Codable {
    enum Kind: String, Codable, CaseIterable {
        case term, fix
        var label: String { self == .term ? "TERM" : "FIX" }
    }

    var id = UUID()
    var kind: Kind
    /// What to look for in the transcript.
    var match: String
    /// What to write instead. For a `.term` this is the canonical spelling.
    var replacement: String
    var isEnabled = true

    init(id: UUID = UUID(), kind: Kind, match: String, replacement: String? = nil, isEnabled: Bool = true) {
        self.id = id
        self.kind = kind
        self.match = match
        self.replacement = replacement ?? match
        self.isEnabled = isEnabled
    }

    /// What the engine should be biased toward — always the canonical spelling.
    var biasTerm: String { replacement }
}

// MARK: Risk check

extension DictionaryEntry {
    /// Why an entry might do damage. Surfaced in the UI before it is saved.
    ///
    /// Multi-word phrases are inherently safe: the correction pass requires the
    /// whole phrase, so "Claude Code" cannot reach "Cloudflare". The real
    /// hazard is a single ordinary word, which would be rewritten every time it
    /// legitimately appears.
    enum Risk: Equatable {
        case tooShort
        case ordinaryWord(String)
        case noop

        var message: String {
            switch self {
            case .tooShort:
                return "Very short entries match constantly. Two characters will fire on almost any sentence."
            case .ordinaryWord(let word):
                return "\u{201C}\(word)\u{201D} is an ordinary English word. Every time you say it normally, it will be rewritten."
            case .noop:
                return "This finds and writes the same thing, so it will never change anything."
            }
        }
    }

    /// Checks an entry before it is saved. Uses the system spelling dictionary
    /// rather than a hand-kept word list, so it stays right without maintenance.
    @MainActor
    static func risk(kind: Kind, match: String, replacement: String) -> Risk? {
        let source = match.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = (kind == .term ? source : replacement).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return nil }

        if kind == .fix, source.compare(target, options: .caseInsensitive) == .orderedSame {
            return .noop
        }
        if source.count < 3 { return .tooShort }

        // Only a single bare word is dangerous; a phrase needs all of its parts.
        let words = source.split { $0.isWhitespace || $0 == "-" }
        guard words.count == 1, let word = words.first else { return nil }
        guard word.allSatisfy(\.isLetter) else { return nil }

        let checker = NSSpellChecker.shared
        let range = checker.checkSpelling(of: String(word), startingAt: 0)
        // A correctly spelled word comes back with no misspelling range.
        if range.location == NSNotFound, word.count > 2 {
            return .ordinaryWord(String(word))
        }
        return nil
    }
}

// MARK: Store

/// Owns the dictionary and keeps the plain-text file and the UI in step.
///
/// The file is the format of record. Everything the UI does is written straight
/// back out, and the file is re-read whenever the app comes forward, so editing
/// it in a text editor and switching back to UFlow just works.
///
/// ponytail: reload-on-activate rather than an FSEvents watcher. Upgrade to a
/// DispatchSource on the parent directory if live external edits matter.
@MainActor
final class DictionaryStore: ObservableObject {
    @Published private(set) var entries: [DictionaryEntry] = []
    @Published private(set) var ruleset = CorrectionEngine.build(from: [])

    /// Bumped whenever the engine should be re-biased.
    @Published private(set) var revision = 0

    private var lastLoadedText = ""

    init() { load() }

    var fileURL: URL { Store.dictionaryFile }

    // MARK: Editing

    func add(_ entry: DictionaryEntry) {
        entries.insert(entry, at: 0)
        commit()
    }

    func update(_ entry: DictionaryEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        commit()
    }

    func delete(_ entry: DictionaryEntry) {
        entries.removeAll { $0.id == entry.id }
        commit()
    }

    func toggle(_ entry: DictionaryEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].isEnabled.toggle()
        commit()
    }

    private func commit() {
        ruleset = CorrectionEngine.build(from: entries)
        revision &+= 1
        save()
    }

    // MARK: Bias list

    /// The short list handed to the speech engine.
    ///
    /// Deliberately capped: a long contextual list makes these models drift and
    /// invent text on quiet audio, which is far worse than a missed term. The
    /// correction pass is the guaranteed path, so this only has to nudge.
    func biasTerms(limit: Int = 40) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for entry in entries where entry.isEnabled {
            let term = entry.biasTerm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
            out.append(term)
            if out.count == limit { break }
        }
        return out
    }

    // MARK: File I/O

    /// Re-reads the file if it changed underneath us. Cheap enough to call on
    /// every app activation.
    func reloadIfChanged() {
        let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        guard text != lastLoadedText else { return }
        Log.app.info("dictionary.txt changed on disk — reloading")
        load()
    }

    func load() {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            entries = Self.starterEntries
            ruleset = CorrectionEngine.build(from: entries)
            save()
            return
        }
        lastLoadedText = text
        entries = Self.parse(text)
        ruleset = CorrectionEngine.build(from: entries)
        revision &+= 1
    }

    private func save() {
        let text = Self.serialize(entries)
        lastLoadedText = text
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            Log.app.error("Could not write dictionary.txt: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Plain-text format

    nonisolated static let header = """
    # UFlow dictionary
    #
    # One entry per line.
    #   A word or phrase to recognise:   Anthropic
    #   A correction, heard => written:  cloud code => Claude Code
    #
    # Matching is whole-word and case-insensitive, and the words of a phrase may
    # be joined by spaces, hyphens or nothing at all — "cloud code" also catches
    # "cloudcode" and "Cloud-Code". A phrase never matches part of another word,
    # so "Claude Code" leaves "Cloudflare" alone.
    #
    # Prefix a line with ! to keep an entry without applying it.

    """

    nonisolated static func serialize(_ entries: [DictionaryEntry]) -> String {
        var out = header
        for entry in entries {
            let prefix = entry.isEnabled ? "" : "!"
            switch entry.kind {
            case .term: out += "\(prefix)\(entry.match)\n"
            case .fix:  out += "\(prefix)\(entry.match) => \(entry.replacement)\n"
            }
        }
        return out
    }

    nonisolated static func parse(_ text: String) -> [DictionaryEntry] {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { rawLine in
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }

            var enabled = true
            if line.hasPrefix("!") {
                enabled = false
                line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { return nil }
            }

            // "=>" is the documented separator; "->" is accepted because people
            // type it and there is no reason to punish them for it.
            for arrow in ["=>", "->", "\u{2192}"] where line.contains(arrow) {
                let parts = line.components(separatedBy: arrow)
                let from = parts[0].trimmingCharacters(in: .whitespaces)
                let to = parts.dropFirst().joined(separator: arrow).trimmingCharacters(in: .whitespaces)
                guard !from.isEmpty, !to.isEmpty else { return nil }
                return DictionaryEntry(kind: .fix, match: from, replacement: to, isEnabled: enabled)
            }
            return DictionaryEntry(kind: .term, match: line, isEnabled: enabled)
        }
    }

    /// Written once, on first launch, so the file is self-explanatory when the
    /// user opens it and the feature is not a blank page.
    static let starterEntries: [DictionaryEntry] = [
        DictionaryEntry(kind: .term, match: "Anthropic"),
        DictionaryEntry(kind: .term, match: "Claude Code"),
        DictionaryEntry(kind: .term, match: "Vercel"),
        DictionaryEntry(kind: .term, match: "Supabase"),
        DictionaryEntry(kind: .fix, match: "cloud code", replacement: "Claude Code"),
        DictionaryEntry(kind: .fix, match: "clawed code", replacement: "Claude Code"),
    ]
}

// =============================================================================
// MARK: - Transcripts
// =============================================================================

struct TranscriptRecord: Identifiable, Hashable, Codable {
    var id = UUID()
    var date: Date
    var engine: String
    var duration: TimeInterval
    var text: String
    var corrections: [AppliedCorrection] = []

    var timeLabel: String {
        let f = DateFormatter()
        f.dateFormat = "h:mma"
        f.amSymbol = "AM"; f.pmSymbol = "PM"
        return f.string(from: date)
    }

    var durationLabel: String { String(format: "%.2fs", duration) }
}

/// History, persisted as JSON. Capped so the file cannot grow without bound.
@MainActor
final class TranscriptStore: ObservableObject {
    @Published private(set) var records: [TranscriptRecord] = []

    private static let cap = 1000

    init() { load() }

    func add(_ record: TranscriptRecord) {
        records.append(record)
        // Newest first, regardless of the order things were appended in.
        records.sort { $0.date > $1.date }
        if records.count > Self.cap { records.removeLast(records.count - Self.cap) }
        save()
    }

    func delete(_ record: TranscriptRecord) {
        records.removeAll { $0.id == record.id }
        save()
    }

    func deleteAll() {
        records.removeAll()
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Store.transcriptsFile),
              let decoded = try? JSONDecoder().decode([TranscriptRecord].self, from: data) else { return }
        records = decoded.sorted { $0.date > $1.date }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(records)
            try data.write(to: Store.transcriptsFile, options: .atomic)
        } catch {
            Log.app.error("Could not write transcripts.json: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// =============================================================================
// MARK: - Settings
// =============================================================================

/// Which look the app wears.
///
/// Every colour token is already a light/dark pair, so this decides nothing
/// about the palette itself — only which half of each pair resolves. Setting
/// `NSApp.appearance` covers every window the app owns, the floating HUD
/// included, so nothing has to be told about the change individually.
/// How the hotkey chord behaves.
enum HotkeyMode: String, CaseIterable, Codable, Sendable {
    /// Tap once to start, talk freely, tap again to stop.
    case toggle
    /// Classic push-to-talk — hold the chord while speaking, release to stop.
    case hold

    var label: String {
        switch self {
        case .toggle: "Tap to toggle"
        case .hold: "Hold to talk"
        }
    }

    var detail: String {
        switch self {
        case .toggle: "Tap once to start, tap again to stop."
        case .hold: "Hold the chord while speaking, release to stop."
        }
    }
}

enum AppearancePreference: String, CaseIterable, Codable, Sendable {
    case system, light, dark

    var label: String {
        switch self {
        case .system: "Match system"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var detail: String {
        switch self {
        case .system: "Follow the macOS appearance setting."
        case .light: "Cream chassis, always."
        case .dark: "Graphite chassis, always."
        }
    }

    /// `nil` hands the decision back to macOS.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// User preferences, backed by UserDefaults. Small enough that a property list
/// of its own would be ceremony.
@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let modifier = "hotkey.modifierKeyCode"
        static let trigger = "hotkey.triggerKeyCode"
        static let mode = "hotkey.mode"
        static let backend = "engine.backend"
        static let sound = "ui.soundEnabled"
        static let menuBar = "ui.menuBarItem"
        static let appearance = "ui.appearance"
        static let launchAtLogin = "ui.launchAtLogin"
    }

    private let defaults = UserDefaults.standard

    /// Stored as `Self.noLetterSentinel` in defaults when nil, so "Fn alone"
    /// shares the one Int-typed key rather than needing a second default to
    /// distinguish "never configured" from "explicitly no letter".
    private static let noLetterSentinel = -1

    @Published var modifierKeyCode: Int { didSet { defaults.set(modifierKeyCode, forKey: Key.modifier) } }
    @Published var triggerKeyCode: Int? {
        didSet { defaults.set(triggerKeyCode ?? Self.noLetterSentinel, forKey: Key.trigger) }
    }
    @Published var hotkeyMode: HotkeyMode { didSet { defaults.set(hotkeyMode.rawValue, forKey: Key.mode) } }

    /// The mode actually used at trigger time. Fn held alone is forced to
    /// hold-to-talk: a toggle would fire on every incidental tap of Fn (input
    /// source switching, emoji panel muscle memory) since there's no second
    /// key to disambiguate an intentional press.
    var effectiveHotkeyMode: HotkeyMode { triggerKeyCode == nil ? .hold : hotkeyMode }
    @Published var backend: BackendPreference { didSet { defaults.set(backend.rawValue, forKey: Key.backend) } }
    @Published var showMenuBarItem: Bool { didSet { defaults.set(showMenuBarItem, forKey: Key.menuBar) } }

    @Published var appearance: AppearancePreference {
        didSet {
            defaults.set(appearance.rawValue, forKey: Key.appearance)
            applyAppearance()
        }
    }

    @Published var soundEnabled: Bool {
        didSet {
            defaults.set(soundEnabled, forKey: Key.sound)
            SoundKit.isEnabled = soundEnabled
        }
    }

    /// Keeps the process resident across reboots, which is what makes Fn+Y
    /// work "without opening the app" — nobody opens anything; it is simply
    /// always there. The system records the running bundle's location.
    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Key.launchAtLogin)
            reconcileLoginItem()
        }
    }

    init() {
        modifierKeyCode = defaults.object(forKey: Key.modifier) as? Int ?? kVK_Function
        // Default is Fn held alone — the fewest possible moving parts.
        let storedTrigger = defaults.object(forKey: Key.trigger) as? Int ?? Self.noLetterSentinel
        triggerKeyCode = storedTrigger == Self.noLetterSentinel ? nil : storedTrigger
        hotkeyMode = (defaults.string(forKey: Key.mode).flatMap(HotkeyMode.init(rawValue:))) ?? .toggle
        backend = (defaults.string(forKey: Key.backend).flatMap(BackendPreference.init(rawValue:))) ?? .automatic
        soundEnabled = defaults.object(forKey: Key.sound) as? Bool ?? true
        showMenuBarItem = defaults.object(forKey: Key.menuBar) as? Bool ?? true
        launchAtLogin = defaults.object(forKey: Key.launchAtLogin) as? Bool ?? true
        appearance = (defaults.string(forKey: Key.appearance)
            .flatMap(AppearancePreference.init(rawValue:))) ?? .system
        SoundKit.isEnabled = soundEnabled
        applyAppearance()
    }

    /// Makes the system's login-item state agree with the stored preference.
    /// Safe to call repeatedly; each call is a cheap status check in the common
    /// already-in-agreement case.
    func reconcileLoginItem() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .notRegistered where launchAtLogin:
                try service.register()
                Log.app.info("Registered as login item")
            case .enabled where !launchAtLogin:
                try service.unregister()
                Log.app.info("Unregistered login item")
            default:
                break
            }
        } catch {
            // A refused registration must never block launch or dictation.
            Log.app.error("Login item update failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Applies the chosen look to every window the app owns.
    ///
    /// Called again from `applicationDidFinishLaunching`, because during
    /// `init` this runs before NSApplication exists and the assignment would
    /// be silently dropped.
    func applyAppearance() {
        guard let app = NSApp else { return }
        app.appearance = appearance.nsAppearance
    }

    var hotkeyTrigger: HotkeyManager.Trigger {
        .init(modifierKeyCode: modifierKeyCode, triggerKeyCode: triggerKeyCode)
    }
}
