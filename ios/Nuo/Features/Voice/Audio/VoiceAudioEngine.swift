@preconcurrency import AVFoundation
import Foundation

/// Smoothed input/output levels (0...1), written from audio threads and read by the orb every frame.
final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var inputValue: Float = 0
    private var outputValue: Float = 0

    var input: Float { lock.withLock { inputValue } }
    var output: Float { lock.withLock { outputValue } }

    func pushInput(db: Float) { lock.withLock { inputValue = Self.smooth(inputValue, Self.normalize(db)) } }
    func pushOutput(db: Float) { lock.withLock { outputValue = Self.smooth(outputValue, Self.normalize(db)) } }
    func reset() { lock.withLock { inputValue = 0; outputValue = 0 } }

    private static func normalize(_ db: Float) -> Float {
        guard db.isFinite else { return 0 }
        return min(max((db + 55) / 45, 0), 1)
    }

    // Fast attack, slow release: the orb jumps with syllables and settles gently.
    private static func smooth(_ current: Float, _ target: Float) -> Float {
        current + (target - current) * (target > current ? 0.6 : 0.15)
    }
}

enum AudioLevel {
    static func rmsDecibels(_ buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return -120 }
        var sum: Float = 0
        if let data = buffer.floatChannelData?[0] {
            for index in 0..<frames { sum += data[index] * data[index] }
        } else if let data = buffer.int16ChannelData?[0] {
            for index in 0..<frames {
                let sample = Float(data[index]) / 32768
                sum += sample * sample
            }
        } else {
            return -120
        }
        let rms = sqrt(sum / Float(frames))
        return rms > 0 ? 20 * log10(rms) : -120
    }
}

/// Owns the AVAudioEngine shared by the mic (voice-processed, echo-cancelled) and the TTS player.
/// TTS goes through the same engine on purpose: the echo canceller only removes what this
/// engine's output unit plays, so speech played elsewhere would be heard back by the mic.
final class VoiceAudioEngine: @unchecked Sendable {
    typealias InputHandler = @Sendable (AVAudioPCMBuffer, _ levelDB: Float, _ time: TimeInterval) -> Void

    let meter = LevelMeter()

