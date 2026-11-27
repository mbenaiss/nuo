@preconcurrency import AVFoundation
import Foundation

/// 16 kHz mono speech as AAC in an .m4a, the format sent to the gateway for transcription: 48 kbit/s is the most the
/// encoder takes at 16 kHz and keeps the voice intact, five times smaller than 16-bit PCM. A minute of dictation is
/// about 380 KB instead of 1.9 MB, encoded in some 40 ms.
final class AACWriter {
    static let sampleRate = 16_000
    static let bitRate = 48_000
    nonisolated(unsafe) static let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: bitRate,
    ]
    private static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!

    let url: URL
    private var file: AVAudioFile?
    private(set) var samplesWritten = 0

    init(url: URL, bitRate: Int = AACWriter.bitRate) throws {
        self.url = url
        try? FileManager.default.removeItem(at: url)
        var settings = Self.settings
        settings[AVEncoderBitRateKey] = bitRate
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func append(_ samples: [Float]) throws {
        guard let file, !samples.isEmpty else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { throw CocoaError(.fileWriteUnknown) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
        samplesWritten += samples.count
    }

    /// Flushes the encoder and the file's index: the file is complete once this returns.
    func close() {
        file?.close()
        file = nil
    }

    /// The whole take at once; the caller removes the file.
    static func encode(_ samples: [Float], to url: URL) throws -> Data {
        let writer = try AACWriter(url: url)
        try writer.append(samples)
        writer.close()
        return try Data(contentsOf: url)
    }
}
