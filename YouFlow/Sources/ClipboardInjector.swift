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
@MainActor
final class ClipboardInjector {
    /// Delay between the synthetic paste and the clipboard-restore check.
    /// Configurable; 100 ms covers virtually all destination apps.
    var restorationDelay: Duration = .milliseconds(100)

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

    /// Best-effort snapshot of the entire General pasteboard. Returns nil when
    /// macOS privacy rules make the clipboard unreadable — dictation proceeds
    /// regardless; only restoration is skipped.
    private func snapshotClipboard() -> (items: [ItemSnapshot], changeCount: Int)? {
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
    private func restoreIfUnchanged(_ snapshot: (items: [ItemSnapshot], changeCount: Int)?, ownedState: Int) {
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

    // MARK: - Injection

    /// Writes `text` to the clipboard and pastes it into the origin app.
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

        // 2) Snapshot the user's clipboard (may be unreadable — tolerated).
        let snapshot = snapshotClipboard()

        // 3) Write the transcript and record the pasteboard state we own.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([text as NSString])
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

        // 5) Give the destination app time to consume the paste.
        try? await Task.sleep(for: restorationDelay)

        // 6) Restore the original clipboard only when nothing else wrote to it
        //    meanwhile. On the PID route we deliberately keep the transcript on
        //    the clipboard instead of restoring, as a safety net.
        if sameApp {
            restoreIfUnchanged(snapshot, ownedState: ownedChangeCount)
            return .injected
        } else {
            Log.clipboard.info("Clipboard restoration skipped: transcript kept for origin app delivery")
            return .injectedToOriginalApp
        }
    }

    // MARK: - Synthetic keystroke

    /// Posts the keyUp half of the Cmd+V pair after the inter-key gap.
    /// Called from an async context so the main thread never blocks.
    private func postCommandVKeyUp(pid: pid_t?) async {
        try? await Task.sleep(for: keystrokeGap)
        postKeyEvent(virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false, pid: pid)
    }

    /// Full paste sequence: keyDown, short gap, keyUp. Never emits keyDown alone.
    private func pasteSequence(pid: pid_t?) async {
        postKeyEvent(virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true, pid: pid) // 0x09
        await postCommandVKeyUp(pid: pid)
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
