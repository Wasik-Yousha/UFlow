import AVFAudio
import FluidAudio
import Foundation

/// What AppState needs from a transcription backend.
///
/// Both engines are actors, which is what serializes sessions: there can only
/// ever be one recording in flight because the actor says so.
protocol TranscriptionEngine: Actor {
    /// Gets the backend ready. `progressHandler` reports 0…1 while assets
    /// download, which is the whole reason it exists — Parakeet's models are
    /// large enough that the user has to be shown something.
    func prepare(progressHandler: (@Sendable (Double) -> Void)?) async throws

    /// Words the recognizer should lean toward. Honoured where the backend
    /// supports it and ignored where it does not; the dictionary's correction
    /// pass runs afterwards either way.
    func setBiasTerms(_ terms: [String])

    func startRecording(onLevel: (@Sendable (Float) -> Void)?) async throws
    func stopRecordingAndCollect() async -> String
    func cancelSession() async

    var activeBackendName: String { get }
}

extension SpeechEngine: TranscriptionEngine {}

// MARK: - Parakeet

enum ParakeetEngineError: LocalizedError {
    case notPrepared
    case sessionAlreadyActive
    case microphoneFormatUnavailable
    case audioStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .notPrepared: "The Parakeet model is not loaded yet."
        case .sessionAlreadyActive: "A dictation session is already running."
        case .microphoneFormatUnavailable: "Microphone input format is unavailable."
        case .audioStartFailed(let detail): "Could not start audio capture: \(detail)"
        }
    }
}

/// NVIDIA Parakeet running on CoreML, via FluidAudio.
///
/// This is the backend for Macs that cannot run Apple's `SpeechAnalyzer`
/// (anything before macOS 26), and it is selectable everywhere else so it can
/// actually be tested rather than only theorised about.
///
/// The weights are ~600 MB and are *not* in the app bundle — that is what keeps
/// the download at a few megabytes. They are fetched once on first use into
/// `~/Library/Application Support/FluidAudio/Models` and reused forever after.
///
/// Unlike the Apple backend this one is not streaming: audio is buffered while
/// you talk and decoded in one pass when you stop. On an M-series Mac that pass
/// runs around 90× realtime, so a minute of speech resolves in well under a
/// second and the difference is not perceptible at dictation lengths.
actor ParakeetEngine: TranscriptionEngine {
    private struct ActiveSession {
        let audioEngine: AVAudioEngine
        let inputNode: AVAudioInputNode
    }

    private let asr = UnifiedAsrManager()
    private var isLoaded = false
    private var activeSession: ActiveSession?

    var activeBackendName: String { "Parakeet" }

    /// Whether the weights are already on disk, so the UI can tell the
    /// difference between "will take four minutes" and "will take four seconds".
    ///
    /// ponytail: "non-empty directory" is the whole test, so a download killed
    /// halfway still reads as present. `prepare()` re-fetches what is missing,
    /// so the cost is a briefly wrong label rather than a broken engine. Verify
    /// the individual model files if that ever stops being true.
    nonisolated static var modelsAreDownloaded: Bool {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return false
        }
        return !contents.isEmpty
    }

    // MARK: - Preparation

    func prepare(progressHandler: (@Sendable (Double) -> Void)? = nil) async throws {
        guard !isLoaded else { return }
        Log.speech.info("Loading Parakeet models")
        try await asr.loadModels(to: nil, configuration: nil) { progress in
            progressHandler?(progress.fractionCompleted)
        }
        isLoaded = true
        Log.speech.info("Parakeet ready")
    }

    /// Parakeet exposes no contextual-bias hook, so this is deliberately a
    /// no-op. The dictionary still applies: `CorrectionEngine` runs on the
    /// output regardless of which backend produced it.
    func setBiasTerms(_ terms: [String]) {
        guard !terms.isEmpty else { return }
        Log.speech.info("Parakeet has no bias hook; \(terms.count, privacy: .public) term(s) will be applied by the correction pass instead")
    }

    // MARK: - Session

    func startRecording(onLevel: (@Sendable (Float) -> Void)? = nil) async throws {
        guard isLoaded else { throw ParakeetEngineError.notPrepared }
        guard activeSession == nil else { throw ParakeetEngineError.sessionAlreadyActive }

        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw ParakeetEngineError.microphoneFormatUnavailable
        }

        // FluidAudio resamples to the 16 kHz mono the model wants, so the tap
        // hands over the hardware format untouched.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [asr] buffer, _ in
            onLevel?(Self.normalizedLevel(of: buffer))
            guard let copy = buffer.deepCopy() else { return }
            Task { try? await asr.appendAudio(copy) }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw ParakeetEngineError.audioStartFailed(error.localizedDescription)
        }

        activeSession = ActiveSession(audioEngine: audioEngine, inputNode: inputNode)
        Log.speech.info("Parakeet recording started")
    }

    func stopRecordingAndCollect() async -> String {
        guard let session = activeSession else { return "" }
        session.inputNode.removeTap(onBus: 0)
        session.audioEngine.stop()
        activeSession = nil

        do {
            let text = try await asr.finish()
            Log.speech.info("Parakeet transcript collected (\(text.isEmpty ? "empty" : "non-empty", privacy: .public))")
            return TranscriptAccumulator.normalize(text)
        } catch {
            Log.speech.error("Parakeet decode failed: \(error.localizedDescription, privacy: .public)")
            return ""
        }
    }

    func cancelSession() async {
        guard let session = activeSession else { return }
        session.inputNode.removeTap(onBus: 0)
        session.audioEngine.stop()
        activeSession = nil
        // Drain whatever was buffered so it cannot leak into the next take.
        _ = try? await asr.finish()
        Log.speech.info("Parakeet session cancelled")
    }

    // MARK: - Level

    /// Same perceptual mapping as the Apple backend, so the VU needle behaves
    /// identically whichever engine is running. See `SpeechEngine` for why
    /// `floorDB` is the calibration knob.
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
}

// MARK: - Buffer copying

extension AVAudioPCMBuffer {
    /// The tap's buffer is reused by the audio unit the moment the callback
    /// returns, so anything handed to another task has to be a copy.
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }
        copy.frameLength = frameLength
        let channels = Int(format.channelCount)
        if let source = floatChannelData, let destination = copy.floatChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: Int(frameLength))
            }
            return copy
        }
        if let source = int16ChannelData, let destination = copy.int16ChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: Int(frameLength))
            }
            return copy
        }
        return nil
    }
}
