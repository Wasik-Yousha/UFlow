import AppKit
import Carbon.HIToolbox
import Combine

/// Explicit dictation lifecycle states. Transitions are driven exclusively by
/// AppState; every error path funnels back to a stable state.
enum DictationState: Equatable {
    case initializing
    case ready
    case recording
    case transcribing
    case injecting
    case unavailable(String)
    case error(String)
}

/// The application coordinator. Owns every manager and serializes dictation
/// sessions: at most one session task exists at any moment, duplicate triggers
/// are ignored, and every failure path lands in `.ready` or a recoverable
/// `.error`/`.unavailable` — never stuck mid-recording.
///
/// Concurrency model:
/// - UI state lives on `@MainActor`.
/// - Heavy work runs inside one structured session `Task`, which awaits the
///   isolated `SpeechEngine` actor (itself a second serialization layer).
/// - Hotkey callbacks arrive pre-hopped onto the main thread by HotkeyManager.
@MainActor
final class AppState: ObservableObject, StatusInfoProvider {
    /// One coordinator per process. The SwiftUI scenes and the AppKit delegate
    /// both need it, and threading it between them buys nothing.
    static let shared = AppState()

    // MARK: - Owned components

    let permissionManager = PermissionManager()
    let transcripts = TranscriptStore()
    let dictionary = DictionaryStore()
    let settings = AppSettings()

    private let hotkeyManager = HotkeyManager()
    private let appleEngine = SpeechEngine()
    private let parakeetEngine = ParakeetEngine()

    /// The backend the current preference selects. Both conform to
    /// `TranscriptionEngine`, so the session runner below does not care which
    /// one it is talking to.
    private var engine: any TranscriptionEngine {
        settings.backend.usesParakeet ? parakeetEngine : appleEngine
    }
    private let hud = HUDPanelController()
    private let injector = ClipboardInjector()
    private(set) weak var statusBarController: StatusBarController?

    // MARK: - Published state

    @Published private(set) var state: DictationState = .initializing {
        didSet { statusBarController?.refreshIcon(isRecording: isRecording, isError: isFaulted) }
    }

    /// Microphone level, 0…1, republished from the audio tap. The meter view
    /// applies its own ballistics on top of this.
    @Published private(set) var level: Double = 0

    /// Seconds since the current recording started; drives the counter.
    @Published private(set) var elapsed: TimeInterval = 0

    /// Name of the backend that produced the last transcript, for the history.
    @Published private(set) var engineName = "Apple (streaming)"

    /// 0…1 while a model is downloading, nil otherwise. Parakeet's weights are
    /// ~600 MB, so this is the difference between a progress bar and a hang.
    @Published private(set) var modelDownloadProgress: Double?

    /// Whether Parakeet's weights are already on disk. Mirrored into a
    /// published property because the on-disk check is a plain filesystem
    /// look and would never tell SwiftUI it had changed.
    @Published private(set) var parakeetModelIsDownloaded = ParakeetEngine.modelsAreDownloaded

    var isRecording: Bool { state == .recording }
    var isBusy: Bool { state == .transcribing || state == .injecting }
    var isFaulted: Bool {
        if case .error = state { return true }
        if case .unavailable = state { return true }
        return false
    }

    // MARK: - Session bookkeeping

    /// How the chord behaves:
    /// - `.toggle`: tap once to start, talk freely, tap again to stop.
    /// - `.hold`: classic push-to-talk — hold while speaking, release to stop.
    private enum TriggerMode {
        case hold
        case toggle
    }

    /// Where a session was started from. It decides what happens to the text:
    /// a session begun by the hotkey types into whatever app you were in, while
    /// one begun from the window would otherwise type into UFlow itself.
    private enum Origin {
        case hotkey
        case window
    }

    private let triggerMode: TriggerMode = .toggle

    private var sessionTask: Task<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var releasePending = false
    private var isShortPress = false
    private var pressStartedAt: ContinuousClock.Instant?
    private var originApp: NSRunningApplication?
    private var origin: Origin = .hotkey
    private var enginePrepared = false
    private var engineDetailText = "Preparing speech engine…"
    private var elapsedTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    /// Presses shorter than this are treated as accidental taps.
    private static let minimumPressDuration: Duration = .milliseconds(120)

    // MARK: - Init

