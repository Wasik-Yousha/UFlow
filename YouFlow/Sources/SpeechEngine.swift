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

    func append(_ rawText: String, isFinal: Bool) {
        let text = String(rawText)
        lock.lock()
        defer { lock.unlock() }
        if isFinal {
            finalizedParts.append(text)
            volatileTail = ""
        } else {
            volatileTail = text
        }
    }

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

/// What the user speaks. Apple ships no Bengali model, so Banglish rides the
/// Indian-English model (South Asian accent, code-switching) plus a short bias
/// list of common romanized Bangla words.
enum SpeechLanguage: String, CaseIterable, Codable, Sendable {
    case english
    case mixed
    case banglish

    var label: String {
        switch self {
        case .english: "English"
        case .mixed: "English + Banglish"
        case .banglish: "Banglish"
        }
    }

    var detail: String {
        switch self {
        case .english: "US English model. Best when you only speak English."
        case .mixed: "Indian-English model. Handles a Bangladeshi accent and Bangla words mixed into English."
        case .banglish: "Indian-English model, nudged toward romanized Bangla words. Add your own to the dictionary."
        }
    }

    var localeIdentifier: String { self == .english ? "en-US" : "en-IN" }

    /// ponytail: a bias nudge, not a Bengali model — real Bangla needs Whisper.
    /// Kept short: long contextual lists make these models invent text.
    var biasTerms: [String] {
        guard self == .banglish else { return [] }
        return ["ami", "tumi", "apni", "ki", "keno", "kothay", "hobe", "korbo",
                "korchi", "bhalo", "achi", "acho", "na", "hae", "ekhon", "kalke",
                "bhai", "accha", "thik ache", "dhonnobad"]
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
    }

    // Preparation results (launch time).
    private var resolvedLocale: Locale?
    private var prefersDictationFallback = false
    private(set) var preparedFormat: AVAudioFormat?

    private var activeSession: ActiveSession?

    /// Words the analyzer should lean toward. Kept deliberately short by the
    /// caller: a long contextual list makes these models drift and invent text
    /// on quiet audio. Biasing is a nudge — the dictionary's correction pass is
    /// what actually guarantees the spelling.
    private var biasTerms: [String] = []

    /// Which transcription backend the user asked for.
    private var preference: BackendPreference = .automatic

    /// Which language model and bias the user asked for.
    private var language: SpeechLanguage = .english

    var isPrepared: Bool { resolvedLocale != nil }
    var isSessionActive: Bool { activeSession != nil }

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
        language = newValue
        resolvedLocale = nil
        preparedFormat = nil
        Log.speech.info("Language set to \(newValue.rawValue, privacy: .public)")
    }

    /// The backend actually in use, for display.
    var activeBackendName: String {
        guard resolvedLocale != nil else { return "Not ready" }
        return prefersDictationFallback ? "Dictation" : "Apple (streaming)"
    }

    // MARK: - Preparation (launch time)

    /// Resolves the locale, ensures assets, and prewarms the model stack using
    /// disposable objects. Intended to run once at application startup.
    ///
    /// - Parameter progressHandler: receives asset download progress (0…1).
    func prepare(progressHandler: (@Sendable (Double) -> Void)? = nil) async throws {
        guard resolvedLocale == nil else { return }

        let requestedLocale = Locale(identifier: language.localeIdentifier)
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
            : SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        try await ensureAssets(for: [probeModule], progressHandler: progressHandler)

        // Prewarm model loading with a throwaway backend + analyzer, then
        // release both so no live module carries a lingering analyzer claim.
        let prewarmBackend: Backend = useFallback
            ? .dictation(DictationTranscriber(locale: locale, preset: .progressiveShortDictation))
            : .transcriber(SpeechTranscriber(locale: locale, preset: .progressiveTranscription))
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

    /// Builds a fresh module set for a new session. Cheap: the underlying
    /// models remain resident via process-lifetime retention.
    private func makeBackend() throws -> Backend {
        guard let locale = resolvedLocale else { throw SpeechEngineError.notPrepared }
        if prefersDictationFallback {
            return .dictation(DictationTranscriber(locale: locale, preset: .progressiveShortDictation))
        }
        return .transcriber(SpeechTranscriber(locale: locale, preset: .progressiveTranscription))
    }

    // MARK: - Session control

    /// Begins a recording session: starts the results consumer, spins up a
    /// fresh SpeechAnalyzer over an AsyncStream of mic buffers, and opens the
    /// AVAudioEngine input tap.
    /// - Parameter onLevel: receives a normalized microphone level (0…1) per
    ///   audio buffer, for the HUD waveform. Called on the realtime audio
    ///   thread — the handler must hop to its own actor and stay cheap.
    func startRecording(onLevel: (@Sendable (Float) -> Void)? = nil) async throws {
        guard activeSession == nil else { throw SpeechEngineError.sessionAlreadyActive }
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
        let allBiasTerms = biasTerms + language.biasTerms
        if !allBiasTerms.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = allBiasTerms
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

        // Lightweight realtime tap: convert the buffer and yield it onward.
        let counter = YieldCounter()
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: hardwareFormat) { buffer, _ in
            onLevel?(Self.normalizedLevel(of: buffer))
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
            yielded: counter
        )
        Log.speech.info("Recording started")
    }

    /// Stops capture, finalizes analyzer input, waits for the stabilized final
    /// transcript, and tears the session down. Returns the final text (possibly
    /// empty — callers decide what to do with that).
    func stopRecordingAndCollect() async -> String {
        guard let session = activeSession else { return "" }

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
            return ""
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
        return text
    }

    /// Cancels the active session without producing a transcript. Used for
    /// accidental taps and unrecoverable errors.
    func cancelSession() async {
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
                accumulator.append(String(result.text.characters), isFinal: result.isFinal)
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
