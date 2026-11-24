import AVFAudio
import AppKit
import CoreAudio
import CoreMedia
import Foundation
import Speech

/// One-shot rendezvous used by the speech shutdown watchdog. This is an actor
/// rather than a structured task group because a task group cannot leave its
/// scope until *all* children finish. If one child is waiting on a wedged
/// SpeechAnalyzer operation, that rule turns the supposed timeout into another
/// indefinite wait.
private actor CompletionRace {
    private var result: Bool?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func resolve(with value: Bool) {
        guard result == nil else { return }
        result = value
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: value) }
    }

    func value() async -> Bool {
        if let result { return result }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

// MARK: - Result text extraction

/// Unifies the result types of SpeechTranscriber and DictationTranscriber so a
/// single consumption path can drain either backend's results stream.
protocol TextualSpeechResult: SpeechModuleResult {
    var text: AttributedString { get }
}

extension SpeechTranscriber.Result: TextualSpeechResult {}
extension DictationTranscriber.Result: TextualSpeechResult {}

// MARK: - Accumulator

/// Thread-safe transcript accumulation across the results consumer task and the
/// owning engine actor. Finalized chunks are appended permanently; volatile
/// (still-revisable) tails are tracked separately and never injected.
///
/// Only deterministic whitespace normalization is applied. Apple's native
/// punctuation/capitalization output is preserved verbatim.
final class TranscriptAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var finalizedParts: [String] = []
    private var volatileTail = ""
    private var confidenceSum = 0.0
    private var confidenceWeight = 0
    private var finalizedWords: [AppleWord] = []
    private var finalizedSpans: [AppleSpan] = []

    func append(_ rawText: String, isFinal: Bool, confidence: (sum: Double, weight: Int) = (0, 0),
                words: [AppleWord] = [], spans: [AppleSpan] = []) {
        let text = String(rawText)
        lock.lock()
        defer { lock.unlock() }
        if isFinal {
            finalizedParts.append(text)
            volatileTail = ""
            confidenceSum += confidence.sum
            confidenceWeight += confidence.weight
            finalizedWords += words
            finalizedSpans += spans
        } else {
            volatileTail = text
        }
    }

    /// Character-weighted mean of the finalized results' confidence, nil when
    /// the model reported none.
    func meanConfidence() -> Double? {
        lock.withLock { confidenceWeight > 0 ? confidenceSum / Double(confidenceWeight) : nil }
    }

    /// Finalized words with the model's confidence in each.
    func words() -> [AppleWord] { lock.withLock { finalizedWords } }

    /// Seconds into the recording where Apple heard its words.
    func spans() -> [AppleSpan] { lock.withLock { finalizedSpans } }

    /// Assembled transcript from finalized results only.
    func finalText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return Self.normalize(Self.join(finalizedParts))
    }

    /// Live view (finalized + volatile) — usable for HUD previews; never injected.
    func currentText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return Self.normalize(Self.join(finalizedParts + [volatileTail]))
    }

    /// Joins Apple's result chunks. Most carry their own leading space, but a
    /// chunk that starts after a pause often doesn't, and plain concatenation
    /// typed "something elseSo," and "detect that?Problem". A space goes in
    /// wherever two words meet (letter or digit on both sides, or the end of a
    /// clause before one) — never before punctuation (", " / "'s"), which is
    /// why a blanket separator corrupts boundaries, and never between digits.
    static func join(_ parts: [String]) -> String {
        var out = ""
        for part in parts {
            if let last = out.last, let first = part.first,
               !last.isWhitespace, !first.isWhitespace,
               first.isLetter || first.isNumber {
                // Digits touching digits are one number. A digit after ". , :"
                // is not: Apple splits results at pauses, so "5." + "10 more"
                // is two sentences far more often than "3." + "14" is a number.
                let insideNumber = first.isNumber && last.isNumber
                if !insideNumber, last.isLetter || last.isNumber || ".!?,;:".contains(last) {
                    out += " "
                }
            }
            out += part
        }
        return out
    }

    /// Deterministic cleanup only: trim, collapse runs of whitespace, drop
    /// duplicate blank lines. No vocabulary changes of any kind.
    static func normalize(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// A stretch of the recording and how many words Apple wrote for it.
struct AppleSpan: Sendable {
    let time: ClosedRange<Double>
    let words: Int
}

/// One word of Apple's transcript and how sure its model was of it.
struct AppleWord: Sendable, Equatable {
    let text: String
    let confidence: Double
}

/// Apple's transcript of one recording.
struct AppleTranscript: Sendable {
    var text = ""
    var confidence: Double?
    var words: [AppleWord] = []
    /// Seconds into the recording that Apple's words cover.
    var spans: [AppleSpan] = []
}

// MARK: - Errors

/// Error taxonomy for the speech pipeline. Every case maps to a stable,
/// user-safe recovery path in AppState (never a crash).
enum SpeechEngineError: LocalizedError {
    case transcriberUnavailable
    case localeUnsupported
    case assetsUnsupported
    case notPrepared
    case sessionAlreadyActive
    case microphoneFormatUnavailable
    case audioStartFailed(String)
    case analysisFailed(String)

    var errorDescription: String? {
        switch self {
        case .transcriberUnavailable: return "On-device speech transcription is unavailable."
        case .localeUnsupported: return "This language's transcription is not supported on this device."
        case .assetsUnsupported: return "Required speech assets cannot be installed on this device."
        case .notPrepared: return "Speech engine is not prepared yet."
        case .sessionAlreadyActive: return "A dictation session is already running."
        case .microphoneFormatUnavailable: return "Microphone input format is unavailable."
        case .audioStartFailed(let detail): return "Could not start audio capture: \(detail)"
        case .analysisFailed(let detail): return "Transcription failed: \(detail)"
        }
    }
}

// MARK: - Backend preference

/// Which on-device model to transcribe with. Exposed in Settings.
enum BackendPreference: String, CaseIterable, Codable, Sendable {
    /// Prefer the streaming transcriber, fall back automatically.
    case automatic
    /// Force the long-form streaming transcriber.
    case streaming
    /// Force the short-form dictation transcriber.
    case dictation

    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .streaming: "Apple streaming transcriber"
        case .dictation: "Apple dictation transcriber"
        }
    }

    var detail: String {
        switch self {
        case .automatic: "Use the streaming transcriber when this Mac supports it."
        case .streaming: "Best for long dictation. Revises text as you speak."
        case .dictation: "Tuned for short phrases. Use if streaming is unavailable."
        }
    }
}

// MARK: - Language

/// What the user speaks. English runs on Apple's streaming model. Apple ships
/// no Bengali model at all (checked: SpeechTranscriber, DictationTranscriber
/// and SFSpeechRecognizer), so the Bangla modes run on on-device Whisper.
/// The "English +" modes also run Apple's English model alongside, which
/// writes any sentence spoken in English; Bangla only writes everything in
/// Bangla script.
enum SpeechLanguage: String, CaseIterable, Codable, Sendable {
    case english
    case banglish
    case bangla
    case banglaOnly

