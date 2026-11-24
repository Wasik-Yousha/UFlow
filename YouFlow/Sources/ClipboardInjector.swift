import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Outcome of an injection attempt, used for logging and HUD feedback.
enum InjectionOutcome {
    /// Pasted into the frontmost (origin) application via the universal path.
    case injected
    /// Origin app is no longer frontmost; paste was posted directly to the
    /// origin app's PID. Transcript intentionally left on the clipboard.
    case injectedToOriginalApp
    /// Nothing was pasted; the transcript remains on the clipboard.
    case keptOnClipboard(reason: String)
}

/// Universal text delivery: clipboard write + synthetic Cmd+V.
///
/// This is deliberately the ONLY injection strategy. Chromium/Electron/web
/// text fields, Notes, Slack, VS Code, Xcode and Terminal all handle a real
/// paste keystroke identically, so the destination receives exactly what it
/// would receive from a physical Cmd+V. No AXValue writes, no JavaScript, no
/// per-character typing.
///
/// Focus rules enforced here:
/// - Never activates this app (no NSApp.activate / NSRunningApplication.activate).
/// - Same-frontmost-app case: events posted to the HID tap land in whatever
///   currently owns keyboard focus — the origin app in the normal case.
/// - Origin-switched case (user moved to another app mid-dictation): events
///   are posted directly to the origin app's PID, and clipboard restoration
///   is skipped so the transcript stays available on the clipboard as a
///   safety net.
///
/// Clipboard preservation:
/// - The previous pasteboard is snapshotted as value types (UTI string →
///   Data) before any mutation; unreadable clipboards never block dictation.
/// - Restoration is race-safe: it happens only when `changeCount` still
///   matches the state this app created, so user/system clipboard writes
///   during the injection window are never destroyed.
/// - Restoration is deferred (see `restorationDelay`) and runs in the
///   background, so `inject` returns as soon as the keystroke is posted.
@MainActor
final class ClipboardInjector {
    /// How long the transcript stays on the clipboard after ⌘V is posted
    /// before the user's previous clipboard is put back.
    ///
    /// Why it isn't shorter: the destination app reads the pasteboard when it
    /// *handles* the keystroke, not when we post it. Native AppKit apps do
    /// that within a few ms, but Chromium/Electron apps route the key through
    /// a renderer process and read the pasteboard asynchronously; under CPU
    /// load or on heavy pages that regularly takes 100–300 ms. Restoring
    /// earlier makes the app paste the user's OLD clipboard instead of the
    /// dictation — the most common complaint in other dictation tools (the
    /// earlier 100 ms default here had the same flaw).
    ///
    /// Why it isn't much longer: during this window a manual ⌘V by the user
    /// would paste the transcript rather than their own clipboard. The
    /// `changeCount` guard still protects anything the user *copies* in the
    /// window, so a longer delay never loses data — it only widens that
    /// small "old clipboard not back yet" window.
    var restorationDelay: Duration = .milliseconds(350)
    /// Used instead of `restorationDelay` for destinations known to read the
    /// pasteboard late: Electron apps, browsers, and a few other slow pasters
    /// (see `isSlowPaster`). 700 ms covers a renderer that is busy with a
    /// heavy page or a long Slack/Notion document.
    var slowAppRestorationDelay: Duration = .milliseconds(700)

    /// Small gap between keyDown and keyUp so every app observes a real press.
    private let keystrokeGap: Duration = .milliseconds(15)
    /// Settle time between the pasteboard write and the synthetic ⌘V. Without
    /// it, a fast paste can grab the *previous* pasteboard generation.
    private let pasteSettleDelay: Duration = .milliseconds(40)
    /// Private event source: never inherits live hardware modifier state.
    private let eventSource = CGEventSource(stateID: .privateState)

    // MARK: - Snapshot types

    /// Value-type snapshot of one pasteboard item: (UTI string, data) pairs.
    private typealias ItemSnapshot = [(type: String, data: Data)]
    private typealias Snapshot = (items: [ItemSnapshot], changeCount: Int)

