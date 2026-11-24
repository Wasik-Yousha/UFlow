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
        if CommandLine.arguments.contains("--dump-status-menu") { MenuDump.statusMenu(); return }
        if let flag = CommandLine.arguments.firstIndex(of: "--snapshot-hud"), flag + 1 < CommandLine.arguments.count {
            HUDPanelController.snapshot(to: CommandLine.arguments[flag + 1])
            return
        }
        if CommandLine.arguments.contains("--romanize") {
            // stdin lines → BanglaRomanizer, for offline evaluation.
            while let line = readLine() { print(BanglaRomanizer.apply(to: line)) }
            NSApp.terminate(nil)
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--transcribe") {
            FileTranscription.run(Array(CommandLine.arguments[(flag + 1)...]))
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--llm") {
            LLMCheck.run(Array(CommandLine.arguments[(flag + 1)...]))
            return
        }
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

    /// Prints the menu-bar mic menu, picks "Bangla" through it, prints it
    /// again to show the check moved, then restores the user's language.
    @MainActor
    static func statusMenu() {
        let state = AppState.shared
        let controller = StatusBarController.makeController()
        state.attachStatusBar(controller)
        let original = state.settings.language
        let menu = NSMenu()
        func dump(_ title: String) {
            controller.menuNeedsUpdate(menu)
            print("[\(title)]")
            for item in menu.items {
                print("    \(item.isSeparatorItem ? "---" : (item.state == .on ? "✓ " : "  ") + item.title)")
            }
        }
        dump("status menu")
        if let index = menu.items.firstIndex(where: { $0.title == SpeechLanguage.banglaOnly.label }) {
            menu.performActionForItem(at: index)
        }
        dump("after choosing \(SpeechLanguage.banglaOnly.label)")
        print("settings.language = \(state.settings.language.rawValue)")
        state.settings.language = original
        NSApp.terminate(nil)
    }
}
#endif

#if DEBUG
/// `UFlow --transcribe <mode> <file.wav>…` prints what each file would type
/// in that mode (english, banglish, bangla, banglaOnly) and how long it took,
/// then quits. Same engine, models and routing as a live dictation.
enum FileTranscription {
    @MainActor static func run(_ args: [String]) {
        Task {
            let engine = SpeechEngine()
            if let mode = args.first.flatMap(SpeechLanguage.init(rawValue:)) { await engine.setLanguage(mode) }
            do {
                try await engine.prepare()
                for path in args.dropFirst() {
                    let started = ContinuousClock.now
                    let text = try await engine.transcribe(file: URL(filePath: path))
                    let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
                    print("\(path)\t\(ms)ms\t\(FillerFilter.apply(to: text))")
                    fflush(stdout)
                }
            } catch {
                print("ERROR \(error.localizedDescription)")
            }
            NSApp.terminate(nil)
        }
    }
}
#endif

#if DEBUG
/// `UFlow --llm <e2b|e4b|e12b> "<text>"… [--wav <file.wav>]` loads that
/// clean-up model (downloading it first if it is missing), runs each text
/// through one generation with a trivial prompt, and prints the reply, load
/// and generation times and memory, then unloads and loads again (warm).
/// With `--wav`, Whisper (banglish) transcribes the file in the same process
/// before and while the model is loaded: two ggml copies side by side.
///
/// Other modes (debug builds only):
///   --prompt p.json --cases c.json   a real prompt over many dictations, timed
///   --wait-pressure <s>              unload on memory pressure (else simulated)
///   --cancel-after <s>               start the download, press Cancel
///   --delete                         remove the model file
/// Point UFLOW_STORE_DIR somewhere disposable for the last two.
enum LLMCheck {
    static let system = "Add punctuation. Output only the text."

