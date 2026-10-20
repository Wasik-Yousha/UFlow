import CryptoKit
import Foundation
import whisper

/// On-device Whisper for the Bangla modes. Apple's speech stack ships no
/// Bengali model at all, so Bangla runs on whisper.cpp (vendored:
/// YouFlow/Vendor, build b5130). Not streaming: the recording is transcribed
/// once, when the key is released. English utterances never need it — Apple's
/// model writes those (see SpeechEngine.route).
///
/// Models were chosen by benchmark (FLEURS bn 150 clips, MUCS 2021
/// Bengali-English code-mixed 150 clips, M4 Pro), against the stock
/// large-v3-turbo this replaced (FLEURS 65% WER, code-mixed 102%):
/// - Bangla only: Bengali.AI 2023 winner (whisper-medium) — FLEURS 7.4% WER.
///   Writes English words in Bangla script, which that mode wants.
/// - English + Bangla / Banglish: the same model fine-tuned on code-switched
///   speech — code-mixed 35% WER, the only one that keeps English words in
///   English letters mid-sentence (pure Bangla 15% WER: the price of that).
///
/// Decode settings, also measured:
/// - language forced to Bengali; beam search; no timestamps (Indic fine-tunes
///   never trained timestamp tokens).
/// - no initial prompt: the code-mixed style prompt raised the code-switch
///   model's code-mixed WER 35% → 40%.
/// - suppress_nst off: these models' custom vocabulary would lose its space.
/// - beam 3, no temperature retries: measured as accurate as beam 5 with
///   retries and 20–40% faster (see `decode`). Invented text is handled by the
///   silence gate, logprob/no-speech segment dropping and `WhisperOutputFilter`
///   (loops, non-speech tags, prompt echo).
///
/// All whisper calls run on one serial queue: the context is not thread-safe,
/// and a 1–3 s blocking decode must not sit on a Swift concurrency thread.
///
/// Memory: the model (~600 MB resident) is freed after `idleUnloadDelay`, or
/// at once when the user switches modes, and reloaded on the next key-down
/// while the user is still speaking.
final class WhisperEngine: @unchecked Sendable {
    static let sampleRate: Double = 16_000

    struct Model: Sendable {
        let file: String
        let url: URL
        let sha256: String
        let bytes: Int64
        /// Fastest beam with no measured accuracy loss for this model (1 = greedy).
        let beamSize: Int32

        static let bangla = Model(
            file: "ggml-bengali-whisper-medium-q6_k.bin",
            url: URL(string: "https://huggingface.co/SayedShaun/bengali-whisper-medium-ggml/resolve/main/ggml-model-q6_k.bin")!,
            sha256: "608e8eafd47c523b4a535c6c4ac3bc1c7a8441aedad37a3460be850d26919b13",
            bytes: 639_896_719,
            // Greedy matched beam 5 + retries (FLEURS 5.6% both) at half the
            // median time; the slowest 10% went 7.5 s → 1.2 s.
            beamSize: 1)

        /// kayees/whisper-medium-bn-en-cs (Apache-2.0), converted to ggml and
        /// quantized to q5_0 for UFlow — no public ggml build existed. q8_0
        /// scored within 0.4 WER points at 290 MB more.
        static let banglish = Model(
            file: "ggml-whisper-medium-bn-en-cs-q5_0.bin",
            url: URL(string: "https://github.com/Wasik-Yousha/UFlow/releases/download/models-v1/ggml-whisper-medium-bn-en-cs-q5_0.bin")!,
            sha256: "f559b0c997621a6212532525d90994bce82d5dba69c447df4a72bdd8961563b5",
            bytes: 539_257_671,
            // Beam 3: same accuracy as beam 5 + retries (Bangla 15.5 vs 15.4%,
            // code-mixed 34.5 vs 34.8%); greedy cost 0.8 points on Bangla.
            beamSize: 3)
    }

    /// ponytail: fixed at the Handy/OpenWhispr default; make it a setting if
    /// someone wants the model pinned in memory.
    private static let idleUnloadDelay: TimeInterval = 5 * 60

    private let model: Model
    private var modelFile: URL {
        Store.directory.appendingPathComponent("models", isDirectory: true).appendingPathComponent(model.file)
    }

    init(model: Model) { self.model = model }

    private let queue = DispatchQueue(label: "com.youflow.whisper", qos: .userInitiated)
    private var context: OpaquePointer?         // queue-confined
    private var idleUnload: DispatchWorkItem?   // queue-confined
    private let lock = NSLock()
    private var preparing: Task<Void, Error>?
    private var installed = false

