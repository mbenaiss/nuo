@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

typealias MeetingBufferHandler = @Sendable (AVAudioPCMBuffer) -> Void

/// 0...1 level of a mono buffer, like the dictation meter.
enum MeetingLevel {
    static func normalized(_ buffer: AVAudioPCMBuffer) -> Float {
        normalized(rms: rms(buffer))
    }

    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let data = buffer.floatChannelData?[0] else { return 0 }
        var sum: Float = 0
        for index in 0..<frames { sum += data[index] * data[index] }
        return sqrt(sum / Float(frames))
    }

    static func normalized(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        return min(max((20 * log10(rms) + 55) / 45, 0), 1)
    }
}

/// Writes one stream as raw 16 kHz mono Float32 into the app's caches: an hour of audio does not fit in memory, and the
/// transcriber reads it back while it is being written. The file is deleted as soon as it is transcribed or the
/// meeting is discarded.
final class MeetingStreamWriter: @unchecked Sendable {
    static let sampleRate = Double(WhisperEngine.sampleRate)
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    let url: URL
    private let lock = NSLock()
    private let queue = DispatchQueue(label: AppIdentity.scoped("meeting.writer"), qos: .utility)
    private var handle: FileHandle?
    private var converter: AVAudioConverter?
    private var mono: AVAudioFormat?
    private var levelValue: Float = 0
    private var signal = false
    private var lastSignal = Date()
    /// Samples queued for the file, silence included.
    private var written = 0
    private var failureValue: Error?
    /// Seconds between the start of the meeting and the first sample of this stream.
    private var offset: TimeInterval?
    private let startedAt: Date
    /// A longer gap (the Mac asleep) is not filled: an hour of silence would take 230 MB.
    private static let longestGap = Int(sampleRate) * 600

    init(url: URL, startedAt: Date) throws {
        self.url = url
        self.startedAt = startedAt
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        handle = try FileHandle(forWritingTo: url)
    }

    /// A stream recorded before Nuo quit, read back to finish its transcription.
    init(recorded url: URL, startedAt: Date, startOffset: TimeInterval?) {
        self.url = url
        self.startedAt = startedAt
        offset = startOffset
        written = MeetingStreamReader.frameCount(url)
    }

    var level: Float { lock.withLock { levelValue } }
    /// Whether any non-silent sample arrived: a denied permission or a muted mic only ever gives zeros.
    var heardSignal: Bool { lock.withLock { signal } }
    /// Seconds since the last non-silent sample (or since the stream started).
    var silentFor: TimeInterval { lock.withLock { Date().timeIntervalSince(lastSignal) } }
    var startOffset: TimeInterval? { lock.withLock { offset } }
    /// The disk refused a write (full, removed): nothing more is recorded.
    var failure: Error? { lock.withLock { failureValue } }

    /// Audio thread. The buffer may not outlive the call (the tap hands its own memory), so it is converted here.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let downmixed = Self.downmix(buffer) else { return }
        let rms = MeetingLevel.rms(downmixed)
        let level = MeetingLevel.normalized(rms: rms)
        let now = Date()
        let converter: AVAudioConverter? = lock.withLock {
            guard handle != nil, failureValue == nil else { return nil }
            if offset == nil { offset = max(0, now.timeIntervalSince(startedAt) - Double(buffer.frameLength) / buffer.format.sampleRate) }
            levelValue += (level - levelValue) * 0.4
            // Exact zeros only: a quiet room still reads above zero, a muted or lost device does not.
            if rms > 0 {
                signal = true
                lastSignal = now
            }
            if self.converter == nil || mono != downmixed.format {
                self.converter = AVAudioConverter(from: downmixed.format, to: Self.format)
                mono = downmixed.format
            }
            return self.converter
        }
        guard let converter, let converted = Self.convert(downmixed, with: converter),
              let data = converted.floatChannelData?[0] else { return }
        let count = Int(converted.frameLength)
        let gap: Int = lock.withLock {
            let expectedEnd = Int((now.timeIntervalSince(startedAt) - (offset ?? 0)) * Self.sampleRate)
            let gap = min(Self.longestGap, MeetingTimeline.silence(written: written, expectedEnd: expectedEnd, incoming: count, tolerance: Int(Self.sampleRate)))
            written += gap + count
            return gap
        }
        if gap > 0 { NSLog("Nuo meeting: %.1f s of audio missing in %@, filled with silence", Double(gap) / Self.sampleRate, url.lastPathComponent) }
        var audio = Data(count: gap * MemoryLayout<Float>.size)
        audio.append(Data(bytes: data, count: count * MemoryLayout<Float>.size))
        let bytes = audio
        queue.async { [self] in
            guard let handle = lock.withLock({ failureValue == nil ? self.handle : nil }) else { return }
            do {
                try handle.write(contentsOf: bytes)
            } catch {
                NSLog("Nuo meeting: write failed — %@", String(describing: error))
                lock.withLock { failureValue = error }
            }
        }
    }

    func close() {
        queue.sync {
            lock.withLock {
                try? handle?.close()
                handle = nil
            }
        }
    }

    func delete() {
        close()
        try? FileManager.default.removeItem(at: url)
    }

    /// Mean of every channel: a multichannel interface may carry the voice on a channel other than the first.
    private static func downmix(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0, buffer.format.commonFormat == .pcmFormatFloat32,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate, channels: 1, interleaved: false),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let target = output.floatChannelData?[0] else { return nil }
        output.frameLength = AVAudioFrameCount(frames)
        if buffer.format.isInterleaved {
            guard let source = buffer.floatChannelData?[0] else { return nil }
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += source[frame * channels + channel] }
                target[frame] = sum / Float(channels)
            }
        } else {
            guard let sources = buffer.floatChannelData else { return nil }
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += sources[channel][frame] }
                target[frame] = sum / Float(channels)
            }
        }
        return output
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> AVAudioPCMBuffer? {
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
}

