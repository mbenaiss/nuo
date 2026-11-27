@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

/// Streams the mic into on-device speech recognition.
/// Cascade: SpeechTranscriber → DictationTranscriber → SFSpeechRecognizer.
final class LiveTranscriber: @unchecked Sendable {
    enum Engine: String, Sendable {
        case speechTranscriber, dictation, legacy
    }

    let updates: AsyncStream<TranscriptUpdate>
    private let updatesContinuation: AsyncStream<TranscriptUpdate>.Continuation
    /// Yields once if recognition breaks down mid-session (its system service crashing, say); the mic keeps going.
    let failures: AsyncStream<String>
    private let failuresContinuation: AsyncStream<String>.Continuation
    private var failed = false

    private let lock = NSLock()
    private var engine: Engine?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var framesFed: Int64 = 0
    private var turn = 0

    private var recognizer: SFSpeechRecognizer?
    private var legacyRequest: SFSpeechAudioBufferRecognitionRequest?
    private var legacyTask: SFSpeechRecognitionTask?

    init() {
        (updates, updatesContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
        (failures, failuresContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// Seconds of audio fed so far, on the analyzer's timeline.
    var currentTime: TimeInterval {
        lock.withLock {
            guard let rate = analyzerFormat?.sampleRate, rate > 0 else { return 0 }
            return Double(framesFed) / rate
        }
    }

    func start(locale requested: Locale, inputFormat: AVAudioFormat) async throws -> Engine {
        var failures: [String] = []
        do {
            try await startSpeechTranscriber(locale: requested, inputFormat: inputFormat)
            return .speechTranscriber
        } catch {
            failures.append("SpeechTranscriber: \(error.localizedDescription)")
        }
        do {
            try await startDictation(locale: requested, inputFormat: inputFormat)
            return .dictation
        } catch {
            failures.append("DictationTranscriber: \(error.localizedDescription)")
        }
        do {
            try await startLegacy(locale: requested)
            return .legacy
        } catch {
            failures.append("SFSpeechRecognizer: \(error.localizedDescription)")
        }
        NSLog("Nuo voice: transcription unavailable — %@", failures.joined(separator: " | "))
        throw TranscriberError.unavailable
    }

    // MARK: - SpeechAnalyzer

    private func startSpeechTranscriber(locale requested: Locale, inputFormat: AVAudioFormat) async throws {
        guard let locale = await Self.resolve(requested, supported: SpeechTranscriber.supportedLocale(equivalentTo:)) else {
            throw TranscriberError.unsupportedLocale
        }
        let module = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )
        try await Self.installAssets(for: module)
        let results = module.results
        try await startAnalyzer(module: module, inputFormat: inputFormat) { [weak self, updatesContinuation] in
            do {
                for try await result in results {
                    updatesContinuation.yield(TranscriptUpdate(
                        text: String(result.text.characters),
                        isFinal: result.isFinal,
                        start: result.range.start.seconds.isFinite ? result.range.start.seconds : nil,
                        end: result.range.end.seconds.isFinite ? result.range.end.seconds : nil
                    ))
                }
                self?.reportFailure("transcriber results ended")
            } catch {
                self?.reportFailure("transcriber results ended — \(error)")
            }
        }
        lock.withLock { engine = .speechTranscriber }
    }

    private func startDictation(locale requested: Locale, inputFormat: AVAudioFormat) async throws {
        guard let locale = await Self.resolve(requested, supported: DictationTranscriber.supportedLocale(equivalentTo:)) else {
            throw TranscriberError.unsupportedLocale
        }
        let module = DictationTranscriber(
            locale: locale,
            contentHints: [.shortForm],
            transcriptionOptions: [.punctuation],
            reportingOptions: [.volatileResults, .frequentFinalization],
            attributeOptions: [.audioTimeRange]
        )
        let reserved = await AssetInventory.reservedLocales
        if !reserved.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            _ = try? await AssetInventory.reserve(locale: locale)
        }
        try await Self.installAssets(for: module)
        let results = module.results
        try await startAnalyzer(module: module, inputFormat: inputFormat) { [weak self, updatesContinuation] in
            do {
                for try await result in results {
                    updatesContinuation.yield(TranscriptUpdate(
                        text: String(result.text.characters),
                        isFinal: result.isFinal,
                        start: result.range.start.seconds.isFinite ? result.range.start.seconds : nil,
                        end: result.range.end.seconds.isFinite ? result.range.end.seconds : nil
                    ))
                }
                self?.reportFailure("dictation results ended")
            } catch {
                self?.reportFailure("dictation results ended — \(error)")
            }
        }
        lock.withLock { engine = .dictation }
    }

    private func startAnalyzer(module: any SpeechModule, inputFormat: AVAudioFormat, consume: @escaping @Sendable () async -> Void) async throws {
        // Speech models want 16 kHz mono Int16; handing them the raw mic format traps in AnalyzerInput.
        let fallback = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: inputFormat) ?? fallback,
              let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw TranscriberError.unavailable
        }
        let analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .userInitiated, modelRetention: .whileInUse))
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        let task = Task.detached(priority: .userInitiated) { await consume() }
        try await analyzer.start(inputSequence: stream)
        lock.withLock {
            self.analyzer = analyzer
            self.inputContinuation = continuation
            self.resultsTask = task
            self.converter = converter
            self.analyzerFormat = format
            self.framesFed = 0
        }
    }

    private static func resolve(_ requested: Locale, supported: (Locale) async -> Locale?) async -> Locale? {
        if let match = await supported(requested) { return match }
        return await supported(Locale(identifier: "fr-FR"))
    }

    private static func installAssets(for module: any SpeechModule) async throws {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        guard await AssetInventory.status(forModules: [module]) == .installed else {
            throw TranscriberError.assetsMissing
        }
    }

    // MARK: - SFSpeechRecognizer fallback

    private func startLegacy(locale requested: Locale) async throws {
        guard await Self.requestSpeechAuthorization() else { throw TranscriberError.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: requested) ?? SFSpeechRecognizer(locale: Locale(identifier: "fr-FR")),
              recognizer.isAvailable else {
            throw TranscriberError.unavailable
        }
        lock.withLock {
            self.recognizer = recognizer
            self.engine = .legacy
            self.analyzerFormat = nil
        }
        startLegacyRequest(turn: 0)
    }

    private func startLegacyRequest(turn: Int) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        let recognizer: SFSpeechRecognizer? = lock.withLock { self.recognizer }
        guard let recognizer else { return }
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        let continuation = updatesContinuation
        let task = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            // Its service crashed or dropped the connection: asking again would only crash it again.
            if let error, result == nil, RecognizerFailure.isServiceFailure(error) {
                self?.reportFailure("recognizer service failed — \(error)")
                return
            }
            if let result {
                continuation.yield(TranscriptUpdate(
                    text: result.bestTranscription.formattedString,
                    isFinal: result.isFinal,
                    start: nil,
                    end: nil,
                    turn: turn
                ))
            }
            // The legacy recognizer gives up after ~1 min or on long silences: keep a request open.
            if error != nil || result?.isFinal == true {
                guard let self else { return }
                let stillCurrent = self.lock.withLock { self.turn == turn && self.recognizer != nil }
                if stillCurrent { self.startLegacyRequest(turn: turn) }
            }
        }
        let previous: SFSpeechRecognitionTask? = lock.withLock {
            let previous = legacyTask
            legacyRequest = request
            legacyTask = task
            return previous
        }
        if previous !== task { previous?.finish() }
    }

    /// Once per session, and never for the end of a session being stopped (`engine` is cleared first).
    private func reportFailure(_ reason: String) {
        let first = lock.withLock { () -> Bool in
            guard engine != nil, !failed else { return false }
            failed = true
            return true
        }
        guard first else { return }
        NSLog("Nuo voice: recognition broke down — %@", reason)
        failuresContinuation.yield(reason)
    }

    nonisolated private static func requestSpeechAuthorization() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    // MARK: - Feeding (audio thread)

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let engine = engine
        let continuation = inputContinuation
        let converter = converter
        let format = analyzerFormat
        let request = legacyRequest
        lock.unlock()

        switch engine {
        case .legacy:
            request?.append(buffer)
        case .speechTranscriber, .dictation:
            guard let continuation, let converter, let format,
                  let converted = Self.convert(buffer, with: converter, to: format) else { return }
            lock.withLock { framesFed += Int64(converted.frameLength) }
            continuation.yield(AnalyzerInput(buffer: converted))
        case nil:
            break
        }
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }

    // MARK: - Turns

    /// Marks the start of a new user utterance; returns the boundary and turn id for the accumulator.
    func beginTurn() -> (boundary: TimeInterval, turn: Int) {
        let (newTurn, isLegacy, analyzer) = lock.withLock { () -> (Int, Bool, SpeechAnalyzer?) in
            turn += 1
            return (turn, engine == .legacy, self.analyzer)
        }
        let boundary = currentTime
        if let analyzer {
            // Close the volatile range at the boundary so the next utterance starts in a fresh result.
            let time = CMTime(seconds: boundary, preferredTimescale: 16000)
            Task.detached { try? await analyzer.finalize(through: time) }
        }
        if isLegacy {
            let old: SFSpeechAudioBufferRecognitionRequest? = lock.withLock { legacyRequest }
            old?.endAudio()
            startLegacyRequest(turn: newTurn)
        }
        return (boundary, newTurn)
    }

    func stop() async {
        let (analyzer, continuation, task, legacyTask, legacyRequest) = lock.withLock {
            let snapshot = (self.analyzer, inputContinuation, resultsTask, self.legacyTask, self.legacyRequest)
            self.analyzer = nil
            inputContinuation = nil
            resultsTask = nil
            self.legacyTask = nil
            self.legacyRequest = nil
            recognizer = nil
            engine = nil
            return snapshot
        }
        continuation?.finish()
        legacyRequest?.endAudio()
        legacyTask?.cancel()
        await analyzer?.cancelAndFinishNow()
        task?.cancel()
        updatesContinuation.finish()
        failuresContinuation.finish()
    }
}
