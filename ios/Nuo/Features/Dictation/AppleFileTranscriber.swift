@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

/// Apple's on-device recognizer (SpeechAnalyzer) over a finished recording, in one pass: the last fallback of dictation
/// and of meetings. The model runs in a system service, so the app itself stays small.
enum AppleFileTranscriber {
    private static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    /// The supported variant of `locale`, once the system has its model (downloaded the first time).
    static func prepare(_ locale: Locale) async throws -> Locale {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { throw TranscriberError.unsupportedLocale }
        let module = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        guard await AssetInventory.status(forModules: [module]) == .installed else { throw TranscriberError.assetsMissing }
        return supported
    }

    /// Phrases with their times in seconds from the start of `samples` (16 kHz mono).
    static func transcribe(_ samples: [Float], locale: Locale) async throws -> [WhisperPass.Segment] {
        let url = URL.temporaryDirectory.appending(path: "speech-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        try write(samples, to: url)
        let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        let analyzer = SpeechAnalyzer(modules: [module])
        let results = module.results
        let collector = Task {
            var segments: [WhisperPass.Segment] = []
            for try await result in results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let start = result.range.start.seconds, end = result.range.end.seconds
                segments.append(.init(text: text, start: start.isFinite ? start : 0, end: end.isFinite ? end : nil))
            }
            return segments
        }
        do {
            try await withTaskCancellationHandler {
                let file = try AVAudioFile(forReading: url)
                if let last = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: last)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
        } catch {
            // The results stream only ends once the analyzer finishes: without this the collector waits forever.
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            throw error
        }
        return try await collector.value
    }

    /// The file is closed when it goes out of scope, before the analyzer reads it.
    private static func write(_ samples: [Float], to url: URL) throws {
        guard !samples.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { throw TranscriberError.unavailable }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}
