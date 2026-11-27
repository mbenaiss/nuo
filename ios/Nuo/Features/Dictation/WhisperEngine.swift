import CoreML
import Foundation
@preconcurrency import WhisperKit

/// One Whisper pass over a slice of audio.
struct WhisperPass: Sendable {
    struct Segment: Sendable {
        var text: String
        /// Seconds from the start of the slice.
        var start: Double
        var end: Double?
    }

    var segments: [Segment]
    var language: String

    var text: String { WhisperText.join(segments.map(\.text)) }
}

/// Holds the loaded model: loaded lazily, kept warm a few minutes after the last use, dropped under memory pressure.
actor WhisperEngine {
    static let shared = WhisperEngine()

    static let sampleRate = 16_000
    private static let keepWarm: Duration = .seconds(120)

    // WhisperKit is not Sendable yet; the actor is its only user.
    private final class Box: @unchecked Sendable {
        let kit: WhisperKit
        init(_ kit: WhisperKit) { self.kit = kit }
    }

    private var box: Box?
    private var loadedModel: WhisperModel?
    private var loading: (model: WhisperModel, task: Task<Box, Error>)?
    private var busy = 0
    /// Long jobs (meeting transcription) that need the model across several passes.
    private var holders = 0
    private var idleTask: Task<Void, Never>?
    private var pressureSource: DispatchSourceMemoryPressure?

    var computeDescription: String {
        guard let compute = box?.kit.modelCompute else { return "not loaded" }
        func name(_ units: MLComputeUnits) -> String {
            switch units {
            case .cpuOnly: "CPU"
            case .cpuAndGPU: "CPU+GPU"
            case .cpuAndNeuralEngine: "CPU+ANE"
            case .all: "all"
            @unknown default: "?"
            }
        }
        return "mel \(name(compute.melCompute)), encoder \(name(compute.audioEncoderCompute)), decoder \(name(compute.textDecoderCompute))"
    }

    func isReady(_ model: WhisperModel) -> Bool { box != nil && loadedModel == model }

    /// Loads `model` in place of the one loaded, unless that one is in use: then it stays, and serves the caller too.
    /// `holding` when the caller already holds the engine, so its own hold does not count as a use.
    func load(_ model: WhisperModel, folder: URL, tokenizerBase: URL = DictationModelStore.root, holding: Bool = false) async throws {
        if box != nil, loadedModel == model {
            scheduleIdleUnload()
            return
        }
        if let loading, loading.model == model {
            _ = try await loading.task.value
            return
        }
        if box != nil, WhisperUsage.inUse(busy: busy, holders: holders, callerHolds: holding) {
            dictationLog.notice("Whisper \(model.variant, privacy: .public) not loaded: \(self.loadedModel?.variant ?? "?", privacy: .public) is in use")
            return
        }
        await unloadNow()
        let task = Task.detached(priority: .userInitiated) { () throws -> Box in
            try await Self.build(model, folder: folder, tokenizerBase: tokenizerBase)
        }
        loading = (model, task)
        defer { if loading?.model == model { loading = nil } }
        let loaded = try await task.value
        box = loaded
        loadedModel = model
        dictationLog.notice("Whisper \(model.variant, privacy: .public) loaded: \(self.computeDescription, privacy: .public)")
        watchMemoryPressure()
        scheduleIdleUnload()
    }

    /// The Neural Engine first, as it is the fastest; where Core ML cannot build a model for it (large-v3 turbo on
    /// an M1: "Error plan build", or a compile that never ends) the GPU instead, remembered for this system build.
    private static func build(_ model: WhisperModel, folder: URL, tokenizerBase: URL) async throws -> Box {
        let key = "nuo.dictation.gpuOnly.\(model.rawValue)"
        let osBuild = ProcessInfo.processInfo.operatingSystemVersionString
        let forced = ProcessInfo.processInfo.arguments.contains("-whisperGPU")
        if forced || UserDefaults.standard.string(forKey: key) == osBuild {
            return try await kit(folder, tokenizerBase, .cpuAndGPU)
        }
        let ane = Task.detached(priority: .userInitiated) { try await kit(folder, tokenizerBase, .cpuAndNeuralEngine) }
        let outcome = await race(ane, timeout: aneBudget)
        if case let .success(box) = outcome { return box }
        dictationLog.error("Whisper \(model.variant, privacy: .public) failed on the Neural Engine (\(String(describing: outcome), privacy: .public)), loading on the GPU")
        UserDefaults.standard.set(osBuild, forKey: key)
        return try await kit(folder, tokenizerBase, .cpuAndGPU)
    }

    /// A first Neural Engine compile of the large model takes about a minute on recent chips.
    private static let aneBudget: Duration = .seconds(150)

    private static func kit(_ folder: URL, _ tokenizerBase: URL, _ units: MLComputeUnits) async throws -> Box {
        let config = WhisperKitConfig(
            modelFolder: folder.path,
            tokenizerFolder: tokenizerBase,
            computeOptions: ModelComputeOptions(melCompute: .cpuAndGPU, audioEncoderCompute: units, textDecoderCompute: units),
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: false
        )
        return Box(try await WhisperKit(config))
    }

    private enum LoadOutcome: Sendable {
        case success(Box)
        case failure(String)
    }

    /// The load's result, or a timeout; a late load is left to finish and is dropped.
    private static func race(_ load: Task<Box, Error>, timeout: Duration) async -> LoadOutcome {
        let once = ResumeOnce()
        return await withCheckedContinuation { continuation in
            Task {
                let outcome: LoadOutcome
                do { outcome = .success(try await load.value) } catch { outcome = .failure(String(describing: error)) }
                if once.claim() { continuation.resume(returning: outcome) }
            }
            Task {
                try? await Task.sleep(for: timeout)
                if once.claim() { continuation.resume(returning: .failure("no answer after \(timeout)")) }
            }
        }
    }

    func hold() {
        holders += 1
        idleTask?.cancel()
    }

    func release() {
        holders = max(0, holders - 1)
        if box != nil { scheduleIdleUnload() }
    }

    /// One pass over a whole recording. `prompt` (the vocabulary) biases the spelling of proper nouns.
    func transcribe(_ samples: [Float], language: String, prompt: String) async throws -> WhisperPass {
        guard let box else { throw TranscriberError.unavailable }
        busy += 1
        idleTask?.cancel()
        defer {
            busy -= 1
            scheduleIdleUnload()
        }
        let kit = box.kit
        var promptTokens: [Int]?
        if !prompt.isEmpty, let tokenizer = kit.tokenizer {
            let begin = tokenizer.specialTokens.specialTokenBegin
            // Whisper reads at most 224 prompt tokens.
            promptTokens = Array(tokenizer.encode(text: " " + prompt).filter { $0 < begin }.suffix(200))
        }
        // Sequential 30 s windows that resume after the last timestamp. VAD chunking is not used: with a prompt, Whisper
        // often ends a chunk after its first sentence and the rest of that chunk is lost (measured: 28 % WER, whole
        // sentences missing), and without one it invents captions in the pauses.
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            temperatureFallbackCount: 2,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: false,
            promptTokens: promptTokens
        )
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        var segments: [WhisperPass.Segment] = []
        for result in results {
            for segment in result.segments {
                let text = WhisperText.clean(segment.text)
                if !text.isEmpty { segments.append(.init(text: text, start: Double(segment.start), end: Double(segment.end))) }
            }
        }
        return WhisperPass(segments: segments, language: results.first?.language ?? language)
    }

    /// French unless Whisper is confident the speaker uses another language.
    func detectLanguage(_ samples: [Float]) async -> String {
        guard let guess = await guessLanguage(samples) else { return "fr" }
        return guess.language == "fr" || guess.probability > 0.8 ? guess.language : "fr"
    }

    /// The most likely language of the first 30 s and its probability.
    func guessLanguage(_ samples: [Float]) async -> (language: String, probability: Double)? {
        guard let box, let detected = try? await box.kit.detectLangauge(audioArray: samples) else { return nil }
        return (detected.language, Double(exp(detected.langProbs[detected.language] ?? -.infinity)))
    }

    func unload(ifUsing model: WhisperModel) async {
        if let loading, loading.model == model { loading.task.cancel() }
        if loadedModel == model { await unloadNow() }
    }

    private func unloadNow() async {
        idleTask?.cancel()
        idleTask = nil
        guard let box else { return }
        self.box = nil
        loadedModel = nil
        await box.kit.unloadModels()
    }

    private func scheduleIdleUnload() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.keepWarm)
            guard !Task.isCancelled else { return }
            await self?.unloadIfIdle()
        }
    }

    private func unloadIfIdle() async {
        guard busy == 0, holders == 0 else { return }
        await unloadNow()
    }

    private func unloadUnderPressure() async {
        guard !WhisperUsage.inUse(busy: busy, holders: holders, callerHolds: false) else { return }
        await unloadNow()
    }

    private func watchMemoryPressure() {
        guard pressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            Task { await self?.unloadUnderPressure() }
        }
        source.resume()
        pressureSource = source
    }
}

enum WhisperText {
    /// Phrases Whisper invents on silence or noise (it learned them from subtitled videos).
    private static let hallucinations = [
        "sous-titres réalisés par", "sous-titrage", "amara.org", "merci d'avoir regardé", "abonnez-vous",
        "thank you for watching", "thanks for watching", "sous-titres fait par",
    ]

    /// Drops only the sentences holding an invented caption: a segment can carry real words before it.
    static func clean(_ text: String) -> String {
        var kept: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
            guard let sentence else { return }
            let lower = sentence.lowercased()
            if !hallucinations.contains(where: lower.contains) { kept.append(sentence) }
        }
        let trimmed = kept.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.allSatisfy({ $0.isPunctuation || $0.isWhitespace }) { return "" }
        return trimmed
    }

    /// `[BLANK_AUDIO]`, `[Music]`, `(rires)`: what Whisper writes for anything but speech.
    static func withoutSoundTags(_ text: String) -> String {
        text.replacing(/\[[^\]]*\]|\([^)]*\)|\*[^*]*\*/, with: "")
    }

    static func join(_ parts: [String]) -> String {
        parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

