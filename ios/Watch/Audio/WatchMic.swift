@preconcurrency import AVFoundation
import Foundation

/// Who uses the watch's audio session: it is turned off only when the last one is done, so the voice reading an
/// answer or a spoken request never cuts a recording short.
@MainActor
enum WatchAudioSession {
    private static var users: Set<String> = []

    static func acquire(_ user: String) {
        users.insert(user)
    }

    static func release(_ user: String) {
        users.remove(user)
        guard users.isEmpty else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    static var isInUse: Bool { !users.isEmpty }
}

/// The time of the last chunk the audio thread delivered, readable from anywhere: the recorder's watchdog checks
/// the microphone itself, not a main thread that may be late.
final class SampleClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast

    func tick() { lock.withLock { last = Date() } }
    func reset() { tick() }
    var lastSample: Date { lock.withLock { last } }
}

/// The watch microphone as 16 kHz mono samples, the rate the gateway transcribes, with a level for the meter.
///
/// watchOS keeps recording with the screen off and the wrist down only when the session was started in the
/// foreground with the `audio` background mode; after an interruption (a call, Siri) it cannot start again until
/// the user brings the app back (Apple Developer Forums thread 750432).
@MainActor
final class WatchMic {
    enum Failure: LocalizedError {
        case denied, unavailable

        var errorDescription: String? {
            switch self {
            case .denied: String(localized: "Nuo can't access the microphone. Allow it in Settings › Privacy › Microphone on the watch.")
            case .unavailable: String(localized: "The microphone isn't available right now.")
            }
        }
    }

    struct Chunk: Sendable {
        var samples: [Float]
        var level: Float
    }

    static let sampleRate = 16_000.0

    /// Samples converted to 16 kHz and the level (0…1) of that chunk, in the order the audio thread produced them.
    var onSamples: (([Float], Float) -> Void)?
    /// The microphone stopped (`true`: a call, Siri, the audio services reset, a route the engine could not follow)
    /// or came back (`false`).
    var onInterruption: ((Bool) -> Void)?

    let owner: String
    let clock = SampleClock()
    private var engine = AVAudioEngine()
    private(set) var isRunning = false
    private var observers: [NSObjectProtocol] = []
    private var chunks: AsyncStream<Chunk>.Continuation?
    private var reader: Task<Void, Never>?

    init(owner: String) {
        self.owner = owner
    }

    static func allowed() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: true
        case .undetermined: await AVAudioApplication.requestRecordPermission()
        default: false
        }
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.overrideMutedMicrophoneInterruption])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        WatchAudioSession.acquire(owner)
        do {
            try installTapAndStart()
        } catch {
            WatchAudioSession.release(owner)
            throw error
        }
        isRunning = true
        clock.reset()
        observe(session)
    }

    /// Stops listening but keeps the session: an interruption that ends is then reported, and the recording can
    /// pick up again where watchOS allows it.
    func suspend() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    /// The end of a request: the chunks already captured are written before the session goes, about a quarter of a
    /// second at most.
    func stopAndDrain() async {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        chunks?.finish()
        chunks = nil
        if let reader {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await reader.value }
                group.addTask { try? await Task.sleep(for: .milliseconds(300)) }
                await group.next()
                group.cancelAll()
            }
        }
        reader = nil
        WatchAudioSession.release(owner)
    }

    /// Stops listening and gives the session back. Safe to call in any state, after an interruption too.
    func stop() {
        suspend()
        reader?.cancel()
        reader = nil
        chunks?.finish()
        chunks = nil
        WatchAudioSession.release(owner)
    }

    private func installTapAndStart() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target)
        else { throw Failure.unavailable }
        if chunks == nil {
            let (stream, continuation) = AsyncStream<Chunk>.makeStream()
            chunks = continuation
            reader = Task { [weak self] in
                for await chunk in stream { self?.onSamples?(chunk.samples, chunk.level) }
            }
        }
        let continuation = chunks
        let clock = clock
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.tap(converter: converter, target: target) { samples, level in
            clock.tick()
            continuation?.yield(Chunk(samples: samples, level: level))
        })
        engine.prepare()
        try engine.start()
    }

    /// A new route (AirPods connected or gone) stops the engine: it starts again on the new format at once.
    private func followConfigurationChange() {
        guard isRunning else { return }
        do {
            try installTapAndStart()
        } catch {
            isRunning = false
            onInterruption?(true)
        }
    }

    /// The audio services restarted: the old engine is dead, a new one takes over.
    private func servicesReset() {
        let wasRunning = isRunning
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine = AVAudioEngine()
        observeEngine()
        isRunning = false
        if wasRunning { onInterruption?(true) }
    }

    private func observe(_ session: AVAudioSession) {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
                let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init) == .began
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if began { self.isRunning = false }
                    self.onInterruption?(began)
                }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.servicesReset() }
            },
        ]
        observeEngine()
    }

    private var engineObserver: NSObjectProtocol?

    private func observeEngine() {
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.followConfigurationChange() }
        }
    }

    /// Built outside the main actor: the audio thread calls it.
    private nonisolated static func tap(converter: AVAudioConverter, target: AVAudioFormat,
                                        deliver: @escaping @Sendable ([Float], Float) -> Void) -> AVAudioNodeTapBlock {
        nonisolated(unsafe) let converter = converter
        return { buffer, _ in
            let ratio = target.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
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
            guard error == nil, let channel = output.floatChannelData?[0], output.frameLength > 0 else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            let power = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)
            // About -50 dB is silence, -10 dB a voice close to the watch.
            let decibels = 10 * log10(max(power, 1e-9))
            deliver(samples, min(1, max(0, (decibels + 50) / 40)))
        }
    }
}
