import AppKit

/// Read-only view of AppState used by the status bar menu. Keeps the
/// controller decoupled from the concrete app-state type.
@MainActor
protocol StatusInfoProvider: AnyObject {
    /// One-line state summary, e.g. "Dictation Ready".
    var statusTitle: String { get }
    /// Current permission snapshot.
    var permissionState: PermissionState { get }
    /// Extra context line (engine/backend description), may be nil.
    var detailLine: String? { get }
    /// Opens the most relevant System Settings privacy pane.
    func openSettingsRequested()
}

/// Owns the NSStatusItem: a small mic glyph plus the status menu described in
/// the product spec (state line, permission rows, Open Settings, Quit).
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private weak var provider: StatusInfoProvider?

    override private init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
    }

    static func makeController() -> StatusBarController {
        StatusBarController()
    }

    func install(provider: StatusInfoProvider) {
        self.provider = provider

        let button = statusItem.button
        button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "UFlow dictation")
        button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// The menu bar item is secondary now, so it can be switched off entirely
    /// without affecting the window or the global hotkey.
    func setVisible(_ visible: Bool) {
        statusItem.isVisible = visible
    }

    /// Updates the glyph to reflect the current state without rebuilding UI.
    func refreshIcon(isRecording: Bool, isError: Bool) {
        let symbol: String
        switch (isRecording, isError) {
        case (true, _): symbol = "mic.fill"
        case (_, true): symbol = "exclamationmark.triangle"
        default: symbol = "mic"
        }
        statusItem.button?.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: "UFlow dictation"
        )
        statusItem.button?.image?.isTemplate = true
    }

    // MARK: - Menu construction

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        guard let provider else { return }

        let titleItem = NSMenuItem(title: provider.statusTitle, action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        if let detail = provider.detailLine {
            let detailItem = NSMenuItem(title: detail, action: nil, keyEquivalent: "")
            detailItem.isEnabled = false
            menu.addItem(detailItem)
        }

        menu.addItem(.separator())

        for row in provider.permissionState.summaryLines {
            let value = row.granted ? "Granted" : "Missing"
            let item = NSMenuItem(title: "\(row.name): \(value)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let open = NSMenuItem(title: "Open UFlow", action: #selector(openWindowClicked), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let settings = NSMenuItem(
            title: "Settings\u{2026}",
            action: #selector(openSettingsClicked),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        let privacy = NSMenuItem(
            title: "Privacy Settings\u{2026}",
            action: #selector(openPrivacyClicked),
            keyEquivalent: ""
        )
        privacy.target = self
        menu.addItem(privacy)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit UFlow", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Actions

    /// Brings the main window forward, creating it again if it was closed.
    @objc private func openWindowClicked() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // The Window scene was closed; AppKit recreates it on reopen.
            NSApp.sendAction(#selector(NSApplication.arrangeInFront(_:)), to: nil, from: nil)
        }
    }

    /// Opens the app's own Settings scene (Cmd+comma) from AppKit.
    ///
    /// Sending `showSettingsWindow:` down the responder chain *reports success*
    /// and then opens nothing, so the usual fallback never fires and the item
    /// silently does nothing. SwiftUI owns the Settings scene, so the reliable
    /// way in is to fire the app menu's own Settings item.
    @objc private func openSettingsClicked() {
        NSApp.activate(ignoringOtherApps: true)

        if let (menu, index) = Self.settingsMenuItem() {
            menu.performActionForItem(at: index)
            return
        }

        // Only reached if the app menu has not been built yet.
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    /// Locates the Settings item in the application menu. Matched by prefix
    /// because the system titles it "Settings…" on current macOS and
    /// "Preferences…" on older ones, and localizes both.
    private static func settingsMenuItem() -> (NSMenu, Int)? {
        guard let appMenu = NSApp.mainMenu?.item(at: 0)?.submenu else { return nil }
        appMenu.update()
        for (index, item) in appMenu.items.enumerated()
        where item.keyEquivalent == "," && item.keyEquivalentModifierMask == .command {
            return (appMenu, index)
        }
        return nil
    }

    /// The System Settings privacy pane, which is a different thing entirely.
    @objc private func openPrivacyClicked() {
        provider?.openSettingsRequested()
    }

    @objc private func quitClicked() {
        Log.app.info("Quit requested from status menu")
        NSApp.terminate(nil)
    }
}
