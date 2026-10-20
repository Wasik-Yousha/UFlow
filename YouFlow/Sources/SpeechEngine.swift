import AVFAudio
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

    func append(_ rawText: String, isFinal: Bool, confidence: (sum: Double, weight: Int) = (0, 0),
                words: [AppleWord] = []) {
        let text = String(rawText)
        lock.lock()
        defer { lock.unlock() }
        if isFinal {
            finalizedParts.append(text)
            volatileTail = ""
            confidenceSum += confidence.sum
            confidenceWeight += confidence.weight
            finalizedWords += words
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

    /// Assembled transcript from finalized results only. Chunks concatenate
    /// verbatim — Apple's result texts are designed to join seamlessly, and
    /// forcing separators between them corrupts word/punctuation boundaries.
    func finalText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return Self.normalize(finalizedParts.joined())
    }

    /// Live view (finalized + volatile) — usable for HUD previews; never injected.
    func currentText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return Self.normalize((finalizedParts + [volatileTail]).joined())
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
        let audioEngine: AVAudioEngine
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
        let audioEngine: AVAudioEngine
        let collector: SampleCollector
        let language: SpeechLanguage
    }
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
                                 attributeOptions: preset.attributeOptions.union([.transcriptionConfidence]))
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
        let backend = try makeBackend()
        let modules = backend.modules

        // Hardware input format (mic permission is verified upstream in AppState).
        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let hardwareFormat = inputNode.inputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw SpeechEngineError.microphoneFormatUnavailable
        }

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
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: hardwareFormat) { buffer, _ in
            onLevel?(Self.normalizedLevel(of: buffer))
            if let collector, let mono = Self.converted(buffer, with: whisperConverter, to: whisperFormat),
               let channel = mono.floatChannelData?[0] {
                collector.append(UnsafeBufferPointer(start: channel, count: Int(mono.frameLength)))
            }
            guard let output = Self.converted(buffer, with: converter, to: targetFormat) else { return }
            counter.count += 1
            continuation.yield(AnalyzerInput(buffer: output))
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            continuation.finish()
            consumerTask.cancel()
            throw SpeechEngineError.audioStartFailed(error.localizedDescription)
        }

        activeSession = ActiveSession(
            analyzer: analyzer,
            audioEngine: audioEngine,
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
        if let session = whisperSession { return await stopWhisperRecording(session) }
        guard let session = activeSession else { return "" }
        guard let collector = session.collector else { return await finishApple(session).text }

        // Bangla modes: Whisper starts on the recording while Apple finalizes.
        // Apple is done first; when it is sure the speech was English its text
        // goes out without waiting for Whisper.
        session.audioEngine.inputNode.removeTap(onBus: 0)
        session.audioEngine.stop()
        let samples = collector.drain()
        let mode = session.language
        let whisperTask = Task { await self.transcribeWhisper(samples, mode: mode) }
        return await pick(english: await finishApple(session), whisper: whisperTask, mode: mode)
    }

    /// Apple's text when it is sure the speech was English, else Whisper's.
    private func pick(english: AppleTranscript, whisper: Task<String, Never>, mode: SpeechLanguage) async -> String {
        if let confidence = english.confidence, confidence >= Self.englishConfidence, !english.text.isEmpty {
            // Stop the now-pointless decode, or the next dictation queues
            // behind it (measured: a Bangla clip after three English ones
            // waited 12.7 s instead of ~1.4 s).
            whisper.cancel()
            Log.speech.info("Routed to Apple (confidence \(confidence, privacy: .public))")
            return english.text
        }
        return route(heard: await whisper.value, english: english, mode: mode)
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
        let hasBangla = heard.unicodeScalars.contains { (0x0980...0x09FF).contains($0.value) }
        if !hasBangla, !english.text.isEmpty { return english.text }
        let spelled = EnglishSpelling.apply(to: heard, apple: english.words)
        return mode == .banglish ? BanglaRomanizer.apply(to: spelled) : spelled
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
        session.audioEngine.inputNode.removeTap(onBus: 0)
        session.audioEngine.stop()

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
                               words: session.accumulator.words())
    }

    /// Cancels the active session without producing a transcript. Used for
    /// accidental taps and unrecoverable errors.
    func cancelSession() async {
        if let session = whisperSession {
            session.audioEngine.inputNode.removeTap(onBus: 0)
            session.audioEngine.stop()
            whisperSession = nil
            Log.speech.info("Session cancelled")
            return
        }
        guard let session = activeSession else { return }
        session.audioEngine.inputNode.removeTap(onBus: 0)
        session.audioEngine.stop()
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
        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let hardwareFormat = inputNode.inputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0,
              let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: WhisperEngine.sampleRate,
                                               channels: 1, interleaved: false)
        else { throw SpeechEngineError.microphoneFormatUnavailable }
        let converter = targetFormat != hardwareFormat ? AVAudioConverter(from: hardwareFormat, to: targetFormat) : nil

        let collector = SampleCollector()
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: hardwareFormat) { buffer, _ in
            onLevel?(Self.normalizedLevel(of: buffer))
            guard let output = Self.converted(buffer, with: converter, to: targetFormat),
                  let channel = output.floatChannelData?[0] else { return }
            collector.append(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        }
        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw SpeechEngineError.audioStartFailed(error.localizedDescription)
        }
        whisperSession = WhisperSession(audioEngine: audioEngine, collector: collector, language: language)
        Log.speech.info("Recording started")
    }

    /// When even the loudest 100 ms of a clip is below this RMS, the clip is
    /// room noise — and near-silence is exactly where Whisper invents text
    /// ("Thank you."). About -55 dBFS. Judged on the loudest window, not the
    /// whole clip, so a long hold with a short phrase in it still counts.
    /// ponytail: calibration knob — lower it if a quiet mic gets skipped.
    private static let silenceRMS: Float = 0.0018

    static func loudestWindowRMS(_ samples: [Float], window: Int = 1600) -> Float {
        stride(from: 0, to: samples.count, by: window).reduce(Float(0)) { loudest, start in
            let chunk = samples[start..<min(start + window, samples.count)]
            return max(loudest, (chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count)).squareRoot())
        }
    }

    private func stopWhisperRecording(_ session: WhisperSession) async -> String {
        session.audioEngine.inputNode.removeTap(onBus: 0)
        session.audioEngine.stop()
        whisperSession = nil
        let heard = await transcribeWhisper(session.collector.drain(), mode: session.language)
        return route(heard: heard, english: AppleTranscript(), mode: session.language)
    }

    /// Whisper's raw transcript of one recording, or "" for silence.
    private func transcribeWhisper(_ samples: [Float], mode: SpeechLanguage) async -> String {
        Log.speech.info("Audio samples delivered to Whisper: \(samples.count, privacy: .public)")
        guard samples.count >= Int(WhisperEngine.sampleRate * 0.3), Self.loudestWindowRMS(samples) >= Self.silenceRMS else {
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
                for run in result.text.runs {
                    guard let value = run.transcriptionConfidence else { continue }
                    let text = String(result.text[run.range].characters)
                    let letters = text.filter { !$0.isWhitespace }.count
                    confidence.sum += value * Double(letters)
                    confidence.weight += letters
                    words += text.split(whereSeparator: \.isWhitespace).map { AppleWord(text: String($0), confidence: value) }
                }
                accumulator.append(String(result.text.characters), isFinal: result.isFinal,
                                   confidence: confidence, words: words)
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

        guard language.usesWhisper else { return try await appleTranscript(of: url).text }
        let mode = language
        let whisperTask = Task { await self.transcribeWhisper(samples, mode: mode) }
        guard mode.usesEnglishCompanion, resolvedLocale != nil else {
            return route(heard: await whisperTask.value, english: AppleTranscript(), mode: mode)
        }
        return await pick(english: try await appleTranscript(of: url), whisper: whisperTask, mode: mode)
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
                               words: accumulator.words())
    }
}
#endif
