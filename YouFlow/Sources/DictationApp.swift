import SwiftUI

/// Application entry point.
///
/// UFlow is a regular app: it has a Dock icon, an app menu, one standard
/// resizable window, and a Settings window on Cmd+comma. The menu bar item is
/// secondary — status and the global hotkey while you are working elsewhere.
@main
struct DictationApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    private var appDelegate

    @ObservedObject private var app = AppState.shared

    var body: some Scene {
        Window("UFlow", id: DictationApp.mainWindowID) {
            MainWindowView()
                .environmentObject(app)
        }
        .defaultSize(width: 1020, height: 720)
        .commands {
            // A dictation app has no documents to make.
            CommandGroup(replacing: .newItem) {}

            CommandMenu("Dictation") {
                Button("Start Recording") { app.startFromWindow() }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(app.isRecording || app.isBusy)

                Button("Stop Recording") { app.stopFromWindow() }
                    .keyboardShortcut(".", modifiers: [.command])
                    .disabled(!app.isRecording)

                Divider()

                Button("Reveal Dictionary File") { Store.reveal(app.dictionary.fileURL) }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(app)
        }
    }

    static let mainWindowID = "uflow.main"
}

/// Application lifecycle coordinator: sets the regular activation policy,
/// installs the secondary menu bar item, and kicks off asynchronous bootstrap
/// (permissions, speech assets, hotkey tap).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusBarController?
    private var menuBarObserver: NSObjectProtocol?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Background agent: menu bar presence, no Dock icon, no activation.
        // Fn+Y must feel like a system feature, not like switching apps.
        // (Snapshot runs stay regular so the capture window behaves normally.)
        #if DEBUG
        NSApp.setActivationPolicy(Snapshot.isActive ? .regular : .accessory)
        #else
        NSApp.setActivationPolicy(.accessory)
        #endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("Application launching")

        #if DEBUG
        CorrectionEngine.selfCheck()
        if CommandLine.arguments.contains("--self-check") { NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--dump-menu") { MenuDump.schedule(); return }
        #endif

        let state = AppState.shared

        // The stores are built during the App struct's init, before NSApp
        // exists, so the appearance stored there could not be applied yet.
        // Now it can.
        state.settings.applyAppearance()

        let controller = StatusBarController.makeController()
        state.attachStatusBar(controller)
        controller.setVisible(state.settings.showMenuBarItem)
        statusController = controller

        // The menu bar item is optional now, so honour the switch.
        menuBarObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak controller] _ in
            MainActor.assumeIsolated {
                controller?.setVisible(AppState.shared.settings.showMenuBarItem)
            }
        }

        // Launch-at-login is what makes Fn+Y "always work": the process is
        // simply there after every reboot, without anyone opening anything.
        state.settings.reconcileLoginItem()

        // SwiftUI orders the main window in at launch. An agent app must not
        // surface a window uninvited, so send it away once it exists. Opening
        // stays possible any time from the menu bar ("Open UFlow") or via
        // `open -a UFlow`, both of which land in `showMainWindow`.
        #if DEBUG
        if !Snapshot.isActive {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { Self.hideMainWindows() }
        }
        #else
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { Self.hideMainWindows() }
        #endif

        #if DEBUG
        if Snapshot.isActive {
            // A snapshot run must not raise permission prompts or touch audio.
            Snapshot.scheduleCapture()
            return
        }
        #endif

        Task { await state.bootstrap() }
    }

    /// Orders every main window off screen without destroying its scene, so a
    /// later "Open UFlow" brings the same window straight back.
    @MainActor private static func hideMainWindows() {
        for window in NSApp.windows where window.canBecomeMain && !(window is NSPanel) {
            window.orderOut(nil)
        }
    }

    /// Brings the main window forward, recreating it if SwiftUI discarded it.
    @MainActor private func showMainWindows() {
        NSApp.activate(ignoringOtherApps: true)
        var shown = false
        for window in NSApp.windows where window.canBecomeMain && !(window is NSPanel) {
            window.makeKeyAndOrderFront(nil)
            shown = true
        }
        if !shown {
            // The scene was never created (or was released); this asks AppKit
            // to restore the app's standard windows.
            NSApp.sendAction(#selector(NSApplication.arrangeInFront(_:)), to: nil, from: nil)
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// Double-clicking the app (or `open -a UFlow`) reveals the window rather
    /// than doing nothing — the one moment surfacing UI is what was asked for.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindows() }
        return true
    }

    /// Closing the window leaves the menu bar item and the global hotkey
    /// running, which is the whole point of keeping one.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

#if DEBUG
/// Writes a PNG of UFlow's own window.
///
/// An app can always draw its own window into a bitmap, so this needs no Screen
/// Recording permission and — unlike ImageRenderer — captures the real thing:
/// scroll views, text fields and all.
///
///     UFLOW_STORE_DIR=/tmp/uflow-snap \
///     UFLOW_SNAPSHOT=/tmp/shot.png UFLOW_SNAPSHOT_TAB=dictionary \
///     UFlow.app/Contents/MacOS/UFlow
enum Snapshot {
    static var path: String? { ProcessInfo.processInfo.environment["UFLOW_SNAPSHOT"] }
    static var isActive: Bool { path != nil }

    static var tab: MainWindowView.Tab {
        ProcessInfo.processInfo.environment["UFLOW_SNAPSHOT_TAB"] == "dictionary" ? .dictionary : .transcriptions
    }

    /// A level for the meter, so a still frame is not a dead needle.
    static var level: Double {
        isActive ? Double(ProcessInfo.processInfo.environment["UFLOW_SNAPSHOT_LEVEL"] ?? "0.62") ?? 0.62 : 0
    }

    @MainActor
    static func scheduleCapture() {
        guard let path else { return }
        switch ProcessInfo.processInfo.environment["UFLOW_SNAPSHOT_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        AppState.shared.seedSampleData()

        Task {
            // Let the window lay out, load fonts, and settle its animations.
            try? await Task.sleep(for: .seconds(2))
            capture(to: path)
            NSApp.terminate(nil)
        }
    }

    @MainActor
    private static func capture(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) && $0.contentView != nil }),
              let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            Log.app.error("Snapshot: no window to capture")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(filePath: path))
        Log.app.info("Snapshot written")
    }
}
#endif

#if DEBUG
/// Prints the main menu, so a menu item can be proved present instead of hunted
/// for by eye. Runs a beat after launch, because SwiftUI fills the menu in then.
///
///     UFLOW_STORE_DIR=/tmp/uflow-store UFlow.app/Contents/MacOS/UFlow --dump-menu
enum MenuDump {
    @MainActor
    static func schedule() {
        Task {
            try? await Task.sleep(for: .seconds(1))
            for menu in NSApp.mainMenu?.items ?? [] {
                menu.submenu?.update()
                print("[\(menu.title)]")
                for item in menu.submenu?.items ?? [] {
                    let modifiers = item.keyEquivalentModifierMask.contains(.command) ? "cmd+" : ""
                    let shortcut = item.keyEquivalent.isEmpty ? "" : "  \(modifiers)\(item.keyEquivalent)"
                    print("    \(item.isSeparatorItem ? "---" : item.title)\(shortcut)")
                }
            }
            NSApp.terminate(nil)
        }
    }
}
#endif
