import AppKit
import CryptoKit
import Foundation
import os

/// The on-device model that cleans up a dictation. One per Mac, picked by RAM
/// (`forThisMac`): a Mac is offered only the model its memory can carry
/// alongside Whisper and whatever the user is doing.
///
/// All three are Google's chat-tuned Gemma 4, quantized Q4_0 by ggml-org.
/// Pinned by SHA-256 (Hugging Face's LFS hash, `x-linked-etag`).
enum CleanupModel: String, CaseIterable, Sendable {
    case e2b, e4b, e12b

    /// < 16 GB → E2B; 16 GB up to 18 GB → E4B; 18 GB and up → 12B.
    /// `physicalMemory` is exact (a 16 GB Mac reports 17_179_869_184), so
    /// this compares in GiB.
    static func forThisMac() -> CleanupModel {
        let gib = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        if gib < 16 { return .e2b }
        if gib < 18 { return .e4b }
        return .e12b
    }

    var displayName: String {
        switch self {
        case .e2b: "Gemma 4 E2B"
        case .e4b: "Gemma 4 E4B"
        case .e12b: "Gemma 4 12B"
        }
    }

    var file: String {
        switch self {
        case .e2b: "gemma-4-E2B-it-Q4_0.gguf"
        case .e4b: "gemma-4-E4B-it-Q4_0.gguf"
        case .e12b: "gemma-4-12B-it-Q4_0.gguf"
        }
    }

    var url: URL {
        let repo = switch self {
        case .e2b: "gemma-4-E2B-it-GGUF"
        case .e4b: "gemma-4-E4B-it-GGUF"
        case .e12b: "gemma-4-12B-it-GGUF"
        }
        return URL(string: "https://huggingface.co/ggml-org/\(repo)/resolve/main/\(file)")!
    }

    var bytes: Int64 {
        switch self {
        case .e2b: 2_841_481_184
        case .e4b: 4_590_807_392
        case .e12b: 7_219_673_216
        }
    }

    var sha256: String {
        switch self {
        case .e2b: "8e30dff3ac4c8434c49a7036fa15564bdbb6044e42bf04550bf1a096ad7e6a52"
        case .e4b: "a555b900214b477d8880e7832e0b8925e139b0159640036b09fe472b6f2097f2"
        case .e12b: "3712b9bd32cae83a22f67ee7a4466d8d7a4f21646ac8a07d19bf9418e8767a70"
        }
    }

    /// ~/Library/Application Support/UFlow/models/<file>
    var fileURL: URL {
        Store.directory.appendingPathComponent("models", isDirectory: true).appendingPathComponent(file)
    }

    /// Installed: present at full size. (The checksum is verified once, before
    /// the file is moved into place; nothing half-written ever gets there.)
    var isDownloaded: Bool { downloadedBytes == bytes }

    /// Size of the installed file on disk, 0 when there is none.
    var downloadedBytes: Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size]) as? Int64) ?? 0
    }
}

enum LocalLLMError: LocalizedError {
    case notEnoughDiskSpace(needed: Int64)
    case downloadFailed(String)
    case corrupted
    case loadFailed

    var errorDescription: String? {
        switch self {
        case .notEnoughDiskSpace(let needed):
            "Not enough disk space for the clean-up model (needs \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)))"
        case .downloadFailed(let why): "Clean-up model download failed (\(why))"
        case .corrupted: "Clean-up model download was corrupted — try again"
        case .loadFailed: "Clean-up model failed to load"
        }
    }
}

/// Runs a Gemma 4 GGUF with llama.cpp (vendored: YouFlow/Vendor, build b12669,
/// reached through LlamaBridge.h — see there for why not `import llama`)
/// to rewrite a short dictation. This only generates; the prompts and the
/// guard that decides whether to trust the output live elsewhere.
///
/// Mirrors `WhisperEngine`:
/// - every llama call runs on one serial queue (the context is not
///   thread-safe, and a blocking decode must not sit on a Swift concurrency
///   thread);
/// - the model is freed after `idleUnloadDelay`, at once on memory pressure,
///   and synchronously at quit (ggml's Metal device asserts at exit if a
///   buffer is still alive — llama.framework carries its own ggml copy, so
///   it has its own copy of that assert).
///
/// Memory: weights are mmapped, never mlocked, and used in place by Metal
/// (unified memory), so they are clean file-backed pages the kernel can drop
/// under pressure instead of swapping. The KV cache is bounded by `contextSize`.
final class LocalLLM: @unchecked Sendable {
    let model: CleanupModel

