import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Reads the text field a dictation was pasted into twice — right after the
/// paste and again once the user had time to fix a misheard word — and hands
/// the difference to `CorrectionLearner`. Opt-in ("Learn from my corrections").
///
/// Privacy, by construction: the field's text lives only in memory, for one
/// edit window, and is never logged or written anywhere. Only the word pairs
/// `CorrectionLearner` returns leave this class. Secure (password) fields and
/// Secure Event Input are never read.
///
/// Reads go through Accessibility, which UFlow already holds. An app that
/// exposes no value for its focused element (some Electron and canvas-drawn
/// editors) simply yields nothing.
@MainActor
final class CorrectionWatcher {
    /// ponytail: how long the user gets to fix words before the field is read
    /// again. The next hotkey press ends the window early.
    static let editWindow: Duration = .seconds(25)
    /// The paste lands when the destination app handles ⌘V, which for
    /// Electron and browsers can take a few hundred ms.
    static let pasteLandDelay: Duration = .milliseconds(900)
    /// Fields bigger than this (a whole manuscript) aren't worth reading.
    static let maxFieldLength = 200_000
    /// Each Accessibility call is a synchronous round trip to the other app;
    /// a hung app must not hang UFlow.
    private static let messagingTimeout: Float = 0.5

    /// Called with the fixes found once a watch concludes. Never with the text.
    var onFixes: (([LearnedFix]) -> Void)?

    private struct Watch {
        let element: AXUIElement
        let before: String
        let dictated: String
    }

    private var watch: Watch?
    private var task: Task<Void, Never>?
    private var generation = 0

    /// Starts watching the focused field for corrections to `dictated`. A
    /// watch already running is concluded first — its window is over.
    func begin(dictated: String) {
        finishNow()
        cancel()
        let current = generation
        task = Task { [weak self] in
            try? await Task.sleep(for: Self.pasteLandDelay)
            guard let self, self.generation == current, !Task.isCancelled else { return }
            guard let element = Self.focusedTextElement(), let before = Self.value(of: element) else {
                Log.app.info("Correction watch skipped: no readable text field")
                return
            }
            self.watch = Watch(element: element, before: before, dictated: dictated)

            try? await Task.sleep(for: Self.editWindow)
            guard self.generation == current, !Task.isCancelled else { return }
            // The user may be mid-word when the window closes; wait until the
            // field stops changing so a half-typed "Cla" isn't learned.
            var last = Self.value(of: element)
            for _ in 0..<4 {
                try? await Task.sleep(for: .milliseconds(1500))
                guard self.generation == current, !Task.isCancelled else { return }
                let now = Self.value(of: element)
                if now == last { break }
                last = now
            }
            self.conclude(after: last)
        }
    }

    /// The next dictation is starting: whatever the user fixed by now is final.
    func finishNow() {
        guard let watch else { return }
        conclude(after: Self.value(of: watch.element))
    }

    /// Drops any watch without reading the field again (setting turned off).
    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        watch = nil
    }

    private func conclude(after: String?) {
        guard let watch else { return }
        cancel()
        guard let after, !IsSecureEventInputEnabled(), !Self.isSecure(watch.element) else { return }
        let fixes = CorrectionLearner.suggestions(
            before: watch.before, after: after, dictated: watch.dictated,
            isOrdinaryWord: Self.isOrdinaryWord)
        Log.app.info("Correction watch finished: \(fixes.count, privacy: .public) suggestion(s)")
        if !fixes.isEmpty { onFixes?(fixes) }
    }

    // MARK: - Accessibility reads

    private static func focusedTextElement() -> AXUIElement? {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return isSecure(element) ? nil : element
    }

    private static func value(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String, (text as NSString).length <= maxFieldLength else { return nil }
        return text
    }

    private static func isSecure(_ element: AXUIElement) -> Bool {
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        return (subrole as? String) == kAXSecureTextFieldSubrole
    }

    /// The system spelling dictionary, as `DictionaryEntry.risk` uses it.
    private static func isOrdinaryWord(_ word: String) -> Bool {
        guard word.count > 1, word.allSatisfy({ $0.isLetter || $0 == "'" }) else { return false }
        return NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0).location == NSNotFound
    }
}