    /// Speed on any Apple Silicon Mac (M1 GPUs are ~3–4x slower than M4 Pro):
    /// a beam-search model (the code-switch one) drops to greedy for good once
    /// two real dictations in a row decode slower than 0.3x their length.
    /// Greedy there is ~20% faster again, code-mixed WER unchanged (34.4 vs
    /// 34.5%), pure Bangla ~0.7 points worse. Queue-confined.
    /// ponytail: one-way switch per launch; add a way back if a Mac that was
    /// only briefly loaded should regain beam search.
    private var greedy = false
    private var slowDecodes = 0
    #if DEBUG
    /// UFLOW_SLOW_RTF=0.01 makes this Mac count as slow, to exercise the switch.
    private static let slowRealTimeFactor = ProcessInfo.processInfo.environment["UFLOW_SLOW_RTF"].flatMap(Double.init) ?? 0.3
    #else
    private static let slowRealTimeFactor = 0.3
    #endif

    /// The model is downloaded, verified and has loaded once. It may be
    /// unloaded right now; `decode` reloads it on demand.
    var isReady: Bool { lock.withLock { installed } }

    // MARK: - Preparation

    /// Downloads (once) and verifies the model, loads it, and runs a silent
    /// warm-up so Metal compiles its shaders now — ~15 s the first time on
    /// this machine — rather than on the user's first dictation. Concurrent
    /// callers share one preparation.
    func prepare(progress: (@Sendable (Double) -> Void)?) async throws {
        let task = lock.withLock {
            if let running = preparing { return running }
            let task = Task { try await self.load(progress: progress) }
            preparing = task
            return task
        }
        do {
            try await task.value
        } catch {
            // A failed attempt (offline, bad download) must be retryable.
            lock.withLock { if preparing == task { preparing = nil } }
            throw error
        }
    }