    private let lock = NSLock()
    // Serializes graph mutations (main thread) against scheduling (synthesizer callback thread).
    private let graphLock = NSRecursiveLock()
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1)!
    private var inputHandler: InputHandler?
    private var inputEnabledValue = true
    private var resampler: AVAudioConverter?
    private(set) var voiceProcessingActive = false
    private(set) var isRunning = false

    var inputEnabled: Bool {
        get { lock.withLock { inputEnabledValue } }
        set { lock.withLock { inputEnabledValue = newValue } }
    }

    var inputFormat: AVAudioFormat { engine.inputNode.outputFormat(forBus: 0) }

    /// Blocking daemon round-trip: call off the main thread.
    static func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try? session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)
    }

    static func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func start(inputHandler: @escaping InputHandler) throws {
        lock.withLock { self.inputHandler = inputHandler }
        try graphLock.withLock { try startGraph() }
    }

    /// Rebuilds the graph after a route/configuration change; scheduled playback is lost.
    func restart() throws {
        try graphLock.withLock {
            stopGraph(keepVoiceProcessing: true)
            try startGraph()
        }
    }

    /// Configuration-change notifications also fire for engines we already dropped.
    func owns(_ object: Any?) -> Bool {
        graphLock.withLock { (object as AnyObject?) === engine }
    }

    func stop() {
        graphLock.withLock { stopGraph() }
        lock.withLock { inputHandler = nil }
        meter.reset()
    }

    private func startGraph() throws {
        // Must be enabled before the engine starts and before reading the input format.
        do {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            try engine.outputNode.setVoiceProcessingEnabled(true)
            voiceProcessingActive = true
        } catch {
            voiceProcessingActive = false
        }

        if player.engine == nil { engine.attach(player) }
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)

        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceAudioError.noInput
        }
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.handleInput(buffer)
        }
        let mixerFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: mixerFormat) { [weak self] buffer, _ in
            self?.meter.pushOutput(db: AudioLevel.rmsDecibels(buffer))
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            // Some routes refuse the voice-processing unit: never lose the mic over it.
            guard voiceProcessingActive else { throw error }
            engine.inputNode.removeTap(onBus: 0)
            engine.mainMixerNode.removeTap(onBus: 0)
            engine.stop()
            engine = AVAudioEngine()
            player = AVAudioPlayerNode()
            voiceProcessingActive = false
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
            let fallbackFormat = engine.inputNode.outputFormat(forBus: 0)
            engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: fallbackFormat) { [weak self] buffer, _ in
                self?.handleInput(buffer)
            }
            engine.prepare()
            try engine.start()
        }
        player.play()
        isRunning = true
    }

    private func stopGraph(keepVoiceProcessing: Bool = false) {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.mainMixerNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        isRunning = false
        if voiceProcessingActive, !keepVoiceProcessing {
            try? engine.inputNode.setVoiceProcessingEnabled(false)
            try? engine.outputNode.setVoiceProcessingEnabled(false)
        }
    }

    private func handleInput(_ buffer: AVAudioPCMBuffer) {
        let time = ProcessInfo.processInfo.systemUptime
        let (handler, enabled) = lock.withLock { (inputHandler, inputEnabledValue) }
        let db = AudioLevel.rmsDecibels(buffer)
        meter.pushInput(db: enabled ? db : -120)
        guard enabled else { return }
        handler?(buffer, db, time)
    }

    // MARK: - Playback

    /// Matches the player to the synthesizer voice's native rate so buffers need no resampling.
    func preparePlayback(sampleRate: Double) {
        graphLock.lock()
        defer { graphLock.unlock() }
        guard sampleRate > 0, sampleRate != playbackFormat.sampleRate,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        playbackFormat = format
        resampler = nil
        guard isRunning else { return }
        player.stop()
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        player.play()
    }

    /// Schedules a synthesized buffer. `completion` runs once it has been played back (or flushed).
    @discardableResult
    func schedule(_ buffer: AVAudioPCMBuffer, completion: @escaping @Sendable () -> Void) -> Bool {
        graphLock.lock()
        defer { graphLock.unlock() }
        guard isRunning, let playable = convertForPlayback(buffer) else { return false }
        player.scheduleBuffer(playable, completionCallbackType: .dataPlayedBack) { _ in completion() }
        if !player.isPlaying { player.play() }
        return true
    }

    func flushPlayback() {
        graphLock.lock()
        defer { graphLock.unlock() }
        guard isRunning else { return }
        player.stop()
        player.play()
    }

    private func convertForPlayback(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let source = buffer.format
        let target = playbackFormat
        guard buffer.frameLength > 0 else { return nil }
        if source == target { return buffer }

        if source.sampleRate == target.sampleRate,
           let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: buffer.frameLength),
           let destination = output.floatChannelData?[0] {
            let frames = Int(buffer.frameLength)
            output.frameLength = buffer.frameLength
            if let samples = buffer.int16ChannelData?[0] {
                let stride = source.isInterleaved ? Int(source.channelCount) : 1
                for index in 0..<frames { destination[index] = Float(samples[index * stride]) / 32768 }
                return output
            }
            if let samples = buffer.floatChannelData?[0] {
                let stride = source.isInterleaved ? Int(source.channelCount) : 1
                for index in 0..<frames { destination[index] = samples[index * stride] }
                return output
            }
        }

        if resampler == nil || resampler?.inputFormat != source {
            resampler = AVAudioConverter(from: source, to: target)
        }
        guard let resampler else { return nil }
        let ratio = target.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 512
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var consumed = false
        var error: NSError?
        resampler.convert(to: output, error: &error) { _, status in
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

enum VoiceAudioError: LocalizedError {
    case noInput

    var errorDescription: String? {
        switch self {
        case .noInput: String(localized: "No microphone available.")
        }
    }
}