    var usesWhisper: Bool { self != .english }

    /// Apple's English model listens alongside Whisper and takes the
    /// sentences that were spoken in English.
    var usesEnglishCompanion: Bool { self == .banglish || self == .bangla }

    /// Caption on the recording HUD.
    var shortLabel: String {
        switch self {
        case .english: "EN"
        case .banglish: "Banglish"
        case .bangla: "EN+বাংলা"
        case .banglaOnly: "বাংলা"
        }
    }

    var label: String {
        switch self {
        case .english: "English"
        case .banglish: "English + Banglish"
        case .bangla: "English + Bangla"
        case .banglaOnly: "Bangla"
        }
    }

    var detail: String {
        switch self {
        case .english: "Apple's streaming model. Fastest; English only."
        case .banglish: "English words stay English and Bangla is typed as Banglish, even in the same sentence (\"My name is Yusha mane amar nam iusha\"). One-time 539 MB download; text appears a moment after you let go."
        case .bangla: "English words stay English and Bangla is typed in Bangla script, even in the same sentence (\"My name is Yusha মানে আমার নাম ইউশা\"). One-time 539 MB download; text appears a moment after you let go."
        case .banglaOnly: "Everything is typed in Bangla script, English words included (\"মিটিং\"). One-time 640 MB download; text appears a moment after you let go."
        }
    }
}

// MARK: - Engine