    init() {
        hotkeyManager.onTriggerDown = { [weak self] in self?.handleTriggerDown() }
        hotkeyManager.onTriggerUp = { [weak self] in self?.handleTriggerUp() }
        hotkeyManager.setTrigger(settings.hotkeyTrigger)

        // SwiftUI does not observe nested ObservableObjects, so a new
        // transcript or dictionary edit would never redraw the window. Forward
        // their change notifications into this object's own.
        for nested in [transcripts.objectWillChange, dictionary.objectWillChange, settings.objectWillChange] {
            nested
                .sink { [weak self] in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }

        // Settings that change live components rather than just being read.
        settings.$modifierKeyCode.combineLatest(settings.$triggerKeyCode)
            .dropFirst()
            .sink { [weak self] modifier, key in
                self?.hotkeyManager.setTrigger(.init(modifierKeyCode: modifier, triggerKeyCode: key))
            }
            .store(in: &cancellables)

        settings.$backend
            .dropFirst()
            .sink { [weak self] preference in
                self?.applyBackend(preference)
            }
            .store(in: &cancellables)
    }

    func attachStatusBar(_ controller: StatusBarController) {
        statusBarController = controller
        controller.install(provider: self)
    }

    var hotkeyDescription: String { settings.hotkeyTrigger.displayName }

    // MARK: - Bootstrap

    /// Launch sequence: permissions → speech assets/module/prewarm → hotkey.
    /// Never bombards prompts: each system dialog appears at most once per launch.
    func bootstrap() async {
        state = .initializing
        Log.app.info("Bootstrap started")

        SoundKit.warmUp()
        await appleEngine.setPreference(settings.backend)

        permissionManager.refresh()
        _ = await permissionManager.requestMicrophoneIfNeeded()
        _ = await permissionManager.requestListenEventAccessIfNeeded()
        _ = await permissionManager.requestPostEventAccessIfNeeded()
        permissionManager.promptAccessibilityIfNeeded()

        // Engine preparation only requires the microphone — decoupled from
        // event-tap permissions so speech assets download even while the user
        // is still approving Input Monitoring.
        if permissionManager.state.microphoneGranted {
            await prepareEngineIfPossible()
        }

        if hotkeyManager.install() {
            if case .initializing = self.state {
                if enginePrepared && permissionManager.state.allGranted {
                    state = .ready
                } else if !enginePrepared {
                    state = .unavailable(engineDetailText)
                } else {
                    let missing = permissionManager.state.missingBlockingNames.joined(separator: ", ")
                    state = .unavailable("Grant \(missing) in System Settings, then restart UFlow")
                }
            }
        } else {
            state = .unavailable("Input Monitoring permission required")
        }
        Log.app.info("Bootstrap finished in state \(String(describing: self.state), privacy: .public)")
    }

    /// Fetch Parakeet's weights on demand, so Settings can offer the download
    /// as a deliberate act instead of having 600 MB start silently the first
    /// time someone presses the hotkey.
    func downloadParakeetModel() {
        guard settings.backend.usesParakeet, modelDownloadProgress == nil else { return }
        Task { await prepareEngineIfPossible() }
    }

    private func prepareEngineIfPossible() async {
        do {
            let usingParakeet = settings.backend.usesParakeet
            try await engine.prepare(progressHandler: { [weak self] fraction in
                Task { @MainActor in
                    let percent = Int(fraction * 100)
                    self?.engineDetailText = usingParakeet
                        ? "Downloading Parakeet model… \(percent)%"
                        : "Downloading speech model… \(percent)%"
                    self?.modelDownloadProgress = fraction < 1 ? fraction : nil
                }
            })
            enginePrepared = true
            modelDownloadProgress = nil
            parakeetModelIsDownloaded = ParakeetEngine.modelsAreDownloaded
            engineDetailText = "On-device English transcription"
            engineName = await engine.activeBackendName
            Log.speech.info("Engine prepared")
        } catch {
            enginePrepared = false
            modelDownloadProgress = nil
            parakeetModelIsDownloaded = ParakeetEngine.modelsAreDownloaded
            engineDetailText = "Engine unavailable"
            if case .initializing = state {
                state = .unavailable(error.localizedDescription)
            }
            Log.speech.error("Engine preparation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Applies a backend change from Settings. The engine drops its prepared
    /// state, so preparation has to be redone before the next session.
    private func applyBackend(_ preference: BackendPreference) {
        enginePrepared = false
        engineDetailText = "Switching model…"
        Task {
            await appleEngine.setPreference(preference)
            await prepareEngineIfPossible()
            if enginePrepared, case .unavailable = state { state = .ready }
        }
    }

    // MARK: - Transport (window)

    /// Start from the main window. The text lands in the history rather than
    /// being typed anywhere.
    func startFromWindow() {
        guard sessionTask == nil else { return }
        SoundKit.play(.recordDown)
        begin(from: .window)
    }

    func stopFromWindow() {
        guard sessionTask != nil else { return }
        SoundKit.play(.stopDown)
        guard state == .recording else { return }
        isShortPress = false
        signalRelease()
    }

    // MARK: - Trigger handling

    private func handleTriggerDown() {
        // Toggle mode: a second tap while recording stops the session.
        if triggerMode == .toggle, sessionTask != nil {
            if state == .recording {
                Log.hotkey.info("Toggle: second tap — stopping session")
                SoundKit.play(.stopDown)
                isShortPress = false
                signalRelease()
            } else {
                Log.hotkey.info("Toggle tap ignored: session already finalizing")
            }
            return
        }

        guard sessionTask == nil else {
            Log.hotkey.info("Trigger DOWN ignored: session already running")
            return
        }
        begin(from: .hotkey)
    }

    /// Shared entry point for both the hotkey and the window's RECORD key.
    private func begin(from origin: Origin) {
        // Secure Event Input: fail completely silent. No recording, no HUD,
        // no keystroke synthesis around password fields.
        if origin == .hotkey, IsSecureEventInputEnabled() {
            Log.hotkey.info("Trigger DOWN ignored: Secure Event Input active")
            return
        }

        permissionManager.refresh()
        guard permissionManager.state.allGranted || origin == .window else {
            let missing = permissionManager.state.missingBlockingNames.joined(separator: ", ")
            state = .unavailable("Permission missing: \(missing)")
            Log.hotkey.info("Trigger DOWN ignored: missing permissions (\(missing, privacy: .public))")
            return
        }
        guard permissionManager.state.microphoneGranted else {
            state = .unavailable("Microphone access is required")
            SoundKit.play(.error)
            return
        }

        self.origin = origin
        originApp = origin == .hotkey ? NSWorkspace.shared.frontmostApplication : nil
        pressStartedAt = ContinuousClock.now
        isShortPress = false
        releasePending = false

        if origin == .hotkey { SoundKit.play(.recordDown) }

        state = .recording
        startElapsedClock()
        sessionTask = Task { [weak self] in
            await self?.runSession()
        }
    }

    private func handleTriggerUp() {
        guard sessionTask != nil else {
            Log.hotkey.info("Trigger UP ignored: no active session")
            return
        }

        // In toggle mode the UP edge merely completes the starting tap; the
        // session keeps recording until the next tap arrives.
        guard triggerMode == .hold else { return }

        if let started = pressStartedAt,
           ContinuousClock.now - started < Self.minimumPressDuration {
            isShortPress = true
        }

        signalRelease()
    }

    /// Wakes the waiting session task exactly once per press.
    private func signalRelease() {
        if let waiter = releaseWaiter {
            releaseWaiter = nil
            waiter.resume()
        } else {
            // Release arrived before the session began waiting (very fast tap);
            // remember it so the wait resolves immediately later.
            releasePending = true
        }
    }

    // MARK: - Elapsed clock

    private func startElapsedClock() {
        elapsed = 0
        elapsedTimer?.invalidate()
        let started = Date()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.elapsed = Date().timeIntervalSince(started) }
        }
    }

    private func stopElapsedClock() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        level = 0
    }

    // MARK: - Session runner

    private func runSession() async {
        let startedAt = Date()
        defer {
            sessionTask = nil
            originApp = nil
            pressStartedAt = nil
            releaseWaiter = nil
            releasePending = false
            stopElapsedClock()
        }

        do {
            // On-demand engine preparation (first press after failed bootstrap,
            // or straight after a model change in Settings).
            if !enginePrepared {
                Log.hotkey.info("Engine not prepared — attempting quick prepare on demand")
                await prepareEngineIfPossible()
                guard enginePrepared else {
                    state = .unavailable(engineDetailText)
                    SoundKit.play(.error)
                    return
                }
            }

            // Bias the engine with the dictionary before it hears anything.
            // Short list by design — see DictionaryStore.biasTerms.
            await engine.setBiasTerms(dictionary.biasTerms())

            // The floating HUD is for when the user is working in another app.
            // The window has its own meter.
            if origin == .hotkey { hud.showRecording() }

            try await engine.startRecording { [weak self] level in
                Task { @MainActor in
                    self?.level = Double(level)
                    if self?.origin == .hotkey { self?.hud.push(level: CGFloat(level)) }
                }
            }

            // Wait for the stop signal (or resolve instantly if it already came).
            if releasePending {
                releasePending = false
            } else {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    releaseWaiter = continuation
                }
            }

            if isShortPress || Task.isCancelled {
                Log.speech.info("Short press detected — discarding session")
                hud.hide()
                await engine.cancelSession()
                state = .ready
                return
            }

            state = .transcribing
            if origin == .hotkey { hud.showTranscribing() }
            let rawText = await engine.stopRecordingAndCollect()
            hud.hide()

            // The dictionary's guaranteed pass.
            let (finalText, corrections) = CorrectionEngine.apply(dictionary.ruleset, to: rawText)

            guard !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // Empty dictation: touch nothing, return to ready.
                Log.speech.info("Empty transcript — clipboard untouched")
                state = .ready
                return
            }

            transcripts.add(
                TranscriptRecord(
                    date: startedAt,
                    engine: engineName,
                    duration: Date().timeIntervalSince(startedAt),
                    text: finalText,
                    corrections: corrections
                )
            )
            if !corrections.isEmpty {
                Log.app.info("Dictionary applied \(corrections.count, privacy: .public) correction(s)")
            }

            if origin == .hotkey, let origin = originApp {
                state = .injecting
                _ = await injector.inject(text: finalText, origin: origin)
            }
            state = .ready
            SoundKit.play(.keyUp)
            Log.app.info("Session completed")

        } catch {
            Log.app.error("Session failed: \(error.localizedDescription, privacy: .public)")
            hud.hide()
            // Best-effort teardown so the mic is never left running.
            await engine.cancelSession()
            hotkeyManager.resetChordState()
            SoundKit.play(.error)
            state = .error(error.localizedDescription)
        }
    }
}

