@preconcurrency import AVFoundation
import Foundation

/// Mic capture for dictation: keeps the whole take as 16 kHz mono floats, transcribed once it ends.
final class DictationRecorder: DictationMic, @unchecked Sendable {
    private let lock = NSLock()
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private var levelValue: Float = 0
    private static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(WhisperEngine.sampleRate), channels: 1, interleaved: false)!

    /// Smoothed 0...1 input level for the meter.
    var level: Float { lock.withLock { levelValue } }

    var recording: [Float] { lock.withLock { samples } }

    var engineID: ObjectIdentifier { ObjectIdentifier(engine) }

    /// Blocking daemon round-trip: call off the main thread.
    static func activateSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers])
        try session.setActive(true)
        #endif
    }

    static func deactivateSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let converter = AVAudioConverter(from: format, to: Self.targetFormat) else {
            throw TranscriberError.unavailable
        }
        lock.withLock {
            self.converter = converter
            samples = []
            samples.reserveCapacity(WhisperEngine.sampleRate * 60)
            levelValue = 0
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.withLock { levelValue = 0 }
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        let normalized = Self.normalizedLevel(buffer)
        let converter = lock.withLock { () -> AVAudioConverter? in
            levelValue += (normalized - levelValue) * (normalized > levelValue ? 0.6 : 0.2)
            return self.converter
        }
        guard let converter, let converted = Self.convert(buffer, with: converter) else { return }
        guard let data = converted.floatChannelData?[0] else { return }
        let chunk = UnsafeBufferPointer(start: data, count: Int(converted.frameLength))
        lock.withLock { samples.append(contentsOf: chunk) }
    }

    private static func normalizedLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let data = buffer.floatChannelData?[0] else { return 0 }
        var sum: Float = 0
        for index in 0..<frames { sum += data[index] * data[index] }
        let rms = sqrt(sum / Float(frames))
        guard rms > 0 else { return 0 }
        return min(max((20 * log10(rms) + 55) / 45, 0), 1)
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
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
}