/// Owns Apple's modern on-device speech stack and the microphone capture graph.
///
/// Lifecycle design (latency-critical AND crash-safe):
/// - Launch time: resolve the chosen language's locale once, install required speech
///   assets, and PREWARM model loading with a THROWAWAY module/analyzer pair
///   that is explicitly released afterwards.
/// - Per press-to-talk session: construct a FRESH transcription module plus a
///   fresh lightweight `SpeechAnalyzer`. Framework modules are single-use —
///   binding one live module to a second analyzer traps at runtime — while the
///   expensive underlying models stay resident thanks to
///   `Options(modelRetention: .processLifetime)`, so fresh modules cost
///   nothing measurable and hotkey latency stays instant.
/// - The engine is an actor, structurally preventing overlapping sessions.
actor SpeechEngine {
    /// Freshly-built module set for one session.
    private enum Backend {
        case transcriber(SpeechTranscriber)
        case dictation(DictationTranscriber)

        var modules: [any SpeechModule] {
            switch self {
            case .transcriber(let t): return [t]
            case .dictation(let d): return [d]
            }
        }
    }

    /// Live per-session state.
    private struct ActiveSession {
        let analyzer: SpeechAnalyzer
        let capture: MicCapture
        let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
        let consumerTask: Task<Void, Never>
        let accumulator: TranscriptAccumulator
        let startedAt: ContinuousClock.Instant
        let yielded: YieldCounter
        /// Bangla modes: the same mic audio at 16 kHz for Whisper.
        let collector: SampleCollector?
        /// The mode at key-down; a switch mid-recording applies to the next one.
        let language: SpeechLanguage
    }

    // Preparation results (launch time).
    private var resolvedLocale: Locale?
    private var prefersDictationFallback = false
    private(set) var preparedFormat: AVAudioFormat?

    private var activeSession: ActiveSession?

    /// English + Banglish: record while held, transcribe once on release.
    private struct WhisperSession {
        let capture: MicCapture
        let collector: SampleCollector
        let language: SpeechLanguage
    }

    /// The microphone, started at key-down before the hold is confirmed, so
    /// the first words are not lost. A hold takes it over; a tap discards it.
    private var armed: MicCapture?

    /// Starts capture ahead of a likely session (Fn went down). Idempotent.
    /// ponytail: a capture nobody claims is stopped after `armTimeout`, so a
    /// lost key-up can never leave the microphone on.
    func armMicrophone(token: Int) {
        // A disarm for this press (or a later one) already arrived: the arm
        // lost the race to the actor and must not open the mic.
        guard token > disarmedThrough else { return }
        guard armed == nil, activeSession == nil, whisperSession == nil else { return }
        // A Bluetooth headset's mic is not opened speculatively: opening it
        // switches AirPods & co. from music quality to call quality, which
        // must not happen for a press that might be a tap. Those dictations
        // start the mic at hold confirmation, as before.
        if Self.defaultInputIsBluetooth() {
            Log.speech.info("Bluetooth input — no pre-roll")
            return
        }
        do {
            let capture = try MicCapture()
            armed = capture
            Task { [weak self] in
                try? await Task.sleep(for: Self.armTimeout)
                await self?.disarm(ifStill: capture)
            }
        } catch {
            Log.speech.error("Pre-roll capture failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The press was a tap, or the session never started: drop the audio.
    /// `token`: arms carrying a token up to this one are void from now on.
    func disarmMicrophone(token: Int = 0) {
        disarmedThrough = max(disarmedThrough, token)
        armed?.stop()
        armed = nil
    }
    private var disarmedThrough = 0

    private func disarm(ifStill capture: MicCapture) {
        guard armed === capture else { return }
        Log.speech.info("Pre-roll capture unclaimed — stopping microphone")
        disarmMicrophone()
    }

    private static let armTimeout: Duration = .seconds(5)

    /// Whether the system's default input device is a Bluetooth one.
    static func defaultInputIsBluetooth() -> Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return false }
        var transport = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyTransportType
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// The armed capture if there is one, else a fresh one.
    private func takeCapture() throws -> MicCapture {
        if let capture = armed {
            armed = nil
            // Armed for this press moments ago (~0.2–0.4 s): use it. Older
            // means it was armed for something else; its buffered audio
            // predates this recording, so start clean.
            if ContinuousClock.now - capture.startedAt < Self.freshArm { return capture }
            capture.stop()
        }
        return try MicCapture()
    }
    private static let freshArm: Duration = .milliseconds(1500)
    private let banglaWhisper = WhisperEngine(model: .bangla)
    private let banglishWhisper = WhisperEngine(model: .banglish)
    /// The Whisper model for the current mode.
    private var whisper: WhisperEngine { whisperEngine(for: language) }
    /// Bangla only: the Bangla model (best pure Bangla). Both "English +"
    /// modes: the code-switch model, the only one that keeps English words in
    /// English letters mid-sentence.
    private func whisperEngine(for language: SpeechLanguage) -> WhisperEngine {
        language == .banglaOnly ? banglaWhisper : banglishWhisper
    }
    private var whisperSession: WhisperSession?

    /// Words the analyzer should lean toward. Kept deliberately short by the
    /// caller: a long contextual list makes these models drift and invent text
    /// on quiet audio. Biasing is a nudge — the dictionary's correction pass is
    /// what actually guarantees the spelling.
    private var biasTerms: [String] = []

    /// Which transcription backend the user asked for.
    private var preference: BackendPreference = .automatic

    /// Which language model and bias the user asked for.
    private var language: SpeechLanguage = .english

    var isPrepared: Bool { language.usesWhisper ? whisper.isReady : resolvedLocale != nil }
    var isSessionActive: Bool { activeSession != nil || whisperSession != nil }

    // MARK: - Configuration

    /// Replaces the contextual bias list. Takes effect on the next session.
    func setBiasTerms(_ terms: [String]) {
        biasTerms = terms
        Log.speech.info("Bias list set (\(terms.count, privacy: .public) terms)")
    }

    /// Chooses the backend. Changing it discards preparation so the next
    /// session rebuilds against the newly requested model.
    func setPreference(_ newValue: BackendPreference) {
        guard newValue != preference else { return }
        preference = newValue
        resolvedLocale = nil
        preparedFormat = nil
        Log.speech.info("Backend preference set to \(newValue.rawValue, privacy: .public)")
    }

    /// Chooses the language. Same rebuild rule as the backend.
    func setLanguage(_ newValue: SpeechLanguage) {
        guard newValue != language else { return }
        // ~600 MB back now rather than in 5 min — unless the new mode runs
        // the same model (English + Bangla ↔ English + Banglish).
        if !isSessionActive, language.usesWhisper,
           !newValue.usesWhisper || whisperEngine(for: newValue) !== whisper {
            whisper.unload()
        }
        language = newValue
        resolvedLocale = nil
        preparedFormat = nil
        Log.speech.info("Language set to \(newValue.rawValue, privacy: .public)")
    }

    /// The backend actually in use, for display.
    var activeBackendName: String {
        if language.usesWhisper { return whisper.isReady ? "Whisper (on-device)" : "Not ready" }
        guard resolvedLocale != nil else { return "Not ready" }
        return prefersDictationFallback ? "Dictation" : "Apple (streaming)"
    }

    // MARK: - Preparation (launch time)

    /// Resolves the locale, ensures assets, and prewarms the model stack using
    /// disposable objects. Intended to run once at application startup.
    ///
    /// - Parameter progressHandler: receives asset download progress (0…1).
    func prepare(progressHandler: (@Sendable (Double) -> Void)? = nil) async throws {
        if language.usesWhisper {
            let requested = language, engine = whisper
            try await engine.prepare(progress: progressHandler)
            // The user switched modes while this downloaded or loaded: that
            // model may not be needed now, and the newer prepare owns the rest.
            guard language == requested else {
                if !language.usesWhisper || whisper !== engine { engine.unload() }
                return
            }
            // Apple's English model listens alongside Whisper and writes the
            // utterances that turn out to be pure English. Optional: without
            // it, Whisper handles everything.
            guard language.usesEnglishCompanion else { return }
            do {
                try await prepareApple(progressHandler: nil)
            } catch {
                Log.speech.notice("English companion unavailable: \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        try await prepareApple(progressHandler: progressHandler)
    }

    private func prepareApple(progressHandler: (@Sendable (Double) -> Void)?) async throws {
        guard resolvedLocale == nil else { return }

        let requestedLocale = Locale(identifier: "en-US")
        let useFallback: Bool
        let locale: Locale

        if preference != .dictation,
           SpeechTranscriber.isAvailable,
           let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) {
            useFallback = false
            locale = resolved
        } else {
            Log.speech.notice("SpeechTranscriber unavailable — falling back to DictationTranscriber")
            guard let resolved = await DictationTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
                throw SpeechEngineError.localeUnsupported
            }
            useFallback = true
            locale = resolved
        }

        // Ensure assets with a throwaway module, then discard it.
        let probeModule: any SpeechModule = useFallback
            ? DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
            : Self.makeTranscriber(locale)
        try await ensureAssets(for: [probeModule], progressHandler: progressHandler)

        // Prewarm model loading with a throwaway backend + analyzer, then
        // release both so no live module carries a lingering analyzer claim.
        let prewarmBackend: Backend = useFallback
            ? .dictation(DictationTranscriber(locale: locale, preset: .progressiveShortDictation))
            : .transcriber(Self.makeTranscriber(locale))
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: prewarmBackend.modules)
        let prewarmAnalyzer = SpeechAnalyzer(
            modules: prewarmBackend.modules,
            options: .init(priority: .userInitiated, modelRetention: .processLifetime)
        )
        try await prewarmAnalyzer.prepareToAnalyze(in: format)
        await prewarmAnalyzer.cancelAndFinishNow()

        resolvedLocale = locale
        prefersDictationFallback = useFallback
        preparedFormat = format
        Log.speech.info("SpeechAnalyzer prewarmed and released (format=\(format?.description ?? "nil", privacy: .public))")
    }

    private func ensureAssets(
        for modules: [any SpeechModule],
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws {
        let status = await AssetInventory.status(forModules: modules)
        guard status != .unsupported else { throw SpeechEngineError.assetsUnsupported }
        guard status != .installed else {
            Log.speech.info("Speech assets already installed")
            return
        }

        Log.speech.info("Speech assets status=\(String(describing: status), privacy: .public) — ensuring installation")
        if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            let observer = request.progress.observe(\.fractionCompleted, options: [.initial]) { progress, _ in
                progressHandler?(progress.fractionCompleted)
            }
            defer { observer.invalidate() }
            try await request.downloadAndInstall()
            Log.speech.info("Speech asset installation completed")
        }
    }

    /// The streaming preset plus per-word confidence, which the Bangla modes
    /// use to tell an English utterance from a Bangla one.
    private static func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        let preset = SpeechTranscriber.Preset.progressiveTranscription
        return SpeechTranscriber(locale: locale,
                                 transcriptionOptions: preset.transcriptionOptions,
                                 reportingOptions: preset.reportingOptions,
                                 attributeOptions: preset.attributeOptions.union([.transcriptionConfidence, .audioTimeRange]))
    }

    /// Builds a fresh module set for a new session. Cheap: the underlying
    /// models remain resident via process-lifetime retention.
    private func makeBackend() throws -> Backend {
        guard let locale = resolvedLocale else { throw SpeechEngineError.notPrepared }
        if prefersDictationFallback {
            return .dictation(DictationTranscriber(locale: locale, preset: .progressiveShortDictation))
        }
        return .transcriber(Self.makeTranscriber(locale))
    }

    // MARK: - Session control

    /// Begins a recording session: starts the results consumer, spins up a
    /// fresh SpeechAnalyzer over an AsyncStream of mic buffers, and opens the
    /// AVAudioEngine input tap.
    /// - Parameter onLevel: receives a normalized microphone level (0…1) per
    ///   audio buffer, for the HUD waveform. Called on the realtime audio
    ///   thread — the handler must hop to its own actor and stay cheap.
    func startRecording(onLevel: (@Sendable (Float) -> Void)? = nil) async throws {
        guard activeSession == nil, whisperSession == nil else { throw SpeechEngineError.sessionAlreadyActive }
        var collector: SampleCollector?
        if language.usesWhisper {
            guard whisper.isReady else { throw SpeechEngineError.notPrepared }
            whisper.preload()
            guard language.usesEnglishCompanion, resolvedLocale != nil else {
                try startWhisperRecording(onLevel: onLevel)
                return
            }
            collector = SampleCollector()
        }
        // Clicks noted for an earlier attempt that never recorded are stale.
        cues.removeAll { ContinuousClock.now - $0 > .seconds(2) }
        // The microphone first (usually already running since key-down):
        // everything below takes time, and speech that arrives meanwhile
        // waits in the capture instead of being lost.
        let capture = try takeCapture()
        var started = false
        defer { if !started { capture.stop() } }
        let hardwareFormat = capture.format

        let backend = try makeBackend()
        let modules = backend.modules

        // Target format requested by the analyzer; convert when necessary.
        let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: modules,
            considering: hardwareFormat
        ) ?? hardwareFormat
        let converter: AVAudioConverter? =
            targetFormat != hardwareFormat ? AVAudioConverter(from: hardwareFormat, to: targetFormat) : nil

        let accumulator = TranscriptAccumulator()

        // Audio flows into the analyzer through this stream. Unbounded buffering
        // keeps realtime capture safe: short dictations hold trivial memory.
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)

        // Start draining results BEFORE any audio is produced — the results
        // sequence only emits while it is actively iterated.
        let consumerTask = Task { [weak self] in
            guard let self else { return }
            switch backend {
            case .transcriber(let t):
                await self.drain(t.results, into: accumulator)
            case .dictation(let d):
                await self.drain(d.results, into: accumulator)
            }
        }

        let analyzer = SpeechAnalyzer(
            modules: modules,
            options: .init(priority: .userInitiated, modelRetention: .processLifetime)
        )
        // Contextual biasing. This is the only thing the dictionary changes
        // about recognition itself; everything else it does happens afterwards.
        if !biasTerms.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = biasTerms
            do {
                try await analyzer.setContext(context)
            } catch {
                // A rejected bias list must never cost the user a recording.
                Log.speech.error("Contextual bias rejected: \(error.localizedDescription, privacy: .public)")
            }
        }

        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            continuation.finish()
            consumerTask.cancel()
            throw SpeechEngineError.analysisFailed(error.localizedDescription)
        }

        // Bangla modes: Whisper hears the same buffers, at its own 16 kHz mono.
        let whisperFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: WhisperEngine.sampleRate,
                                          channels: 1, interleaved: false)!
        let whisperConverter = collector != nil && whisperFormat != hardwareFormat
            ? AVAudioConverter(from: hardwareFormat, to: whisperFormat) : nil

        // Lightweight realtime tap: convert the buffer and yield it onward.
        let counter = YieldCounter()
        // Audio captured before this point is replayed first, in order.
        capture.attach { buffer in
            onLevel?(Self.normalizedLevel(of: buffer))
            if let collector, let mono = Self.converted(buffer, with: whisperConverter, to: whisperFormat),
               let channel = mono.floatChannelData?[0] {
                collector.append(UnsafeBufferPointer(start: channel, count: Int(mono.frameLength)))
            }
            guard let output = Self.converted(buffer, with: converter, to: targetFormat) else { return }
            counter.count += 1
            continuation.yield(AnalyzerInput(buffer: output))
        }
        started = true

        activeSession = ActiveSession(
            analyzer: analyzer,
            capture: capture,
            inputContinuation: continuation,
            consumerTask: consumerTask,
            accumulator: accumulator,
            startedAt: ContinuousClock.now,
            yielded: counter,
            collector: collector,
            language: language
        )
        Log.speech.info("Recording started")
    }

    /// Stops capture, finalizes analyzer input, waits for the stabilized final
    /// transcript, and tears the session down. Returns the final text (possibly
    /// empty — callers decide what to do with that).
    func stopRecordingAndCollect() async -> String {
        let mode = whisperSession?.language ?? activeSession?.language ?? language
        return await finish(await collectScript(), mode: mode)
    }

    /// The transcript in the script it was spoken in (Bangla stays Bangla
    /// script); romanizing for Banglish happens in `finish`, after clean-up.
    private func collectScript() async -> String {
        if let session = whisperSession { return await stopWhisperRecording(session) }
        guard let session = activeSession else { return "" }
        guard let collector = session.collector else { return await finishApple(session).text }

        // Bangla modes: Whisper starts on the recording while Apple finalizes.
        // Apple is done first; when it is sure the speech was English its text
        // goes out without waiting for Whisper.
        session.capture.stop()
        let samples = collector.drain()
        let mode = session.language
        let cue = cueRanges(in: session.capture)
        cues = []
        let whisperTask = Task { await self.transcribeWhisper(samples, mode: mode, ignoring: cue) }
        return await pick(english: await finishApple(session), whisper: whisperTask, samples: samples, mode: mode)
    }

    /// Apple's text when it is sure the speech was English, else Whisper's.
    private func pick(english: AppleTranscript, whisper: Task<String, Never>, samples: [Float],
                      mode: SpeechLanguage) async -> String {
        #if DEBUG
        if ProcessInfo.processInfo.environment["UFLOW_TRACE"] != nil {
            let words = english.words.map { "\($0.text)@\(String(format: "%.2f", $0.confidence))" }.joined(separator: " ")
            let unheard = Self.unheardSpeechSeconds(samples, spans: english.spans)
            FileHandle.standardError.write(Data("WORDS\tmean=\(english.confidence.map { String(format: "%.3f", $0) } ?? "-")\tunheard=\(String(format: "%.2f", unheard))\t\(words)\n".utf8))
        }
        #endif
        if let confidence = english.confidence, confidence >= Self.englishConfidence, !english.text.isEmpty {
            // Apple is sure — about the words it understood. Bangla inside an
            // English sentence it silently drops ("I will send the report
            // কালকে সকালে okay" → "I will send the report. Okay.") or turns
            // into English ("ভাই" → "Bye", "কেমন আছো" → "Camo nacho"), and
            // the remaining English words keep its confidence high. So Whisper
            // gets a short wait to say whether it heard Bangla too; if it did,
            // the sentence is mixed and goes the mixed route (Whisper's words,
            // Apple's English spellings).
            // Only when there are signs of it, so pure English stays instant:
            // speech Apple wrote no word for (dropped Bangla), or a doubtful
            // word before the last (Bangla turned into English; the last word
            // of a sentence is often doubtful anyway).
            let doubtful = english.words.dropLast().contains { $0.confidence < Self.doubtfulWord }
                || Self.unheardSpeechSeconds(samples, spans: english.spans) >= Self.unheardSpeech
            if doubtful, let heard = await Self.value(of: whisper, within: Self.mixedCheckWait),
               Self.banglaWordCount(heard) >= 2 {
                Log.speech.info("Apple sure (\(confidence, privacy: .public)) but Whisper heard Bangla too — mixed sentence")
                return route(heard: heard, english: english, mode: mode)
            }
            // Stop a decode that ran over, or the next dictation queues
            // behind it (measured: a Bangla clip after three English ones
            // waited 12.7 s instead of ~1.4 s).
            whisper.cancel()
            Log.speech.info("Routed to Apple (confidence \(confidence, privacy: .public))")
            return english.text
        }
        // Short replies ("no", "cool", "got it") get less confidence from
        // Apple than sentences, and the Bangla model turns them into Bangla
        // ("no" → "nao"). A lower bar is safe only when every word Apple
        // heard is a real English word and none of them is a common Bangla
        // word that also spells as English ("bolo", "ki").
        if let confidence = english.confidence, confidence >= Self.shortEnglishConfidence,
           await Self.isShortEnglish(english.text) {
            whisper.cancel()
            Log.speech.info("Routed to Apple: short English reply (confidence \(confidence, privacy: .public))")
            return english.text
        }
        Log.speech.info("Routed to Whisper (Apple confidence \(english.confidence ?? -1, privacy: .public), \(english.words.count, privacy: .public) words)")
        return route(heard: await whisper.value, english: english, mode: mode)
    }

    /// A word Apple is less sure of than this, before the sentence's last
    /// word, suggests it is English Apple made up for Bangla ("Bye" for ভাই
    /// 0.64, "Camo" for কেমন 0.67). Pure English mid-sentence words: ≥ 0.69.
    private static let doubtfulWord = 0.70

    /// This much speech with no Apple word over it means Apple dropped
    /// something it couldn't understand — usually Bangla.
    private static let unheardSpeech = 0.35

    /// Seconds of clearly spoken audio (16 kHz samples) that no Apple word
    /// covers. Words are given a little slack on both sides, since Apple's
    /// timings are tight and speech trails off.
    static func unheardSpeechSeconds(_ samples: [Float], spans: [AppleSpan],
                                     rate: Double = WhisperEngine.sampleRate) -> Double {
        guard !spans.isEmpty, !samples.isEmpty else { return 0 }
        let window = Int(rate * 0.02)
        let slack = 0.2
        let covered = spans.map { ($0.time.lowerBound - slack)...($0.time.upperBound + slack) }
        // A span far longer than its words take to say hides speech Apple
        // skipped: "report. Okay." stretched over "কালকে সকালে" in between.
        let stretched = spans.reduce(0.0) { total, span in
            let length = span.time.upperBound - span.time.lowerBound
            return total + max(0, length - (Self.secondsPerWord * Double(max(span.words, 1)) + 0.3))
        }
        var unheard = 0
        for start in stride(from: 0, to: samples.count, by: window) {
            let chunk = samples[start..<min(start + window, samples.count)]
            let rms = (chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count)).squareRoot()
            guard rms >= speechRMS else { continue }
            let t = (Double(start) + Double(window) / 2) / rate
            if !covered.contains(where: { $0.contains(t) }) { unheard += 1 }
        }
        return Double(unheard * window) / rate + stretched
    }

    /// Generous time for one spoken English word (typical: 0.25–0.4 s).
    private static let secondsPerWord = 0.6

    /// Louder than this is speech rather than room noise (about -40 dBFS).
    private static let speechRMS: Float = 0.01

    /// How long an English-confident dictation waits for Whisper's opinion.
    /// Whisper takes ~0.4–0.9 s on a sentence (M4 Pro); slower Macs that run
    /// over simply get Apple's text, as before.
    private static let mixedCheckWait: Duration = .milliseconds(2500)

    /// Words in Bangla script. Two or more means Whisper really heard Bangla;
    /// a single one can be an English word it spelled phonetically.
    static func banglaWordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).filter { word in
            word.unicodeScalars.contains { (0x0980...0x09FF).contains($0.value) }
        }.count
    }

    /// The task's value, or nil if it isn't done within `limit`.
    static func value(of task: Task<String, Never>, within limit: Duration) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask { await task.value }
            group.addTask { try? await Task.sleep(for: limit); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// The bar for 1–3 word replies that are all real English words.
    /// Measured on 116 short clips (5 English voices incl. two Indian
    /// English, 16 Bangla words): English that went astray 0.735–0.814
    /// ("no", "wait", "cool"); Bangla read as real English words at most
    /// 0.644 (নাও → "Now."; না → "No." 0.606). ponytail: synthetic voices —
    /// recalibrate on real recordings if short Bangla replies turn English.
    private static let shortEnglishConfidence = 0.70

    /// Common Bangla words that macOS's English dictionary also accepts.
    private static let banglaLookalikes: Set<String> = [
        "bolo", "cholo", "ji", "jee", "g", "ki", "key", "he", "na", "nah", "ha", "haa", "hum", "hmm",
        "to", "tho", "je", "jao", "khao", "dao", "nao", "aro", "shono", "dekho", "keno", "acha",
    ]

    /// 1–3 words, every one a real English word and none a Bangla lookalike.
    @MainActor
    static func isShortEnglish(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() }
            .filter { !$0.isEmpty }
        guard (1...3).contains(words.count) else { return false }
        let checker = NSSpellChecker.shared
        return words.allSatisfy { word in
            !banglaLookalikes.contains(word)
                && word.unicodeScalars.allSatisfy { $0.isASCII }
                && checker.checkSpelling(of: word, startingAt: 0, language: "en", wrap: false,
                                         inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
    }

    /// Apple's mean word confidence that marks an utterance as English.
    /// Measured on 320 clips: English 0.915–0.990, Bangla 0.025–0.534,
    /// code-mixed 0.000–0.745. ponytail: calibration knob — the English set
    /// was synthetic speech; lower toward 0.78 if accented English lands in
    /// the Bangla model.
    private static let englishConfidence = 0.82

    /// Whisper's transcript, unless it holds no Bangla script at all: then
    /// the speech was English and Apple spells English far better (4.8% vs
    /// 31% WER on our English set). In a mixed sentence the English words
    /// take Apple's spelling one by one (`EnglishSpelling`).
    private func route(heard: String, english: AppleTranscript, mode: SpeechLanguage) -> String {
        let out = routeChoice(heard: heard, english: english, mode: mode)
        #if DEBUG
        if ProcessInfo.processInfo.environment["UFLOW_TRACE"] != nil {
            FileHandle.standardError.write(Data("TRACE\tapple=\(english.text)\tconf=\(english.confidence.map { String(format: "%.3f", $0) } ?? "-")\twhisper=\(heard)\tout=\(out)\n".utf8))
        }
        #endif
        return out
    }

    private func routeChoice(heard: String, english: AppleTranscript, mode: SpeechLanguage) -> String {
        let hasBangla = heard.unicodeScalars.contains { (0x0980...0x09FF).contains($0.value) }
        if !hasBangla, !english.text.isEmpty { return english.text }
        return EnglishSpelling.apply(to: heard, apple: english.words)
    }

    /// Optional on-device clean-up (`TextCleaner`), set from Settings.
    private var cleaner: TextCleaner?

    func setCleaner(_ cleaner: TextCleaner?) { self.cleaner = cleaner }

    /// Last steps on the spoken-script transcript: fillers out, then the
    /// clean-up model (which works best on Bangla script, before
    /// romanization, and never sees Banglish), then Banglish romanization.
    private func finish(_ script: String, mode: SpeechLanguage) async -> String {
        var text = script
        if let cleaner, !text.isEmpty {
            text = await cleaner.clean(FillerFilter.apply(to: text))
        }
        return mode == .banglish ? BanglaRomanizer.apply(to: text) : text
    }

    /// Stops Apple's analyzer and collects its final transcript and confidence.
    private func finishApple(_ session: ActiveSession) async -> AppleTranscript {

        // Finalization of a long recording legitimately takes longer than a
        // short one, so scale the safety budget with the session duration
        // (floor 6 s for quick taps, cap 120 s for marathon sessions).
        let elapsed = ContinuousClock.now - session.startedAt
        let finalizeBudget = min(max(.seconds(6), elapsed * 2), .seconds(120))
        let drainBudget = min(max(.seconds(6), elapsed), .seconds(60))

        // 1) Stop microphone capture immediately.
        session.capture.stop()

        // 2) Tell the stream no more audio is coming.
        session.inputContinuation.finish()
        Log.speech.info("Audio buffers delivered to analyzer: \(session.yielded.count, privacy: .public)")

        // A release that lands before the microphone's first buffer (a quick
        // tap, or a slow engine start on an older Mac) leaves the analyzer with
        // an input stream that closed empty. In that state it never ends its
        // results sequence, so finalizing would only park the HUD on
        // TRANSCRIBING until the drain watchdog fires. There is nothing to
        // transcribe anyway.
        guard session.yielded.count > 0 else {
            await cancelSession()
            return AppleTranscript()
        }

        // 3) Ask the analyzer to finalize everything received so far. Bounded
        //    by a timeout so a wedged pipeline can never hang the app.
        let finalizeTask = Task { try await session.analyzer.finalizeAndFinishThroughEndOfInput() }
        // awaitCompletion returns TRUE when the task finished in time — do not
        // read it as "timed out", or every successful finalization gets torn
        // down by cancelAndFinishNow() and the final results are discarded.
        let finalizedInTime = await Self.awaitCompletion(of: finalizeTask, within: finalizeBudget)
        if !finalizedInTime {
            Log.speech.warning("Finalization timed out — cancelling analysis")
            finalizeTask.cancel()

            // Apple's emergency cancellation is normally immediate, but keep
            // it behind its own watchdog too. A framework operation that is
            // already wedged must not be able to strand the HUD a second time
            // through the recovery path.
            let cancellationTask = Task { await session.analyzer.cancelAndFinishNow() }
            let cancelledInTime = await Self.awaitCompletion(of: cancellationTask, within: .seconds(2))
            if !cancelledInTime {
                Log.speech.error("Speech cancellation timed out — abandoning analyzer")
                cancellationTask.cancel()
            }
        } else {
            Log.speech.info("Speech finalization completed")
        }

        // 4) Drain remaining results only after a successful finalization. If
        // finalization itself timed out, cancellation cannot yield a reliable
        // final result and another full drain deadline would just keep the dead
        // HUD visible longer.
        if finalizedInTime {
            let drainedInTime = await Self.awaitCompletion(of: session.consumerTask, within: drainBudget)
            if !drainedInTime {
                session.consumerTask.cancel()
                // Do not immediately await the cancelled task here: an
                // AsyncSequence supplied by the framework may fail to observe
                // cancellation, which would undo the timeout above.
                Log.speech.warning("Results drain timed out — abandoning consumer")
            }
        } else {
            session.consumerTask.cancel()
        }

        let text = session.accumulator.finalText()
        activeSession = nil
        Log.speech.info("Recording stopped; transcript collected (\(text.isEmpty ? "empty" : "non-empty", privacy: .public))")
        return AppleTranscript(text: text, confidence: session.accumulator.meanConfidence(),
                               words: session.accumulator.words(), spans: session.accumulator.spans())
    }

    /// Cancels the active session without producing a transcript. Used for
    /// accidental taps and unrecoverable errors.
    func cancelSession() async {
        if let session = whisperSession {
            session.capture.stop()
            whisperSession = nil
            Log.speech.info("Session cancelled")
            return
        }
        guard let session = activeSession else { return }
        session.capture.stop()
        session.inputContinuation.finish()

        let cancellationTask = Task { await session.analyzer.cancelAndFinishNow() }
        let cancelledInTime = await Self.awaitCompletion(of: cancellationTask, within: .seconds(2))
        if !cancelledInTime {
            Log.speech.error("Speech cancellation timed out — abandoning analyzer")
            cancellationTask.cancel()
        }

        session.consumerTask.cancel()
        let consumerStopped = await Self.awaitCompletion(of: session.consumerTask, within: .seconds(1))
        if !consumerStopped {
            Log.speech.warning("Cancelled results consumer did not stop in time")
        }
        activeSession = nil
        Log.speech.info("Session cancelled")
    }

    // MARK: - Whisper session

    private func startWhisperRecording(onLevel: (@Sendable (Float) -> Void)?) throws {
        cues.removeAll { ContinuousClock.now - $0 > .seconds(2) }
        let capture = try takeCapture()
        let hardwareFormat = capture.format
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: WhisperEngine.sampleRate,
                                               channels: 1, interleaved: false)
        else { capture.stop(); throw SpeechEngineError.microphoneFormatUnavailable }
        let converter = targetFormat != hardwareFormat ? AVAudioConverter(from: hardwareFormat, to: targetFormat) : nil

        let collector = SampleCollector()
        capture.attach { buffer in
            onLevel?(Self.normalizedLevel(of: buffer))
            guard let output = Self.converted(buffer, with: converter, to: targetFormat),
                  let channel = output.floatChannelData?[0] else { return }
            collector.append(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        }
        whisperSession = WhisperSession(capture: capture, collector: collector, language: language)
        Log.speech.info("Recording started")
    }

    /// A 20 ms slice quieter than this RMS is room noise — and near-silence
    /// is exactly where Whisper invents text ("Thank you."). About -55 dBFS.
    /// ponytail: calibration knob — lower it if a quiet mic gets skipped.
    private static let silenceRMS: Float = 0.0018

    /// Less audible sound than this is not speech — about the old gate's
    /// sensitivity (any 20 ms slice above room noise, three of them), so
    /// even a quick "হ্যাঁ" (0.16 s) passes.
    static let minimumAudibleSeconds = 0.06

    /// How long after a click is played its sound can be in the recording:
    /// the 80–120 ms cue plus output latency.
    static let cueWindow = 0.25

    /// Seconds of the clip that are louder than room noise, in 20 ms slices,
    /// not counting `ignoring` (sample indices of the start click).
    ///
    /// Since the microphone starts at key-down, the start click (`SoundKit`
    /// .recordDown) is recorded, and on its own Whisper turned it into
    /// "taropore amader shows er shows er…" — so pressing Fn and saying
    /// nothing typed garbage. Duration alone can't tell them apart (click
    /// 0.12 s, a quick "হ্যাঁ" 0.16 s), but the app knows when it played the
    /// click, so that stretch simply doesn't count as speech. The audio
    /// itself is untouched: words said over the click still reach the model.
    static func audibleSeconds(_ samples: [Float], ignoring: [Range<Int>] = [],
                               sampleRate: Double = WhisperEngine.sampleRate) -> Double {
        let window = max(1, Int(sampleRate * 0.02))
        let loud = stride(from: 0, to: samples.count, by: window).filter { start in
            let range = start..<min(start + window, samples.count)
            if ignoring.contains(where: { $0.overlaps(range) }) { return false }
            let chunk = samples[range]
            return (chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count)).squareRoot() >= silenceRMS
        }.count
        return Double(loud * window) / sampleRate
    }

    /// Where the app's own clicks fall in a recording made by `capture`.
    private func cueRanges(in capture: MicCapture) -> [Range<Int>] {
        let rate = WhisperEngine.sampleRate
        return cues.compactMap { cue in
            let d = cue - capture.startedAt
            let offset = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
            let lower = max(0, Int((offset - 0.02) * rate))
            let upper = Int((offset + Self.cueWindow) * rate)
            guard upper > lower else { return nil }
            Log.speech.info("Click at \(String(format: "%.2f", offset), privacy: .public) s into the recording; not counted as speech")
            return lower..<upper
        }
    }

    /// When the app played its record/stop clicks for the current session.
    private var cues: [ContinuousClock.Instant] = []

    /// AppState plays the clicks; the silence gate needs to know when.
    func noteCue(at instant: ContinuousClock.Instant) { cues.append(instant) }

    private func stopWhisperRecording(_ session: WhisperSession) async -> String {
        session.capture.stop()
        whisperSession = nil
        let cue = cueRanges(in: session.capture)
        cues = []
        let heard = await transcribeWhisper(session.collector.drain(), mode: session.language, ignoring: cue)
        return route(heard: heard, english: AppleTranscript(), mode: session.language)
    }

    /// Whisper's raw transcript of one recording, or "" for silence.
    private func transcribeWhisper(_ samples: [Float], mode: SpeechLanguage, ignoring cue: [Range<Int>] = []) async -> String {
        Log.speech.info("Audio samples delivered to Whisper: \(samples.count, privacy: .public)")
        guard samples.count >= Int(WhisperEngine.sampleRate * 0.3),
              Self.audibleSeconds(samples, ignoring: cue) >= Self.minimumAudibleSeconds else {
            Log.speech.info("Too short or silent — nothing to transcribe")
            return ""
        }
        let heard = await whisperEngine(for: mode).transcribe(samples)
        Log.speech.info("Whisper transcript collected (\(heard.isEmpty ? "empty" : "non-empty", privacy: .public))")
        return heard
    }

    // MARK: - Internals

    /// RMS of a mic buffer mapped onto a perceptual 0…1 scale for the waveform.
    ///
    /// `floorDB` is the calibration knob: speech RMS varies widely across
    /// machines and mic gain settings. Raise it toward -40 if the waveform sits
    /// too tall on a hot mic, lower it toward -60 if a quiet mic looks flat.
    private static func normalizedLevel(of buffer: AVAudioPCMBuffer, floorDB: Float = -50) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let samples = channels[0]
        let count = Int(buffer.frameLength)
        var sumOfSquares: Float = 0
        for index in 0..<count {
            let sample = samples[index]
            sumOfSquares += sample * sample
        }
        let rms = (sumOfSquares / Float(count)).squareRoot()
        let decibels = 20 * log10(max(rms, 1e-7))
        return min(max((decibels - floorDB) / -floorDB, 0), 1)
    }

    /// Drives one results sequence into the accumulator until the stream ends.
    private func drain<S: AsyncSequence>(
        _ sequence: S,
        into accumulator: TranscriptAccumulator
    ) async where S.Element: TextualSpeechResult {
        do {
            for try await result in sequence {
                var confidence = (sum: 0.0, weight: 0)
                var words: [AppleWord] = []
                var spans: [AppleSpan] = []
                for run in result.text.runs {
                    if let range = run.audioTimeRange, range.start.isNumeric, range.end.isNumeric,
                       range.end.seconds >= range.start.seconds {
                        let count = String(result.text[run.range].characters).split(whereSeparator: \.isWhitespace).count
                        spans.append(AppleSpan(time: range.start.seconds...range.end.seconds, words: count))
                    }
                    guard let value = run.transcriptionConfidence else { continue }
                    let text = String(result.text[run.range].characters)
                    let letters = text.filter { !$0.isWhitespace }.count
                    confidence.sum += value * Double(letters)
                    confidence.weight += letters
                    words += text.split(whereSeparator: \.isWhitespace).map { AppleWord(text: String($0), confidence: value) }
                }
                accumulator.append(String(result.text.characters), isFinal: result.isFinal,
                                   confidence: confidence, words: words,
                                   spans: spans)
            }
        } catch is CancellationError {
            // Expected on cancellation paths.
        } catch {
            Log.speech.error("Results stream terminated: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Awaits a task with a deadline. Returns true when the task finished in
    /// time, false on timeout (the task stays runnable; caller decides whether
    /// to cancel it).
    private static func awaitCompletion<F: Error>(
        of task: Task<Void, F>,
        within duration: Duration
    ) async -> Bool {
        let race = CompletionRace()

        // These are deliberately unstructured observers. A structured task
        // group waits for every child on scope exit, including a child blocked
        // on `task.result`, so its timeout branch can never actually return
        // while the speech framework is wedged.
        let completionObserver = Task {
            _ = await task.result
            await race.resolve(with: true)
        }
        let timeoutObserver = Task {
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            await race.resolve(with: false)
        }

        let completed = await race.value()
        completionObserver.cancel()
        timeoutObserver.cancel()
        return completed
    }
}

// MARK: - Audio tap helpers

/// The microphone for one recording, startable before the recording exists.
///
/// Holding Fn alone waits `HotkeyManager.holdDelay` (300 ms) to tell a hold
/// from a tap, and building the analyzer takes ~130 ms more. Starting the mic
/// only after both lost the first word or two of every dictation ("use
/// subagents" arrived as "pull agents"). So capture starts at key-down and
/// buffers until a session `attach`es, which replays the buffered audio in
/// order before going live — no gap, no reordering, because both happen under
/// one lock that the tap thread also takes.
///
/// The microphone can also change mid-recording (AirPods connect, a USB mic
/// is unplugged). macOS then stops the engine and every later word is lost
/// silently. The capture restarts on the new device and converts its audio
/// back to `format`, so the session's converters never see the change.
final class MicCapture: @unchecked Sendable {
    /// The format every delivered buffer has, for the capture's whole life.
    let format: AVAudioFormat
    /// When the microphone went live; sample 0 of the recording.
    private(set) var startedAt = ContinuousClock.now
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var pending: [AVAudioPCMBuffer] = []
    private var pendingFrames: AVAudioFrameCount = 0
    private var sink: ((AVAudioPCMBuffer) -> Void)?
    private var stopped = false
    private var deviceObserver: NSObjectProtocol?
    /// Serialises everything that touches `engine`: a device-change restart
    /// (notification thread) and `stop()` (the speech actor) must never run
    /// at once, or a restart could start the engine again after stop and
    /// leave the microphone on. Separate from `lock`, which the tap thread
    /// takes for every buffer.
    private let engineLock = NSLock()

    /// Audio kept while waiting for a session. Far more than the ~0.5 s a
    /// hold needs; only bounds memory if a session is slow to claim it.
    private static let maxPendingSeconds = 4.0

    init() throws {
        let input = engine.inputNode
        format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw SpeechEngineError.microphoneFormatUnavailable
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.receive(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
            startedAt = .now
        } catch {
            input.removeTap(onBus: 0)
            throw SpeechEngineError.audioStartFailed(error.localizedDescription)
        }
        deviceObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in self?.restartOnNewDevice() }
    }

    /// The input device changed under a running capture: listen to the new one.
    private func restartOnNewDevice() {
        engineLock.lock()
        defer { engineLock.unlock() }
        lock.lock()
        let done = stopped
        lock.unlock()
        guard !done else { return }   // checked under engineLock: stop() can't interleave

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let device = input.inputFormat(forBus: 0)
        guard device.sampleRate > 0, device.channelCount > 0 else {
            Log.speech.error("Input device changed to one with no usable format; capture stopped")
            return
        }
        let target = format
        let bridge = device == target ? nil : AVAudioConverter(from: device, to: target)
        input.installTap(onBus: 0, bufferSize: 1024, format: device) { [weak self] buffer, _ in
            guard let self, let same = SpeechEngine.converted(buffer, with: bridge, to: target) else { return }
            self.receive(same)
        }
        do {
            engine.prepare()
            try engine.start()
            Log.speech.info("Input device changed mid-capture (\(device.sampleRate, privacy: .public) Hz); capture continued")
        } catch {
            input.removeTap(onBus: 0)
            Log.speech.error("Input device changed; restart failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func receive(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        if let sink {
            sink(buffer)
            return
        }
        // The tap may reuse its buffer; keep a copy.
        guard let copy = buffer.copy() as? AVAudioPCMBuffer else { return }
        pending.append(copy)
        pendingFrames += copy.frameLength
        let limit = AVAudioFrameCount(Self.maxPendingSeconds * format.sampleRate)
        while pendingFrames > limit, !pending.isEmpty {
            pendingFrames -= pending.removeFirst().frameLength
        }
    }

    /// Replays everything captured so far into `sink`, then streams live audio to it.
    func attach(_ sink: @escaping (AVAudioPCMBuffer) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        pending.forEach(sink)
        pending.removeAll()
        pendingFrames = 0
        self.sink = sink
    }

    /// Stops the microphone. Safe to call more than once.
    func stop() {
        lock.lock()
        let first = !stopped
        stopped = true
        sink = nil
        pending.removeAll()
        lock.unlock()
        guard first else { return }
        if let deviceObserver { NotificationCenter.default.removeObserver(deviceObserver) }
        engineLock.lock()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engineLock.unlock()
    }
}

/// Buffers yielded into the analyzer this session. Written only from the
/// realtime tap (one thread) and read after the tap is removed.
final class YieldCounter: @unchecked Sendable {
    var count = 0
}

/// Mic samples for one Whisper session: appended on the realtime tap thread,
/// drained once after the tap is removed.
final class SampleCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []

    func append(_ chunk: UnsafeBufferPointer<Float>) {
        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()
    }

    func drain() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }
}