    /// Room for system prompt + few-shot examples + a dictation + its rewrite.
    /// Fixed so memory is bounded; a prompt that does not fit is refused.
    static let contextSize: UInt32 = 2048
    private static let idleUnloadDelay: TimeInterval = 3 * 60
    /// `shouldSkip` stays true this long after a memory-pressure event.
    private static let pressureCooldown: TimeInterval = 60

    private static let log = Logger(subsystem: "com.youflow.dictation", category: "LLM")

    /// llama_backend_init must run once per process, before any model load.
    private static let backend: Void = {
        uflow_llama_init { text in
            // llama.cpp logs every tensor at load; the bridge passes errors only.
            guard let text else { return }
            LocalLLM.log.error("llama: \(String(cString: text), privacy: .public)")
        }
    }()

    init(model: CleanupModel) {
        self.model = model
        // Same reason as WhisperEngine: free before ggml's statics are torn down.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.freeNow() }

        // Not on `queue`: a generation running there must be told to stop.
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical],
                                                             queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self, weak source] in
            self?.memoryPressure(critical: source?.data.contains(.critical) ?? true)
        }
        source.activate()
        pressureSource = source
    }

    deinit {
        pressureSource?.cancel()
        // Nothing else can hold the model now (queued work retains `self`),
        // and a model outliving its owner would trip the exit assert.
        if let llm { uflow_llama_free(llm) }
    }

    private let queue = DispatchQueue(label: "com.youflow.llm", qos: .userInitiated)
    private var pressureSource: DispatchSourceMemoryPressure?

    // Queue-confined.
    private var llm: OpaquePointer?
    private var swaWindow: Int32 = 0
    /// The 12B's template pre-fills an empty thought after `<|turn>model\n`
    /// when thinking is off; E2B/E4B's don't. Follow whichever the file has.
    private var emptyThoughtPrefill = false
    /// Tokens whose keys/values are in the KV cache, in order, so the next
    /// prompt only evaluates what differs (the system prompt and examples
    /// are the same every time).
    private var cachedTokens: [Int32] = []
    private var idleUnload: DispatchWorkItem?
    private(set) var usesGPU = false

    // Lock-protected.
    private let lock = NSLock()
    private var inFlight: [AbortFlag] = []
    private var preparing: Task<Void, Error>?
    private var download: LLMDownload?
    private var lastPressure: Date?

    // MARK: - Should we even try

    /// True when clean-up should be skipped and the raw transcript used:
    /// memory pressure in the last minute, a hot Mac, or Low Power Mode.
    var shouldSkip: Bool {
        if let last = lock.withLock({ lastPressure }), Date().timeIntervalSince(last) < Self.pressureCooldown {
            return true
        }
        let thermal = ProcessInfo.processInfo.thermalState
        return thermal == .serious || thermal == .critical || ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    #if DEBUG
    /// What the pressure source does, for `--llm --wait-pressure` when the
    /// OS can't be made to send one (`memory_pressure -S` needs root).
    func simulateMemoryPressure() { memoryPressure(critical: true) }
    #endif

    /// Critical: stop now, unload, and skip clean-up for `pressureCooldown`.
    ///
    /// Warning: keep cleaning, but release the model straight after each use
    /// instead of keeping it warm. An 8 GB Mac with a browser open sits at
    /// the warning level much of the time, and skipping there would mean
    /// clean-up never runs on exactly the Macs that asked for the small
    /// model. The weights are clean memory-mapped pages, so macOS reclaims
    /// them freely; what unloading gives back is the context and GPU buffers.
    private func memoryPressure(critical: Bool) {
        lock.withLock {
            lastWarning = Date()
            if critical {
                lastPressure = Date()
                inFlight.forEach { $0.set() }
            }
        }
        queue.async {
            if self.llm != nil {
                Self.log.notice("Memory pressure (\(critical ? "critical" : "warning", privacy: .public)) — unloading the clean-up model")
            }
            self.free()
        }
    }

    /// A warning arrived recently: unload after each generation.
    private var underWarning: Bool {
        lock.withLock { lastWarning.map { Date().timeIntervalSince($0) < Self.pressureCooldown } ?? false }
    }
    private var lastWarning: Date?

    // MARK: - Download

    var isDownloaded: Bool { model.isDownloaded }
    var downloadedBytes: Int64 { model.downloadedBytes }

    /// Downloads (once) and verifies the model. Does not load it — `preload`
    /// does. Concurrent callers share one download. Cancelling the calling
    /// task, or `cancelDownload()`, stops it and throws `CancellationError`.
    /// `progress` (0…1) is called on a background queue.
    /// ponytail: no resume — a cancelled or dropped download starts over.
    func prepare(progress: (@Sendable (Double) -> Void)?) async throws {
        let task = lock.withLock {
            if let running = preparing { return running }
            let task = Task { try await self.install(progress: progress) }
            preparing = task
            return task
        }
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            lock.withLock { if preparing == task { preparing = nil } }
        } catch {
            // A failed or cancelled attempt must be retryable.
            lock.withLock { if preparing == task { preparing = nil } }
            throw error
        }
    }

    /// For a Cancel button: stops a download in progress (no-op otherwise).
    func cancelDownload() {
        lock.withLock {
            preparing?.cancel()
            download?.cancel()
        }
    }

    /// Unloads the model and removes its file (a Remove button).
    func delete() throws {
        cancelDownload()
        freeNow()
        if FileManager.default.fileExists(atPath: model.fileURL.path) {
            try FileManager.default.removeItem(at: model.fileURL)
        }
    }

    private func install(progress: (@Sendable (Double) -> Void)?) async throws {
        if model.isDownloaded { return }
        let destination = model.fileURL
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // The temporary copy and the installed file never coexist (it is
        // moved, not copied), so the file size plus some headroom is enough.
        let needed = model.bytes + 512 << 20
        if let free = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free < needed {
            throw LocalLLMError.notEnoughDiskSpace(needed: needed)
        }

        Self.log.info("Downloading \(self.model.file, privacy: .public)")
        let fetch = LLMDownload(progress: progress)
        lock.withLock { download = fetch }
        defer { lock.withLock { if download === fetch { download = nil } } }
        try Task.checkCancellation()
        let downloaded = try await withTaskCancellationHandler {
            try await fetch.run(model.url)
        } onCancel: {
            fetch.cancel()
        }
        defer { try? FileManager.default.removeItem(at: downloaded) }

        // A truncated or corrupted file would load as garbage or crash
        // llama.cpp, so nothing is installed unless it matches exactly.
        let hash = try await Self.sha256(of: downloaded)
        guard hash == model.sha256 else { throw LocalLLMError.corrupted }
        try Task.checkCancellation()
        _ = try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: downloaded, to: destination)
        Self.log.info("Installed \(self.model.file, privacy: .public)")
    }

    /// Re-checks the installed file against its pinned SHA-256 (seconds of
    /// I/O; e.g. for a "Verify" action or after a suspected disk problem).
    func verifyInstalled() async -> Bool {
        guard model.isDownloaded else { return false }
        return (try? await Self.sha256(of: model.fileURL)) == model.sha256
    }

    /// Hashes off the cooperative pool: several GB take seconds of blocking I/O.
    private static func sha256(of url: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    var hasher = SHA256()
                    // One pool per chunk: FileHandle's Data is autoreleased,
                    // and without this the whole file (GBs) stays resident
                    // until the block returns — measured: 4.6 GB footprint
                    // peak while verifying E4B.
                    while try autoreleasepool(invoking: {
                        guard let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty else { return false }
                        hasher.update(data: chunk)
                        return true
                    }) {}
                    continuation.resume(returning: hasher.finalize().map { String(format: "%02x", $0) }.joined())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Loading

    /// Loads the model in the background (e.g. on key-down, while the user is
    /// still speaking) so the release doesn't wait on it. Cheap when loaded.
    func preload() {
        queue.async { if self.load() { self.scheduleIdleUnload() } }
    }

    /// `preload`, awaited. False when the file is missing or will not load.
    func loadNow() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                let loaded = self.load()
                if loaded { self.scheduleIdleUnload() }
                continuation.resume(returning: loaded)
            }
        }
    }

    /// Frees the model now (Settings switch, memory pressure). Async.
    func unload() {
        queue.async { self.free() }
    }

    /// Frees the model before returning. A generation in progress is told to
    /// stop first, so quitting waits for the next token, not the whole reply.
    func freeNow() {
        lock.withLock { inFlight.forEach { $0.set() } }
        queue.sync { free() }
    }

    var isLoaded: Bool { queue.sync { llm != nil } }

    /// Queue-confined.
    private func free() {
        idleUnload?.cancel()
        if let llm { uflow_llama_free(llm) }
        llm = nil
        cachedTokens = []
    }

    /// Queue-confined. Loads unless loaded, and holds off the idle unload.
    private func load() -> Bool {
        idleUnload?.cancel()
        if llm != nil { return true }
        guard model.isDownloaded else {
            Self.log.error("\(self.model.file, privacy: .public) is not downloaded")
            return false
        }
        _ = Self.backend
        // Metal first; if this Mac's GPU can't take it (init or allocation
        // fails), the CPU still works, just slower.
        if loadWeights(gpu: true) || loadWeights(gpu: false) {
            return true
        }
        Self.log.error("\(self.model.file, privacy: .public) failed to load")
        return false
    }

    /// Queue-confined.
    private func loadWeights(gpu: Bool) -> Bool {
        free()
        let threads = Int32(max(2, min(Self.performanceCores, 8)))
        guard let loaded = uflow_llama_load(model.fileURL.path, gpu, Self.contextSize, threads) else { return false }

        // The prompt is built by hand from the GGUF's own Gemma 4 template
        // (see `prompt`); refuse a file whose template is something else.
        let template = Self.chatTemplate(of: loaded)
        guard template.contains("<|turn>"), template.contains("<turn|>") else {
            Self.log.error("Unexpected chat template in \(self.model.file, privacy: .public)")
            uflow_llama_free(loaded)
            return false
        }
        llm = loaded
        swaWindow = uflow_llama_swa_window(loaded)
        emptyThoughtPrefill = template.contains(#"'<|channel>thought\n<channel|>'"#)
        usesGPU = uflow_llama_uses_gpu(loaded)
        warmUp()
        Self.log.info("Loaded \(self.model.file, privacy: .public) (\(self.usesGPU ? "Metal" : "CPU", privacy: .public))")
        return true
    }

    /// Queue-confined. Metal builds its compute pipelines on first use, which
    /// cost the first generation of each process ~0.3–0.5 s (measured, E4B on
    /// M4 Pro). One batch and one single-token step here — during `preload`,
    /// while the user is still speaking — pay that instead.
    private func warmUp() {
        guard let llm else { return }
        let batch = prompt(system: "", shots: [], user: "ok")
        if uflow_llama_eval(llm, batch, Int32(batch.count), 0) == 0 {
            var token = uflow_llama_sample(llm)
            _ = uflow_llama_eval(llm, &token, 1, Int32(batch.count))
        }
        uflow_llama_clear(llm)
        cachedTokens = []
    }

    private static func chatTemplate(of llm: OpaquePointer) -> String {
        let length = uflow_llama_chat_template(llm, nil, 0)
        guard length > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: Int(length) + 1)
        _ = uflow_llama_chat_template(llm, &buffer, length)
        return String(cString: buffer)
    }

    private static let performanceCores: Int = {
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &cores, &size, nil, 0) == 0, cores > 0 { return Int(cores) }
        return max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
    }()

    /// Queue-confined.
    private func scheduleIdleUnload() {
        idleUnload?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.llm != nil else { return }
            self.free()
            Self.log.info("Clean-up model unloaded after idle")
        }
        idleUnload = item
        queue.asyncAfter(deadline: .now() + Self.idleUnloadDelay, execute: item)
    }

    // MARK: - Generation

    /// One chat completion: `system`, then each few-shot pair as a user and
    /// a model turn, then `user`; greedy (temperature 0), up to the model's
    /// end of turn. Returns the reply trimmed, or nil on timeout, abort
    /// (cancelling the calling task, memory pressure, quit), failure, a
    /// prompt that doesn't fit `contextSize`, or a reply that runs into
    /// `maxTokens` without ending (a runaway is not a usable rewrite).
    ///
    /// `maxTokens` defaults to 1.5 × the tokens of `user` + 16. `timeout`
    /// counts from this call, including time spent waiting for the model to
    /// load or for an earlier generation to finish.
    ///
    /// Does not consult `shouldSkip`; callers do, before asking.
    func generate(system: String,
                  shots: [(user: String, assistant: String)] = [],
                  user: String,
                  maxTokens: Int? = nil,
                  timeout: Duration = .seconds(10)) async -> String? {
        let deadline = ContinuousClock.now + timeout
        let abort = AbortFlag()
        lock.withLock { inFlight.append(abort) }
        defer { lock.withLock { inFlight.removeAll { $0 === abort } } }
        let shotsCopy = shots.map { (user: $0.user, assistant: $0.assistant) }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    let result = self.run(system: system, shots: shotsCopy, user: user,
                                          maxTokens: maxTokens, deadline: deadline, abort: abort)
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            abort.set()
        }
    }

    #if DEBUG
    /// Timings of the last generation, for `--llm`. Queue-confined.
    struct Stats: Sendable { var promptTokens = 0; var reusedTokens = 0; var generatedTokens = 0; var promptMs = 0.0; var generateMs = 0.0 }
    private var stats = Stats()
    var lastStats: Stats { queue.sync { stats } }
    #endif

    /// Queue-confined.
    private func run(system: String, shots: [(user: String, assistant: String)], user: String,
                     maxTokens: Int?, deadline: ContinuousClock.Instant, abort: AbortFlag) -> String? {
        func expired() -> Bool { abort.isSet || ContinuousClock.now >= deadline }
        guard !expired() else { return nil }
        guard load(), let llm else { return nil }
        defer { if underWarning { free() } else { scheduleIdleUnload() } }

        let prompt = self.prompt(system: system, shots: shots, user: user)
        let cap = maxTokens ?? (tokenize(user.trimmingCharacters(in: .whitespacesAndNewlines), parseSpecial: false).count * 3 / 2 + 16)
        guard cap > 0, prompt.count + cap <= Int(Self.contextSize) else {
            Self.log.error("Clean-up prompt too long (\(prompt.count, privacy: .public) + \(cap, privacy: .public) tokens)")
            return nil
        }

        uflow_llama_set_abort(llm, { data in
            Unmanaged<AbortFlag>.fromOpaque(data!).takeUnretainedValue().isSet
        }, Unmanaged.passUnretained(abort).toOpaque())
        defer { uflow_llama_set_abort(llm, nil, nil) }

        let started = ContinuousClock.now
        // Keep the cached prefix the new prompt shares (system + examples),
        // and drop the rest. At least one token is evaluated, to get logits.
        var reuse = zip(cachedTokens, prompt).prefix { $0 == $1 }.count
        reuse = min(reuse, prompt.count - 1)
        // Sliding-window layers only keep the last `swaWindow` positions; if
        // the kept prefix reaches back past what they still hold, start over.
        let oldest = uflow_llama_pos_min(llm)
        if reuse > 0, swaWindow > 0, oldest > max(0, Int32(reuse) - swaWindow) { reuse = 0 }
        if reuse == 0 || !uflow_llama_truncate(llm, Int32(reuse)) {
            uflow_llama_clear(llm)
            reuse = 0
        }
        cachedTokens = Array(prompt.prefix(reuse))

        guard evaluate(Array(prompt[reuse...]), at: reuse, llm: llm) else {
            // Half-evaluated state is unknown: don't reuse any of it.
            uflow_llama_clear(llm)
            cachedTokens = []
            if !abort.isSet { Self.log.error("Clean-up prompt evaluation failed") }
            return nil
        }
        cachedTokens = prompt
        let prompted = ContinuousClock.now

        var bytes: [UInt8] = []
        var generated = 0
        var ended = false
        var piece = [CChar](repeating: 0, count: 256)
        while generated < cap {
            guard !expired() else { break }
            let token = uflow_llama_sample(llm)
            if uflow_llama_is_eog(llm, token) { ended = true; break }
            generated += 1
            var n = uflow_llama_piece(llm, token, &piece, Int32(piece.count))
            if n < 0 {
                piece = [CChar](repeating: 0, count: Int(-n))
                n = uflow_llama_piece(llm, token, &piece, Int32(piece.count))
            }
            if n > 0 { bytes += piece[..<Int(n)].map { UInt8(bitPattern: $0) } }
            guard evaluate([token], at: cachedTokens.count, llm: llm) else {
                uflow_llama_clear(llm)   // state unknown: reuse none of it
                cachedTokens = []
                break
            }
            cachedTokens.append(token)
        }
        #if DEBUG
        stats = Stats(promptTokens: prompt.count, reusedTokens: reuse, generatedTokens: generated,
                      promptMs: Double((prompted - started) / .microseconds(1)) / 1000,
                      generateMs: Double((ContinuousClock.now - prompted) / .microseconds(1)) / 1000)
        #endif
        guard ended else {
            if expired() {
                Self.log.notice("Clean-up timed out or was cancelled after \(generated, privacy: .public) tokens")
            } else {
                Self.log.notice("Clean-up hit its \(cap, privacy: .public)-token cap without finishing")
            }
            return nil
        }
        return Self.reply(from: String(decoding: bytes, as: UTF8.self))
    }

    /// Strips what Gemma may put around the answer even with thinking off:
    /// an (empty) thought channel, and a stray turn marker.
    static func reply(from raw: String) -> String {
        var text = raw
        while let open = text.range(of: "<|channel>") {
            guard let close = text.range(of: "<channel|>", range: open.upperBound..<text.endIndex) else {
                text.removeSubrange(open.lowerBound...)   // unterminated thought: no answer
                break
            }
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        if let marker = text.range(of: "<turn|>") { text.removeSubrange(marker.lowerBound...) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Queue-confined. Evaluates `tokens` at positions `start...`, with
    /// logits for the last one only.
    private func evaluate(_ tokens: [Int32], at start: Int, llm: OpaquePointer) -> Bool {
        uflow_llama_eval(llm, tokens, Int32(tokens.count), Int32(start)) == 0
    }

    // MARK: - Prompt

    /// The GGUF's Gemma 4 chat template, rendered for plain text turns
    /// without thinking (`enable_thinking` off: no `<|think|>`):
    ///
    ///     <bos><|turn>system\n{system}<turn|>\n
    ///     <|turn>user\n{user}<turn|>\n<|turn>model\n{assistant}<turn|>\n …
    ///     <|turn>user\n{user}<turn|>\n<|turn>model\n
    ///
    /// plus `<|channel>thought\n<channel|>` at the end when the template
    /// pre-fills an empty thought (12B). Content is trimmed as the template trims it. llama.cpp's
    /// `llama_chat_apply_template` has no Gemma 4 entry (only Jinja does), so
    /// this is done here. Markers are tokenized as control tokens and the
    /// texts as plain text, so dictated words can never spell a turn marker.
    /// Queue-confined.
    private func prompt(system: String, shots: [(user: String, assistant: String)], user: String) -> [Int32] {
        var tokens: [Int32] = []
        if let llm, case let bos = uflow_llama_bos(llm), bos >= 0 { tokens.append(bos) }
        func marker(_ s: String) { tokens += tokenize(s, parseSpecial: true) }
        func text(_ s: String) { tokens += tokenize(s.trimmingCharacters(in: .whitespacesAndNewlines), parseSpecial: false) }
        func turn(_ role: String, _ content: String) {
            marker("<|turn>\(role)\n")
            text(content)
            marker("<turn|>\n")
        }
        if !system.isEmpty { turn("system", system) }
        for shot in shots {
            turn("user", shot.user)
            turn("model", shot.assistant)
        }
        turn("user", user)
        marker("<|turn>model\n")
        if emptyThoughtPrefill { marker("<|channel>thought\n<channel|>") }
        return tokens
    }

    /// Queue-confined. No BOS: `prompt` adds it once.
    private func tokenize(_ text: String, parseSpecial: Bool) -> [Int32] {
        guard let llm, !text.isEmpty else { return [] }
        let utf8 = Array(text.utf8CString.dropLast())   // without the NUL
        var tokens = [Int32](repeating: 0, count: utf8.count + 8)
        var count = uflow_llama_tokenize(llm, utf8, Int32(utf8.count), &tokens, Int32(tokens.count), parseSpecial)
        if count < 0 {
            tokens = [Int32](repeating: 0, count: Int(-count))
            count = uflow_llama_tokenize(llm, utf8, Int32(utf8.count), &tokens, Int32(tokens.count), parseSpecial)
        }
        return count > 0 ? Array(tokens.prefix(Int(count))) : []
    }

    #if DEBUG
    /// For `--llm`: the hand-built prompt vs. the same text tokenized in one
    /// piece, and what llama_chat_apply_template makes of the GGUF template.
    func promptCheck(system: String, user: String) -> String {
        queue.sync {
            guard load(), let llm else { return "not loaded" }
            let ours = prompt(system: system, shots: [], user: user)
            let flat = "<|turn>system\n\(system)<turn|>\n<|turn>user\n\(user)<turn|>\n<|turn>model\n"
                + (emptyThoughtPrefill ? "<|channel>thought\n<channel|>" : "")
            var whole = tokenize(flat, parseSpecial: true)
            if case let bos = uflow_llama_bos(llm), bos >= 0 { whole.insert(bos, at: 0) }
            var report = "segment-tokenized prompt == whole-string tokenization: \(ours == whole) (\(ours.count) tokens)\n"
            var buffer = [CChar](repeating: 0, count: 8192)
            let n = uflow_llama_apply_template(llm, system, user, &buffer, Int32(buffer.count))
            report += "llama_chat_apply_template(GGUF template) → "
            report += n < 0 ? "\(n) (unsupported)" : String(cString: buffer).debugDescription
            return report
        }
    }
    #endif
}

/// One cancellable file download with progress. URLSession's async
/// `download` reports no progress, so this is the delegate form wrapped in a
/// continuation (as `WhisperEngine`'s, plus cancel).
private final class LLMDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: (@Sendable (Double) -> Void)?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var task: URLSessionDownloadTask?
    private var cancelled = false

    init(progress: (@Sendable (Double) -> Void)?) { self.progress = progress }

    func run(_ url: URL) async throws -> URL {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.downloadTask(with: url)
            let start = lock.withLock {
                self.continuation = continuation
                self.task = task
                return !cancelled
            }
            if start { task.resume() } else { finish(.failure(CancellationError())) }
        }
    }

    func cancel() {
        let task = lock.withLock { cancelled = true; return self.task }
        task?.cancel()
    }

    private func finish(_ result: Result<URL, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<URL, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
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
                throw LocalLLMError.downloadFailed("HTTP \(http.statusCode)")
            }
            try FileManager.default.moveItem(at: location, to: kept)
            finish(.success(kept))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let wasCancelled = lock.withLock { cancelled }
        finish(.failure(wasCancelled ? CancellationError() : error))
    }
}