    private func load(progress: (@Sendable (Double) -> Void)?) async throws {
        let file = modelFile
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? nil
        if size != model.bytes {
            try await download(to: file, progress: progress)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard self.loadContext() else {
                    continuation.resume(throwing: SpeechEngineError.analysisFailed("Whisper model failed to load"))
                    return
                }
                _ = self.decode([Float](repeating: 0, count: Int(Self.sampleRate)))
                continuation.resume()
            }
        }
        lock.withLock { installed = true }
        Log.speech.info("Whisper model loaded and warmed")
    }

    /// Reloads an idle-unloaded model while the user is still speaking, so
    /// the release doesn't wait on it. Cheap no-op when it is loaded.
    func preload() {
        // Rescheduled here too: an accidental tap or a silent clip never
        // reaches decode, and the model must still go after the idle delay.
        queue.async { if self.loadContext() { self.scheduleIdleUnload() } }
    }

    /// Queue-confined. Loads the model unless it already is, and holds off
    /// the idle unload while it is in use.
    private func loadContext() -> Bool {
        idleUnload?.cancel()
        if context != nil { return true }
        // whisper.cpp logs every layer to stderr; nothing there is for the user.
        whisper_log_set({ _, _, _ in }, nil)
        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true
        context = whisper_init_from_file_with_params(modelFile.path, params)
        if context == nil {
            Log.speech.error("Whisper model failed to load")
            // The file was deleted after setup: make the next prepare fetch it
            // again instead of reporting ready and typing nothing.
            if !FileManager.default.fileExists(atPath: modelFile.path) {
                lock.withLock { installed = false; preparing = nil }
            }
        }
        return context != nil
    }

    /// Queue-confined. Frees the model after a quiet spell; any later
    /// queue work (preload, decode) cancels it first.
    private func scheduleIdleUnload() {
        idleUnload?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, let context = self.context else { return }
            whisper_free(context)
            self.context = nil
            Log.speech.info("Whisper model unloaded after idle")
        }
        idleUnload = item
        queue.asyncAfter(deadline: .now() + Self.idleUnloadDelay, execute: item)
    }

    // MARK: - Transcription

    /// Transcribes 16 kHz mono samples. Returns Whisper's raw text in Bangla
    /// script (English letters too, for the code-switch model) — romanizing
    /// is the caller's job.
    /// Cancelling the calling task stops the decode — before it starts if it
    /// is still queued, mid-decode otherwise — so a transcript nobody will
    /// use (Apple already wrote the English) can't hold up the next one.
    func transcribe(_ samples: [Float]) async -> String {
        let abort = AbortFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: self.decode(samples, abort: abort, timed: true)) }
            }
        } onCancel: {
            abort.set()
        }
    }

    /// Frees the model now (mode switch) instead of after the idle delay.
    func unload() {
        queue.async {
            self.idleUnload?.cancel()
            guard let context = self.context else { return }
            whisper_free(context)
            self.context = nil
        }
    }

    /// Queue-confined.
    private func decode(_ samples: [Float], abort: AbortFlag = AbortFlag(), timed: Bool = false) -> String {
        guard !abort.isSet else { return "" }
        guard loadContext(), let context else { return "" }
        defer { scheduleIdleUnload() }
        let started = ContinuousClock.now
        // No temperature retries: they never improved accuracy here and made
        // the slowest dictations several seconds slower.
        let useGreedy = greedy || model.beamSize <= 1
        var params = whisper_full_default_params(useGreedy ? WHISPER_SAMPLING_GREEDY : WHISPER_SAMPLING_BEAM_SEARCH)
        params.beam_search.beam_size = model.beamSize
        params.greedy.best_of = 1
        params.temperature_inc = 0
        params.no_timestamps = true
        params.no_context = true
        params.suppress_nst = false
        params.logprob_thold = -1.25   // with no_speech_thold, drops silent segments
        params.n_threads = 4
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        // `abort` outlives the call: this frame holds it until whisper_full returns.
        params.abort_callback = { data in Unmanaged<AbortFlag>.fromOpaque(data!).takeUnretainedValue().isSet }
        params.abort_callback_user_data = Unmanaged.passUnretained(abort).toOpaque()

        let status: Int32 = "bn".withCString { language in
            params.language = language
            return samples.withUnsafeBufferPointer {
                whisper_full(context, params, $0.baseAddress, Int32($0.count))
            }
        }
        guard status == 0, !abort.isSet else {
            if !abort.isSet { Log.speech.error("Whisper decode failed (\(status, privacy: .public))") }
            return ""
        }
        // Segment texts are byte runs that can split a Bangla character, so
        // join the bytes first and decode once; a stray invalid byte becomes
        // U+FFFD, which the filter drops.
        var bytes: [UInt8] = []
        for segment in 0..<whisper_full_n_segments(context) {
            let text = whisper_full_get_segment_text(context, segment)!
            bytes += UnsafeBufferPointer(start: UnsafeRawPointer(text).assumingMemoryBound(to: UInt8.self),
                                         count: strlen(text))
        }
        let raw = String(decoding: bytes, as: UTF8.self)
        let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
        Log.speech.info("Whisper decode: \(ms, privacy: .public) ms for \(samples.count / 16, privacy: .public) ms of audio")
        // Clips under 3 s are dominated by the fixed 30 s encoder pass, so
        // only longer ones say anything about this Mac's speed.
        let audioMs = samples.count / 16
        if timed, !greedy, model.beamSize > 1, audioMs >= 3000 {
            slowDecodes = Double(ms) > Double(audioMs) * Self.slowRealTimeFactor ? slowDecodes + 1 : 0
            if slowDecodes >= 2 {
                greedy = true
                Log.speech.notice("Whisper is slow on this Mac — switching to greedy decoding")
            }
        }
        return WhisperOutputFilter.apply(to: raw, prompt: "")
    }

    // MARK: - Download

    private func download(to destination: URL, progress: (@Sendable (Double) -> Void)?) async throws {
        Log.speech.info("Downloading Whisper model")
        let downloaded = try await ModelDownload(progress: progress).run(model.url)
        defer { try? FileManager.default.removeItem(at: downloaded) }

        // A truncated or corrupted file would load as garbage or crash
        // whisper.cpp, so nothing is installed unless it matches exactly.
        guard try Self.sha256(of: downloaded) == model.sha256 else {
            throw SpeechEngineError.analysisFailed("Whisper model download was corrupted — try again")
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: downloaded, to: destination)
        Log.speech.info("Whisper model installed")
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// One file download with progress. URLSession's async `download` reports no
/// progress, so this is the delegate form wrapped in a continuation.
private final class ModelDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: (@Sendable (Double) -> Void)?
    private var continuation: CheckedContinuation<URL, Error>?

    init(progress: (@Sendable (Double) -> Void)?) { self.progress = progress }

    func run(_ url: URL) async throws -> URL {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The system deletes `location` when this returns, so move it now.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw SpeechEngineError.analysisFailed("Whisper model download failed (HTTP \(http.statusCode))")
            }
            try FileManager.default.moveItem(at: location, to: kept)
            continuation?.resume(returning: kept)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

/// Set from any thread to stop one decode; read by whisper.cpp between steps.
final class AbortFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