extension SpeechEngine {
    /// Converts one mic buffer into the analyzer's format.
    ///
    /// A FRESH output buffer per callback is mandatory, not wasteful: the
    /// buffer is handed to `AnalyzerInput` and queued in an unbounded stream
    /// the analyzer drains on its own schedule. Reusing one buffer aliases
    /// every queued input onto memory the audio thread immediately overwrites,
    /// so the analyzer reads whatever the microphone captured last rather than
    /// the recording — which is silence-shaped, and yields no transcript.
    static func converted(
        _ input: AVAudioPCMBuffer,
        with converter: AVAudioConverter?,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard let converter else { return input }

        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(max(input.frameLength, 1)) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var conversionError: NSError?
        // Canonical AVAudioConverter pattern: serve the pending input exactly
        // once per convert() call. If the converter asks again (it needs more
        // data to fill its output), answer .noDataNow — returning the same
        // buffer twice would duplicate frames and corrupt recognition.
        var servedCurrentInput = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if servedCurrentInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            servedCurrentInput = true
            outStatus.pointee = .haveData
            return input
        }
        let result = converter.convert(to: output, error: &conversionError, withInputFrom: inputBlock)
        if conversionError != nil || (result == .error && output.frameLength == 0) {
            Log.speech.error("Audio conversion failed: \(conversionError?.localizedDescription ?? "unknown", privacy: .public)")
            return nil
        }
        return output.frameLength > 0 ? output : nil
    }
}