    /// A scheduled restore that has not run yet.
    private struct PendingRestore {
        let task: Task<Void, Never>
        /// Pasteboard `changeCount` right after the transcript was written.
        let ownedChangeCount: Int
        /// What the clipboard is meant to hold once this injection settles:
        /// the user's original clipboard (normal route) or the plain
        /// transcript (origin-PID route). Carried forward if a new injection
        /// starts before the restore ran, so the user's real clipboard is not
        /// replaced by a snapshot of our own transcript.
        let settledContents: Snapshot?
    }
    private var pendingRestore: PendingRestore?
    private var terminationObserver: NSObjectProtocol?

    init() {
        // A restore still waiting out its delay must not be lost when the app
        // quits (menu Quit, update relaunch): the user's clipboard would stay
        // replaced by a transient transcript that clipboard managers skipped.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushPendingRestore() }
        }
    }

    /// Runs a pending restore right now instead of after its delay.
    func flushPendingRestore() {
        guard let pending = pendingRestore else { return }
        pending.task.cancel()
        pendingRestore = nil
        Log.clipboard.info("Flushing pending clipboard restore")
        restoreIfUnchanged(pending.settledContents, ownedState: pending.ownedChangeCount)
    }

    /// Best-effort snapshot of the entire General pasteboard. Returns nil when
    /// macOS privacy rules make the clipboard unreadable — dictation proceeds
    /// regardless; only restoration is skipped.
    private func snapshotClipboard() -> Snapshot? {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        var items: [ItemSnapshot] = []

        for item in pasteboard.pasteboardItems ?? [] {
            var entry: ItemSnapshot = []
            for type in item.types {
                let uti = type.rawValue
                guard !uti.isEmpty else { continue }
                if let data = item.data(forType: type) {
                    entry.append((uti, data))
                }
            }
            if !entry.isEmpty {
                items.append(entry)
            }
        }
        Log.clipboard.info("Clipboard snapshotted (items=\(items.count, privacy: .public) count=\(changeCount, privacy: .public))")
        return (items, changeCount)
    }

    /// Restores a snapshot only when the pasteboard is still in the state this
    /// app created after pasting.
    private func restoreIfUnchanged(_ snapshot: Snapshot?, ownedState: Int) {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == ownedState else {
            Log.clipboard.info("Clipboard restoration skipped: changeCount changed")
            return
        }
        guard let snapshot, !snapshot.items.isEmpty else {
            Log.clipboard.info("Clipboard restoration skipped: original clipboard unreadable")
            return
        }

        pasteboard.clearContents()
        var restoredObjects: [NSPasteboardItem] = []
        for entry in snapshot.items {
            let item = NSPasteboardItem()
            var wroteAny = false
            for (uti, data) in entry {
                if item.setData(data, forType: NSPasteboard.PasteboardType(uti)) {
                    wroteAny = true
                }
            }
            if wroteAny {
                restoredObjects.append(item)
            }
        }
        if restoredObjects.isEmpty {
            Log.clipboard.info("Clipboard restoration skipped: no restorable representations")
            return
        }
        pasteboard.writeObjects(restoredObjects)
        Log.clipboard.info("Clipboard restored (\(restoredObjects.count, privacy: .public) items)")
    }

    // MARK: - Restoration timing

    /// Bundle-ID prefixes of browsers. Their web content runs in a separate
    /// renderer process that reads the pasteboard asynchronously.
    private static let browserBundlePrefixes: [String] = [
        "com.google.Chrome",        // Chrome, Beta, Dev, Canary
        "company.thebrowser.",      // Arc, Dia
        "com.brave.Browser",        // Brave (+ Beta, Nightly)
        "com.microsoft.edgemac",    // Edge (+ Beta, Dev, Canary)
        "org.mozilla.",             // Firefox, Developer Edition, Nightly
        "com.apple.Safari",         // Safari, Safari Technology Preview
        "org.chromium.Chromium",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "app.zen-browser.",
        "com.kagi.kagimacOS",       // Orion
    ]

    /// Known slow pasters, as a backstop for when the Electron framework
    /// check below misses (non-standard bundle layout, WebView2-style apps,
    /// JVM-based IDEs).
    private static let slowBundlePrefixes: [String] = [
        "com.tinyspeck.slackmacgap",    // Slack
        "com.microsoft.VSCode",         // VS Code (+ Insiders)
        "com.hnc.Discord",              // Discord
        "notion.id",                    // Notion
        "com.todesktop.",               // Cursor and other ToDesktop builds
        "com.microsoft.teams",          // Teams (classic + new)
        "md.obsidian",                  // Obsidian
        "com.figma.Desktop",            // Figma
        "com.jetbrains.",               // JetBrains IDEs (JVM)
    ]

    /// Electron detection results, keyed by bundle path (bundles don't
    /// change identity while running, and this avoids a stat per dictation).
    private var electronCache: [String: Bool] = [:]

    private func isElectronApp(_ app: NSRunningApplication) -> Bool {
        guard let bundleURL = app.bundleURL else { return false }
        if let cached = electronCache[bundleURL.path] { return cached }
        let framework = bundleURL
            .appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        let isElectron = FileManager.default.fileExists(atPath: framework.path)
        electronCache[bundleURL.path] = isElectron
        return isElectron
    }

    private func isSlowPaster(_ app: NSRunningApplication) -> Bool {
        if let bundleID = app.bundleIdentifier {
            if Self.browserBundlePrefixes.contains(where: { bundleID.hasPrefix($0) }) { return true }
            if Self.slowBundlePrefixes.contains(where: { bundleID.hasPrefix($0) }) { return true }
        }
        return isElectronApp(app)
    }

    /// The restore delay for the app that will receive the paste.
    private func effectiveRestorationDelay(for app: NSRunningApplication) -> Duration {
        isSlowPaster(app) ? max(slowAppRestorationDelay, restorationDelay) : restorationDelay
    }

    // MARK: - Injection

    /// Writes `text` to the clipboard and pastes it into the origin app.
    ///
    /// Returns once the keystroke has been posted; the clipboard restore runs
    /// later in the background (see `restorationDelay`).
    ///
    /// - Parameters:
    ///   - text: final, non-empty transcript.
    ///   - origin: the application that was frontmost when dictation began.
    func inject(text: String, origin: NSRunningApplication) async -> InjectionOutcome {
        // 1) Never inject into (or monitor around) secure input contexts.
        if IsSecureEventInputEnabled() {
            Log.clipboard.info("Injection aborted: Secure Event Input active")
            return .keptOnClipboard(reason: "secure input")
        }

        let pasteboard = NSPasteboard.general

        // 2) Snapshot the user's clipboard (may be unreadable — tolerated).
        //    If a previous injection's restore is still pending and the
        //    clipboard still holds that injection's transcript, take over its
        //    intended final contents instead of snapshotting our own text.
        let snapshot: Snapshot?
        if let previous = pendingRestore {
            previous.task.cancel()
            pendingRestore = nil
            if pasteboard.changeCount == previous.ownedChangeCount {
                Log.clipboard.info("Previous restore still pending — carrying its clipboard forward")
                snapshot = previous.settledContents
            } else {
                snapshot = snapshotClipboard()
            }
        } else {
            snapshot = snapshotClipboard()
        }

        // 3) Write the transcript and record the pasteboard state we own.
        pasteboard.clearContents()
        pasteboard.writeObjects([text as NSString])
        // nspasteboard.org convention: clipboard managers skip transient
        // items, so every dictation doesn't pile up in their history.
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let ownedChangeCount = pasteboard.changeCount

        // Let the new pasteboard generation settle before the keystroke lands.
        try? await Task.sleep(for: pasteSettleDelay)

        // 4) Decide the delivery route from the CURRENT frontmost app.
        let current = NSWorkspace.shared.frontmostApplication
        let sameApp = current?.processIdentifier == origin.processIdentifier

        if sameApp {
            await pasteSequence(pid: nil)
        } else {
            Log.clipboard.info("Frontmost changed since dictation started — posting to origin PID")
            await pasteSequence(pid: origin.processIdentifier)
        }

        // 5) Give the destination app time to consume the paste, then
        //    6) restore the original clipboard only when nothing else wrote to
        //    it meanwhile. On the PID route we deliberately keep the
        //    transcript on the clipboard instead of restoring, as a safety net.
        //    Both routes receive the paste in `origin`, so its timing applies.
        let delay = effectiveRestorationDelay(for: origin)
        Log.clipboard.info("Clipboard restore scheduled in \(String(describing: delay), privacy: .public)")

        let settled: Snapshot?
        if sameApp {
            settled = snapshot
        } else {
            settled = ([[(NSPasteboard.PasteboardType.string.rawValue, Data(text.utf8))]], 0)
        }

        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            // A newer injection cancelled us and took over `settledContents`.
            guard !Task.isCancelled, let self else { return }
            self.pendingRestore = nil
            if sameApp {
                self.restoreIfUnchanged(snapshot, ownedState: ownedChangeCount)
            } else {
                // The kept copy is the safety net, so it must not be transient:
                // rewrite it plain, unless something else has claimed the clipboard.
                if pasteboard.changeCount == ownedChangeCount {
                    pasteboard.clearContents()
                    pasteboard.writeObjects([text as NSString])
                }
                Log.clipboard.info("Clipboard restoration skipped: transcript kept for origin app delivery")
            }
        }
        pendingRestore = PendingRestore(task: task, ownedChangeCount: ownedChangeCount, settledContents: settled)

        return sameApp ? .injected : .injectedToOriginalApp
    }

    // MARK: - Synthetic keystroke

    /// Posts the keyUp half of the Cmd+V pair after the inter-key gap.
    /// Called from an async context so the main thread never blocks.
    private func postCommandVKeyUp(keyCode: CGKeyCode, pid: pid_t?) async {
        try? await Task.sleep(for: keystrokeGap)
        postKeyEvent(virtualKey: keyCode, keyDown: false, pid: pid)
    }

    /// Full paste sequence: keyDown, short gap, keyUp. Never emits keyDown alone.
    /// The key code is resolved once so both halves use the same key.
    private func pasteSequence(pid: pid_t?) async {
        let keyCode = PasteKeyResolver.keyCodeForV()
        postKeyEvent(virtualKey: keyCode, keyDown: true, pid: pid)
        await postCommandVKeyUp(keyCode: keyCode, pid: pid)
    }

    /// Constructs and posts one synthetic event with the Command flag set.
    /// `pid == nil` posts to the HID tap (delivered to keyboard focus); a pid
    /// posts directly to that application's event queue.
    private func postKeyEvent(virtualKey: CGKeyCode, keyDown: Bool, pid: pid_t?) {
        let event = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: virtualKey,
            keyDown: keyDown
        )
        guard let event else { return }
        event.flags = CGEventFlags.maskCommand
        if let pid {
            event.postToPid(pid)
        } else {
            event.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - Layout-aware ⌘V

/// Finds the virtual key code that produces "v" with ⌘ held in the current
/// keyboard layout.
///
/// Virtual key codes are physical positions: `kVK_ANSI_V` is where V sits on
/// QWERTY. On Dvorak that position types "k", on Colemak/AZERTY etc. other
/// layouts move V too, so a hard-coded `kVK_ANSI_V` + ⌘ becomes a different
/// shortcut. We therefore translate each key code through the active layout's
/// `uchr` data and pick the one that yields "v".
///
/// Translation uses the layout's ⌘ modifier table first, because that is the
/// table AppKit consults when matching ⌘ shortcuts. This also makes
/// non-Latin layouts (Russian, Greek, …) whose ⌘ table maps to Latin QWERTY
/// resolve correctly. Falls back to `kVK_ANSI_V` when nothing types "v"
/// (e.g. a layout without `uchr` data or without Latin letters).
///
/// Limitations: "Dvorak – QWERTY ⌘"-style layouts switch to QWERTY
/// positions while ⌘ is held; they're special-cased to `kVK_ANSI_V` by
/// ID/name in case the layout's ⌘ table doesn't express it. Apps that match
/// shortcuts by raw key code rather than by character (some games, remote
/// desktop/VM clients, a few Java apps) see the resolved position and may
/// behave as if a different key was pressed. A layout switch between our
/// lookup and the app handling the key is not accounted for.
@MainActor
enum PasteKeyResolver {
    /// Last resolution, keyed by input source ID. The ID is read on every
    /// paste (one cheap TIS call) so a layout change is picked up immediately;
    /// the 128-key scan only reruns when the ID differs.
    /// Keyed by keyboard type too: the same layout can map keys differently
    /// on an ANSI, ISO or JIS keyboard, and users switch between built-in and
    /// external ones.
    private static var cached: (layoutID: String, keyboardType: UInt8, keyCode: CGKeyCode)?

    /// Key code for "v" in the current keyboard layout (main thread only —
    /// Text Input Sources APIs must be called on the main thread).
    static func keyCodeForV() -> CGKeyCode {
        let fallback = CGKeyCode(kVK_ANSI_V)
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
            Log.clipboard.info("Paste key: no current keyboard layout — using kVK_ANSI_V")
            return fallback
        }
        let layoutID = stringProperty(source, kTISPropertyInputSourceID) ?? ""
        let keyboardType = LMGetKbdType()
        if let cached, !layoutID.isEmpty, cached.layoutID == layoutID, cached.keyboardType == keyboardType {
            return cached.keyCode
        }
        let keyCode = keyCode(forLayout: source) ?? fallback
        cached = (layoutID, keyboardType, keyCode)
        Log.clipboard.info("Paste key for layout \(layoutID, privacy: .public): \(keyCode, privacy: .public)")
        return keyCode
    }

    /// Resolves "v" for a specific layout. Returns nil when the layout has no
    /// usable `uchr` data or no key that types "v". Internal for testing with
    /// layouts that aren't currently selected.
    static func keyCode(forLayout source: TISInputSource) -> CGKeyCode? {
        let ansiV = CGKeyCode(kVK_ANSI_V)
        let layoutID = stringProperty(source, kTISPropertyInputSourceID) ?? ""
        let name = stringProperty(source, kTISPropertyLocalizedName) ?? ""
        if layoutID.uppercased().contains("QWERTYCMD") || name.contains("QWERTY ⌘") {
            return ansiV
        }

        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        let keyboardType = UInt32(LMGetKbdType())

        // UCKeyTranslate takes Carbon modifier bits shifted right by 8.
        let commandState = UInt32((cmdKey >> 8) & 0xFF)
        for modifierState in [commandState, 0] {
            // Prefer the QWERTY position when it already types "v".
            if types(layout, keyCode: ansiV, modifierState: modifierState, keyboardType: keyboardType) {
                return ansiV
            }
            for code in CGKeyCode(0)..<CGKeyCode(128)
            where types(layout, keyCode: code, modifierState: modifierState, keyboardType: keyboardType) {
                return code
            }
        }
        return nil
    }

    /// True when `keyCode` with `modifierState` types exactly "v".
    private static func types(
        _ layout: UnsafePointer<UCKeyboardLayout>,
        keyCode: CGKeyCode,
        modifierState: UInt32,
        keyboardType: UInt32
    ) -> Bool {
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
            layout,
            UInt16(keyCode),
            UInt16(kUCKeyActionDown),
            modifierState,
            keyboardType,
            OptionBits(1 << kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &length,
            &chars
        )
        return status == noErr && length == 1 && chars[0] == 0x76 // "v"
    }

    private static func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
}
