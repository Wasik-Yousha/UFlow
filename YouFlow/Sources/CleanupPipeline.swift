import Combine
import Foundation

/// The on-device clean-up step, end to end: the local model suggests a cleaned
/// version of the dictation and `CleanupGuard` decides what survives. The
/// model can only delete words it can prove were stumbles, add punctuation and
/// casing, and (English) lay out lists and paragraphs from the spoken words.
///
/// Never in the way: if the model isn't downloaded, the Mac is under memory
/// pressure or hot, the dictation is too short to need it, or either pass runs
/// past the budget, the text goes through exactly as transcribed.
struct TextCleaner: Sendable {
    let llm: LocalLLM

    /// Below this many words there is nothing to clean but punctuation, and a
    /// one- or two-word reply ("ok", "thik ache") is better left as said.
    static let minimumWords = 3

    /// Both passes together, scaled with length: an answer has to be written
    /// word by word, so a fixed limit cut long dictations off and they went
    /// out uncleaned (12B: every 60-word email hit a flat 2.5 s). Short
    /// replies stay quick. ponytail: per-word cost measured on M4 Pro with
    /// 12B; slower Macs run smaller models, which are faster per word.
    static func budget(words: Int) -> Duration {
        min(.milliseconds(2000) + .milliseconds(40) * words, .milliseconds(6000))
    }

    func clean(_ text: String) async -> String {
        let words = text.split(whereSeparator: \.isWhitespace).count
        guard words >= Self.minimumWords, llm.isDownloaded else { return text }
        guard !llm.shouldSkip else {
            Log.speech.info("Clean-up skipped: memory pressure, heat or Low Power Mode")
            return text
        }
        let started = ContinuousClock.now
        let budget = Self.budget(words: words)
        guard let pass1 = await llm.generate(system: CleanupPrompts.system, shots: CleanupPrompts.shots,
                                             user: text, timeout: budget) else {
            Log.speech.info("Clean-up gave no usable answer in time — text kept as transcribed")
            return text
        }
        let raw = CleanupPrompts.pass1Output(pass1)

        var layoutRaw: String?
        if let request = CleanupGuard.layoutRequest(spoken: text, cleanRaw: raw) {
            let left = budget - (ContinuousClock.now - started)
            if left > .milliseconds(200),
               let pass2 = await llm.generate(system: CleanupPrompts.layoutSystem,
                                              shots: CleanupPrompts.layoutShots,
                                              user: request, timeout: left) {
                layoutRaw = CleanupPrompts.layoutOutput(pass2)
            }
        }

        let final = CleanupGuard.finalize(spoken: text, cleanRaw: raw, layoutRaw: layoutRaw)
        let elapsed = ContinuousClock.now - started
        Log.speech.info("Clean-up done in \(String(describing: elapsed), privacy: .public)\(layoutRaw == nil ? "" : " (with layout)", privacy: .public)")
        return final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : final
    }
}

/// The clean-up model for this Mac, as Settings shows it.
///
/// One model per Mac, chosen by memory (`CleanupModel.forThisMac`): 8 GB
/// Macs get Gemma 4 E2B, 16 GB get E4B, 18 GB and up get 12B. Nothing ships
/// inside the app; Download fetches the file from Hugging Face, checks its
/// SHA-256 and keeps it in Application Support.
@MainActor
final class CleanupController: ObservableObject {
    enum Phase: Equatable {
        case notDownloaded
        case downloading(Double)
        case ready
        case failed(String)
    }

    /// The models this Mac's memory allows; more than one only at 18 GB+.
    let choices = CleanupModel.choicesForThisMac()
    @Published private(set) var model: CleanupModel
    private(set) var llm: LocalLLM
    @Published private(set) var phase: Phase
    private static let choiceKey = "cleanup.model"
    private var download: Task<Void, Never>?

    /// The model clean-up actually runs on: this Mac's own model when it is
    /// installed, otherwise the largest smaller one already on disk, so a
    /// 24 GB Mac still cleans up with E4B while its 12B downloads. Never a
    /// model above this Mac's tier. Nil when none is installed.
    @Published private(set) var active: LocalLLM?

    init() {
        let allowed = CleanupModel.choicesForThisMac()
        let stored = UserDefaults.standard.string(forKey: Self.choiceKey).flatMap(CleanupModel.init(rawValue:))
        let chosen = stored.flatMap { allowed.contains($0) ? $0 : nil } ?? allowed[0]
        model = chosen
        llm = LocalLLM(model: chosen)
        phase = chosen.isDownloaded ? .ready : .notDownloaded
        refresh()
    }

    /// Switches this Mac's model (Settings picker). A download in progress
    /// for the old choice is cancelled; the new one needs its own Download
    /// unless it is already on disk.
    func choose(_ choice: CleanupModel) {
        guard choice != model, choices.contains(choice) else { return }
        cancelDownload()
        download = nil
        model = choice
        llm = LocalLLM(model: choice)
        phase = choice.isDownloaded ? .ready : .notDownloaded
        UserDefaults.standard.set(choice.rawValue, forKey: Self.choiceKey)
        refresh()
    }

    /// Clean-up can run (some suitable model is installed).
    var isReady: Bool { active != nil }

    /// Re-reads what is on disk. Cheap (file sizes); called at every
    /// dictation, so a download finished elsewhere is picked up at once.
    func refresh() {
        if model.isDownloaded, case .notDownloaded = phase { phase = .ready }
        let best = CleanupModel.allCases
            .filter { $0.bytes <= model.bytes && $0.isDownloaded }
            .max { $0.bytes < $1.bytes }
        guard best != active?.model || (best == model && active !== llm) else { return }
        active?.unload()
        active = best.map { $0 == model ? llm : LocalLLM(model: $0) }
        if let best { Log.app.info("Clean-up uses \(best.displayName, privacy: .public)") }
    }

    /// Shown in Settings when a smaller model stands in for this Mac's own.
    var standIn: CleanupModel? {
        guard let active, active.model != model else { return nil }
        return active.model
    }

    /// Human-readable size of the download, e.g. "2.8 GB".
    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file)
    }

    var memoryText: String {
        let gib = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
        return "\(gib) GB"
    }

    func startDownload() {
        guard download == nil, phase != .ready else { return }
        phase = .downloading(0)
        download = Task { [weak self, llm] in
            do {
                try await llm.prepare { fraction in
                    Task { @MainActor [weak self] in
                        guard let self, case .downloading = self.phase else { return }
                        self.phase = .downloading(fraction)
                    }
                }
                self?.phase = .ready
                self?.refresh()
                Log.app.info("Clean-up model installed")
            } catch is CancellationError {
                self?.phase = .notDownloaded
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
            self?.download = nil
        }
    }

    func cancelDownload() {
        llm.cancelDownload()
        download?.cancel()
    }

    func remove() {
        llm.unload()
        try? llm.delete()
        phase = .notDownloaded
        refresh()
    }

    /// Load while the user is still talking, so the release doesn't wait.
    func warmUp() {
        // Under critical memory pressure clean-up is skipped anyway; loading
        // gigabytes into a starved Mac would only make it worse.
        refresh()
        guard let active, !active.shouldSkip else { return }
        active.preload()
    }
}