/// Reads a recorded stream back, also while it is still being written.
enum MeetingStreamReader {
    static func frameCount(_ url: URL) -> Int {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return size / MemoryLayout<Float>.size
    }

    static func read(_ url: URL, from start: Int, count: Int) throws -> [Float] {
        guard count > 0 else { return [] }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(start * MemoryLayout<Float>.size))
        guard let data = try handle.read(upToCount: count * MemoryLayout<Float>.size) else { return [] }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(data.count / MemoryLayout<Float>.size)) }
    }
}

/// The microphone (« Moi »). Follows the default input: a headset or AirPods plugged in mid-meeting stop the engine
/// on its own, so it is restarted on the new device and format.
final class MeetingMicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var handler: MeetingBufferHandler?
    private var observer: NSObjectProtocol?
    private var inputListener: AudioObjectPropertyListenerBlock?
    private var pendingRestart: DispatchWorkItem?
    /// Main queue: the input could not be restarted after a device change.
    var onFailure: (@Sendable (Error) -> Void)?

    func start(_ handler: @escaping MeetingBufferHandler) throws {
        self.handler = handler
        do {
            try run(handler)
        } catch {
            self.handler = nil
            throw error
        }
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.scheduleRestart()
        }
        var address = CoreAudioQuery.address(kAudioHardwarePropertyDefaultInputDevice)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleRestart() }
        inputListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
    }

    private func run(_ handler: @escaping MeetingBufferHandler) throws {
        let input = engine.inputNode
        if let unit = input.audioUnit,
           var device = CoreAudioQuery.objectID(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice) {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = input.outputFormat(forBus: 0)
        NSLog("Nuo meeting: mic format %@", format.description)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw TranscriberError.unavailable }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in handler(buffer) }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    /// Main queue. A switch fires several notifications in a row: one restart once they settle.
    private func scheduleRestart(attempt: Int = 0) {
        guard handler != nil else { return }
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.restart(attempt: attempt) }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.3 : 1), execute: work)
    }

    private func restart(attempt: Int) {
        guard let handler else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            try run(handler)
            NSLog("Nuo meeting: mic restarted after a device change")
        } catch {
            NSLog("Nuo meeting: mic restart failed — %@", String(describing: error))
            if attempt < 5 { scheduleRestart(attempt: attempt + 1) } else { onFailure?(error) }
        }
    }

    func stop() {
        handler = nil
        pendingRestart?.cancel()
        pendingRestart = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if let inputListener {
            var address = CoreAudioQuery.address(kAudioHardwarePropertyDefaultInputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, inputListener)
        }
        inputListener = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// What the Mac plays (« Eux »), through a Core Audio process tap on every process but Nuo, read from a private
/// aggregate device. Needs the « Enregistrement audio du système uniquement » permission; when it is denied the tap
/// still runs but only delivers silence.
final class SystemAudioTap: @unchecked Sendable {
    enum TapError: LocalizedError {
        case create(OSStatus), format, aggregate(OSStatus), start(OSStatus)

        var errorDescription: String? {
            switch self {
            case let .create(status): String(localized: "Couldn't create the audio tap (\(status)).")
            case .format: String(localized: "The system audio format can't be read.")
            case let .aggregate(status): String(localized: "Couldn't create the capture audio device (\(status)).")
            case let .start(status): String(localized: "Couldn't capture system audio (\(status)).")
            }
        }
    }

    private let queue = DispatchQueue(label: AppIdentity.scoped("meeting.tap"), qos: .userInitiated)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private(set) var format: AVAudioFormat?
    private var handler: MeetingBufferHandler?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var pendingRebuild: DispatchWorkItem?
    /// Main queue: the capture could not be rebuilt after an output change.
    var onFailure: (@Sendable (Error) -> Void)?
    private static let outputSelectors = [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice]

    /// Creates the tap and its aggregate device; returns the format the buffers will have.
    func prepare() throws -> AVAudioFormat {
        let own = Self.processObject(pid: getpid()).map { [$0] } ?? []
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: own)
        description.uuid = UUID()
        description.name = "Nuo"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != kAudioObjectUnknown else { throw TapError.create(status) }
        tapID = tap

        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            teardown()
            throw TapError.format
        }

        var properties: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Nuo réunion",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        // The output device clocks the aggregate; without one the tap still works on its own clock.
        if let output = Self.defaultOutputUID() {
            properties[kAudioAggregateDeviceMainSubDeviceKey] = output
            properties[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: output]]
        }
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(properties as CFDictionary, &aggregate)
        guard status == noErr else {
            teardown()
            throw TapError.aggregate(status)
        }
        aggregateID = aggregate
        self.format = format
        return format
    }

    func start(_ handler: @escaping MeetingBufferHandler) throws {
        try startIO(handler)
        self.handler = handler
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleRebuild() }
        outputListener = listener
        for selector in Self.outputSelectors {
            var address = CoreAudioQuery.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
    }

    private func startIO(_ handler: @escaping MeetingBufferHandler) throws {
        guard let format, aggregateID != kAudioObjectUnknown else { throw TapError.format }
        var proc: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, queue) { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let range = MeetingTapBuffer.range(channels: buffers.map(\.mNumberChannels), expected: format.channelCount,
                                                     interleaved: format.isInterleaved) else { return }
            if range.count == buffers.count {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
                handler(buffer)
                return
            }
            let list = AudioBufferList.allocate(maximumBuffers: range.count)
            defer { free(list.unsafeMutablePointer) }
            for (slot, index) in range.enumerated() { list[slot] = buffers[index] }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer, deallocator: nil) else { return }
            handler(buffer)
        }
        guard status == noErr, let proc else {
            teardown()
            throw TapError.start(status)
        }
        procID = proc
        status = AudioDeviceStart(aggregateID, proc)
        guard status == noErr else {
            teardown()
            throw TapError.start(status)
        }
    }

    /// The aggregate is clocked by the output it was built on and the tap keeps the format it had then: AirPods or a
    /// headset taking over the output need both rebuilt. Main queue.
    private func scheduleRebuild() {
        guard handler != nil else { return }
        pendingRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuild() }
        pendingRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func rebuild() {
        guard let handler else { return }
        teardown()
        do {
            _ = try prepare()
            try startIO(handler)
            NSLog("Nuo meeting: system audio rebuilt for the new output")
        } catch {
            NSLog("Nuo meeting: system audio rebuild failed — %@", String(describing: error))
            onFailure?(error)
        }
    }

    func stop() {
        handler = nil
        pendingRebuild?.cancel()
        pendingRebuild = nil
        if let outputListener {
            for selector in Self.outputSelectors {
                var address = CoreAudioQuery.address(selector)
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, outputListener)
            }
        }
        outputListener = nil
        teardown()
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    static func processObject(pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func defaultOutputUID() -> String? {
        guard let device = CoreAudioQuery.objectID(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice) else { return nil }
        return CoreAudioQuery.string(device, kAudioDevicePropertyDeviceUID)
    }
}

/// Small typed reads of Core Audio properties.
enum CoreAudioQuery {
    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    static func objectID(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var address = address(selector)
        var value = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return status == noErr && value != kAudioObjectUnknown ? value : nil
    }

    static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func pid(_ object: AudioObjectID) -> pid_t? {
        var address = address(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func objectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &list) == noErr else { return [] }
        return list
    }
}