// MARK: - StatusInfoProvider

extension AppState {
    var statusTitle: String {
        switch state {
        case .initializing: return "Starting…"
        case .ready: return "Dictation Ready"
        case .recording: return "Recording…"
        case .transcribing: return "Transcribing…"
        case .injecting: return "Injecting…"
        case .unavailable(let reason): return "Unavailable — \(reason)"
        case .error(let message): return "Error — \(message)"
        }
    }

    var permissionState: PermissionState {
        permissionManager.state
    }

    var detailLine: String? {
        engineDetailText
    }

    func openSettingsRequested() {
        permissionManager.openRelevantSettingsPane()
    }
}

#if DEBUG
extension AppState {
    /// Fills the stores with the content from the design references so a
    /// snapshot shows a populated interface. Debug builds only, and it writes
    /// into whatever UFLOW_STORE_DIR points at.
    func seedSampleData() {
        guard transcripts.records.isEmpty else { return }
        let now = Date()
        let samples: [(String, TimeInterval, String, [AppliedCorrection], TimeInterval)] = [
            ("Apple (streaming)", 0.16,
             "Okay, testing this now by saying the word Claude Code, let's see if it will actually correctly transcribe Claude Code.",
             [AppliedCorrection(heard: "claude-code", written: "Claude Code", count: 2)], 0),
            ("Apple (streaming)", 0.13,
             "Okay, testing this record now is to see if our murmured YouTube GO! is actually working. How is it going to transcribe GO!?",
             [], 60),
            ("Wispr Flow", 1.91,
             "Okay testing this now with Wispr Flow, with Mac Transcribe, with Parakeet. I'm just going to go on another rant. This is gonna be a quicker rant than the last rant but I'm just gonna keep talking so we can really test the speed of all three of these models. See if Wispr Flow is really that much better.",
             [], 4500),
            ("Parakeet", 0.27, "Short one to check the level meter.", [], 4560),
        ]
        for (engine, duration, text, corrections, ago) in samples {
            transcripts.add(
                TranscriptRecord(date: now.addingTimeInterval(-ago), engine: engine,
                                 duration: duration, text: text, corrections: corrections)
            )
        }
        for entry in [
            DictionaryEntry(kind: .term, match: "Wispr Flow"),
            DictionaryEntry(kind: .term, match: "Parakeet"),
            DictionaryEntry(kind: .term, match: "Murmur"),
            DictionaryEntry(kind: .fix, match: "Vercell", replacement: "Vercel"),
        ] where !dictionary.entries.contains(where: { $0.match == entry.match }) {
            dictionary.add(entry)
        }
    }
}
#endif