    @MainActor static func run(_ arguments: [String]) {
        var args = arguments
        func option(_ name: String) -> String? {
            guard let flag = args.firstIndex(of: name), flag + 1 < args.count else { return nil }
            defer { args.removeSubrange(flag...(flag + 1)) }
            return args[flag + 1]
        }
        let wav = option("--wav")
        let promptFile = option("--prompt")
        let casesFile = option("--cases")
        guard let name = args.first, let model = CleanupModel(rawValue: name) else {
            print("usage: --llm <e2b|e4b|e12b> \"text\"… [--wav file.wav] [--prompt p.json --cases c.json]")
            NSApp.terminate(nil)
            return
        }
        if let after = option("--cancel-after").flatMap(Double.init) {
            // Starts the download and presses Cancel after `after` seconds.
            Task {
                let llm = LocalLLM(model: model)
                let fraction = LastValue(0.0)
                let download = Task { try await llm.prepare { _ = fraction.swap($0) } }
                try? await Task.sleep(for: .seconds(after))
                llm.cancelDownload()
                let started = ContinuousClock.now
                let outcome: String
                do { try await download.value; outcome = "finished?!" } catch { outcome = "\(type(of: error))" }
                print("cancelled at \(Int(fraction.swap(0) * 1000) / 10)% → \(outcome) after \(seconds(since: started)); "
                      + "downloaded=\(model.isDownloaded) bytes on disk=\(model.downloadedBytes)")
                NSApp.terminate(nil)
            }
            return
        }
        if args.contains("--verify") {
            Task {
                let llm = LocalLLM(model: model)
                let started = ContinuousClock.now
                let ok = await llm.verifyInstalled()
                print("sha256 \(ok ? "OK" : "MISMATCH") in \(seconds(since: started)); memory: \(memory())")
                NSApp.terminate(nil)
            }
            return
        }
        if args.contains("--delete") {
            let llm = LocalLLM(model: model)
            print("before: downloaded=\(llm.isDownloaded) bytes=\(llm.downloadedBytes)")
            do { try llm.delete() } catch { print("delete ERROR \(error.localizedDescription)") }
            print("after: downloaded=\(llm.isDownloaded) bytes=\(llm.downloadedBytes)")
            NSApp.terminate(nil)
            return
        }
        if let wait = option("--wait-pressure").flatMap(Double.init) {
            // Loads, then waits for a memory-pressure event to unload it
            // (simulate one with `memory_pressure -S -l warn`).
            Task {
                let llm = LocalLLM(model: model)
                guard await llm.loadNow() else { print("load FAILED"); NSApp.terminate(nil); return }
                print("loaded; waiting up to \(Int(wait)) s for memory pressure (shouldSkip=\(llm.shouldSkip))")
                fflush(stdout)
                let started = ContinuousClock.now
                while llm.isLoaded, ContinuousClock.now - started < .seconds(wait) {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                print(llm.isLoaded ? "still loaded" : "unloaded after \(seconds(since: started)); shouldSkip=\(llm.shouldSkip)")
                if llm.isLoaded {
                    // Mid-generation, as the worst case: it must stop and unload.
                    let generating = Task {
                        await llm.generate(system: system, user: String(repeating: "and then we talked some more ", count: 40),
                                           timeout: .seconds(30))
                    }
                    try? await Task.sleep(for: .milliseconds(300))
                    let fired = ContinuousClock.now
                    llm.simulateMemoryPressure()
                    let reply = await generating.value
                    print("simulated pressure mid-generation → reply \(reply.debugDescription) after \(seconds(since: fired)); "
                          + "loaded=\(llm.isLoaded) shouldSkip=\(llm.shouldSkip)")
                }
                let reply = await llm.generate(system: system, user: "hello there how are you", timeout: .seconds(30))
                print("generate afterwards (reloads): \(reply.debugDescription)")
                withExtendedLifetime(llm) { NSApp.terminate(nil) }
            }
            return
        }
        if let promptFile, let casesFile {
            Task {
                await evaluate(model: model, prompt: URL(filePath: promptFile), cases: URL(filePath: casesFile))
                NSApp.terminate(nil)
            }
            return
        }
        let texts = args.dropFirst().isEmpty
            ? ["so i was thinking we could meet tomorrow at the office around ten and go over the budget numbers before the call"]
            : Array(args.dropFirst())
        Task {
            // The engines must outlive terminate: their willTerminate
            // observers free the models before ggml's exit-time assert.
            let engines = await check(model: model, texts: texts, wav: wav)
            withExtendedLifetime(engines) { NSApp.terminate(nil) }
        }
    }

    private static func check(model: CleanupModel, texts: [String], wav: String?) async -> [AnyObject] {
        print("this Mac: \(ProcessInfo.processInfo.physicalMemory >> 30) GiB → forThisMac() = \(CleanupModel.forThisMac().rawValue)")
        print("model: \(model.displayName)  \(model.fileURL.path)  downloaded=\(model.isDownloaded) (\(model.downloadedBytes) bytes)")
        print("memory at start: \(memory())")
        let speech = wav == nil ? nil : SpeechEngine()
        if let speech, let wav {
            await speech.setLanguage(.banglish)
            do {
                try await speech.prepare()
                let text = try await speech.transcribe(file: URL(filePath: wav))
                print("whisper (before llama): \(text.debugDescription)   memory: \(memory())")
            } catch {
                print("whisper ERROR \(error.localizedDescription)")
            }
        }

        let llm = LocalLLM(model: model)
        let engines: [AnyObject] = [llm] + (speech.map { [$0] } ?? [])
        if !model.isDownloaded {
            let started = ContinuousClock.now
            let last = LastValue(-1)
            do {
                try await llm.prepare { fraction in
                    let percent = Int(fraction * 100)
                    if last.swap(percent) != percent, percent % 5 == 0 { print("  download \(percent)%"); fflush(stdout) }
                }
                print("downloaded + verified in \(seconds(since: started))")
            } catch {
                print("download ERROR \(error.localizedDescription)")
                return engines
            }
        }
        print("shouldSkip: \(llm.shouldSkip)")

        var started = ContinuousClock.now
        guard await llm.loadNow() else { print("load FAILED"); return engines }
        print("load #1: \(seconds(since: started))  gpu=\(llm.usesGPU)  memory: \(memory())")
        print(llm.promptCheck(system: system, user: texts[0]))

        for round in 1...2 {
            for text in texts {
                started = ContinuousClock.now
                let reply = await llm.generate(system: system, user: text, timeout: .seconds(30))
                let stats = llm.lastStats
                print("""
                [round \(round)] \(text.split(separator: " ").count) words → \(seconds(since: started)) \
                (prompt \(stats.promptTokens) tok, \(stats.reusedTokens) reused, \(Int(stats.promptMs)) ms; \
                generated \(stats.generatedTokens) tok, \(Int(stats.generateMs)) ms)
                  → \(reply.debugDescription)
                """)
                fflush(stdout)
            }
        }
        print("memory while loaded: \(memory())")

        // A timeout must come back as nil, promptly.
        started = ContinuousClock.now
        let timedOut = await llm.generate(system: system, user: texts[0], timeout: .milliseconds(150))
        print("150 ms timeout → \(timedOut.debugDescription) after \(seconds(since: started))")

        if let speech, let wav {
            do {
                let text = try await speech.transcribe(file: URL(filePath: wav))
                print("whisper (llama loaded): \(text.debugDescription)   memory: \(memory())")
            } catch {
                print("whisper ERROR \(error.localizedDescription)")
            }
        }

        llm.freeNow()
        print("after unload: loaded=\(llm.isLoaded)  memory: \(memory())")
        started = ContinuousClock.now
        _ = await llm.loadNow()
        print("load #2 (warm): \(seconds(since: started))  memory: \(memory())")
        started = ContinuousClock.now
        let again = await llm.generate(system: system, user: texts[0], timeout: .seconds(30))
        print("first generation after reload: \(seconds(since: started)) → \(again.debugDescription)")
        print("memory at end: \(memory())")
        return engines
    }

    /// `--prompt {system, shots: [{user, assistant}]}` and `--cases [{said, raw?}]`:
    /// a realistic prompt over many dictations. Prints each reply and its time,
    /// and how many first lines equal `raw` (a reference model's output).
    private static func evaluate(model: CleanupModel, prompt: URL, cases: URL) async {
        struct Prompt: Decodable { struct Shot: Decodable { let user, assistant: String }; let system: String; let shots: [Shot] }
        struct Case: Decodable { let said: String; let raw: String? }
        guard let p = try? JSONDecoder().decode(Prompt.self, from: Data(contentsOf: prompt)),
              let list = try? JSONDecoder().decode([Case].self, from: Data(contentsOf: cases)) else {
            print("cannot read --prompt / --cases"); return
        }
        let shots = p.shots.map { (user: $0.user, assistant: $0.assistant) }
        let llm = LocalLLM(model: model)
        var started = ContinuousClock.now
        guard await llm.loadNow() else { print("load FAILED"); return }
        print("\(model.displayName): load \(seconds(since: started)), memory: \(memory())")
        var times: [Double] = [], same = 0, compared = 0, failed = 0
        for (i, c) in list.enumerated() {
            started = ContinuousClock.now
            let reply = await llm.generate(system: p.system, shots: shots, user: c.said, timeout: .seconds(30))
            let ms = Double((ContinuousClock.now - started) / .microseconds(1)) / 1000
            times.append(ms)
            let stats = llm.lastStats
            let first = reply.map { String($0.split(separator: "\n", omittingEmptySubsequences: true).first ?? "") }
            if reply == nil { failed += 1 }
            if let raw = c.raw { compared += 1; if first == raw { same += 1 } }
            print("\(i + 1)\t\(Int(ms)) ms\tprompt \(stats.promptTokens) (\(stats.reusedTokens) reused) gen \(stats.generatedTokens)\t"
                  + "\(first == c.raw ? "=" : "≠")\t\(first ?? "nil")")
            fflush(stdout)
        }
        let sorted = times.sorted()
        func pct(_ q: Double) -> Int { Int(sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))]) }
        print("\(list.count) cases: first \(Int(times[0])) ms, median \(pct(0.5)) ms, p90 \(pct(0.9)) ms, max \(Int(sorted.last!)) ms; "
              + "nil \(failed); first line == reference \(same)/\(compared)")
        print("memory: \(memory())")
    }

    private static func seconds(since start: ContinuousClock.Instant) -> String {
        String(format: "%.0f ms", Double((ContinuousClock.now - start) / .microseconds(1)) / 1000)
    }

    /// phys_footprint (what Activity Monitor calls Memory; excludes clean
    /// mmapped file pages), its peak, and resident size (includes them).
    private static func memory() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return "?" }
        func mb(_ bytes: UInt64) -> String { "\(bytes >> 20) MB" }
        return "footprint \(mb(info.phys_footprint)) (peak \(mb(UInt64(info.ledger_phys_footprint_peak)))), resident \(mb(info.resident_size))"
    }
}

/// Lock-protected value for the download progress callback.
private final class LastValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func swap(_ new: Value) -> Value { lock.withLock { defer { value = new }; return value } }
}
#endif