#if DEBUG
// MARK: - File test hook

extension SpeechEngine {
    /// Runs a recording through the same models, routing and romanizing as a
    /// live dictation; only the microphone is replaced by the file. Backs
    /// `--transcribe` (debug builds only).
    func transcribe(file url: URL) async throws -> String {
        let file = try AVAudioFile(forReading: url)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: WhisperEngine.sampleRate,
                                       channels: 1, interleaved: false) else { return "" }
        try file.read(into: pcm)
        let converter = pcm.format == mono ? nil : AVAudioConverter(from: pcm.format, to: mono)
        let converted = Self.converted(pcm, with: converter, to: mono)
        let samples = converted.flatMap { buffer in
            buffer.floatChannelData.map { Array(UnsafeBufferPointer(start: $0[0], count: Int(buffer.frameLength))) }
        } ?? []

        guard language.usesWhisper else { return await finish(try await appleTranscript(of: url).text, mode: language) }
        let mode = language
        let whisperTask = Task { await self.transcribeWhisper(samples, mode: mode) }
        guard mode.usesEnglishCompanion, resolvedLocale != nil else {
            return await finish(route(heard: await whisperTask.value, english: AppleTranscript(), mode: mode), mode: mode)
        }
        return await finish(await pick(english: try await appleTranscript(of: url), whisper: whisperTask, samples: samples, mode: mode), mode: mode)
    }

    private func appleTranscript(of url: URL) async throws -> AppleTranscript {
        let backend = try makeBackend()
        let accumulator = TranscriptAccumulator()
        let consumer = Task {
            switch backend {
            case .transcriber(let t): await self.drain(t.results, into: accumulator)
            case .dictation(let d): await self.drain(d.results, into: accumulator)
            }
        }
        let analyzer = SpeechAnalyzer(modules: backend.modules,
                                      options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        try await analyzer.start(inputAudioFile: AVAudioFile(forReading: url), finishAfterFile: true)
        await consumer.value
        return AppleTranscript(text: accumulator.finalText(), confidence: accumulator.meanConfidence(),
                               words: accumulator.words(), spans: accumulator.spans())
    }
}
#endif
