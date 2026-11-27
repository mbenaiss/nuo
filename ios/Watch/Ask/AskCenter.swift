@preconcurrency import AVFoundation
import Foundation
import Observation
import WatchConnectivity
import WatchKit

/// « Parler à Nuo »: a short spoken request (the watch's button stopped within the minute, or a reply in a
/// conversation) recorded on the watch and handed to the iPhone, which transcribes it in one pass on the gateway,
/// picks the bot and sends it with the app's own access (the watch's token may neither transcribe nor talk to the
/// general bot). Out of the iPhone's reach the request waits on disk and leaves through
/// the system's transfer queue; it is deleted only once the iPhone has sent it.
@MainActor
@Observable
final class AskCenter {
    static let shared = AskCenter()

    enum Phase: Equatable {
        case idle, listening
        /// The minute is up: the microphone is off and nothing leaves until the user sends or cancels.
        case capped
        /// Handed to the iPhone, waiting for the transcript and the bot.
        case sending
        /// The iPhone does not answer: the request is queued.
        case queued
        case failed(String)
    }

    /// Where the answer lands, as the iPhone reports it.
    struct Delivery: Hashable {
        var askId: String
        var conversationId: String
        var botId: String
        var text: String
        var speechEndedAt: Date
    }

    private(set) var phase: Phase = .idle
    private(set) var level: Float = 0
    private(set) var seconds: TimeInterval = 0
    private(set) var queue: AskQueue
    private(set) var phoneReachable = false
    /// Why a request waits, shown under « En attente de l'iPhone » (a locked iPhone, mostly).
    private(set) var queuedReason: String?
    /// A request that left as a file while the iPhone was in reach: its answer, once the iPhone says where it is.
    private(set) var arrived: Delivery?
    @ObservationIgnored private var awaitingAck: (id: String, endedAt: Date)?
    /// How the request being sent travels, for the words under the spinner.
    private(set) var sendingLive = true
    /// No word from the iPhone this long after a request left as a file: it is shown as waiting, not « en route ».
    static let ackTimeout: Duration = .seconds(25)
    @ObservationIgnored private var wake: Task<Void, Never>?

    @ObservationIgnored private let mic = WatchMic(owner: "ask")
    @ObservationIgnored private var file: AVAudioFile?
    @ObservationIgnored private var current: (id: String, botId: String?, conversationId: String?)?
    @ObservationIgnored private var samples = 0
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var sendingId: String?
    @ObservationIgnored private var demo: Task<Void, Never>?
    @ObservationIgnored let isDemo = ProcessInfo.processInfo.arguments.contains("-demo")

    private static var queueURL: URL { WatchFiles.asks.appending(path: "queue.json") }
    /// AAC at 32 kbit/s: the voice stays clear for the recognition and ten seconds weigh about 40 KB, under what a live
    /// message carries; longer requests go as a file.
    private static let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: WatchMic.sampleRate,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
    ]
    static let liveMessageLimit = 60_000
    /// Most a request may last: a quick request, not a dictation of a letter.
    static let maxSeconds: TimeInterval = 60

    private init() {
        queue = WatchFiles.load(AskQueue.self, from: Self.queueURL) ?? AskQueue()
        mic.onSamples = { [weak self] samples, level in self?.consume(samples, level: level) }
        mic.onInterruption = { [weak self] began in if began { self?.cancel() } }
    }

    var isListening: Bool { phase == .listening || phase == .capped }

    // MARK: - Listening

    func listen(botId: String?, conversationId: String?) async {
        guard !isListening else { return }
        // The recorder holds the microphone: taking it would stop the meeting being recorded.
        guard !VoiceRecorder.shared.isActive else {
            phase = .failed(Self.busyMessage)
            return
        }
        current = (UUID().uuidString.lowercased(), botId, conversationId)
        seconds = 0
        samples = 0
        if isDemo {
            phase = .listening
            playDemoLevels()
            return
        }
        guard await WatchMic.allowed() else {
            phase = .failed(WatchMic.Failure.denied.localizedDescription)
            return
        }
        guard let id = current?.id,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: WatchMic.sampleRate, channels: 1, interleaved: false)
        else { return }
        do {
            file = try AVAudioFile(forWriting: WatchFiles.asks.appending(path: "\(id).m4a"), settings: Self.settings,
                                   commonFormat: format.commonFormat, interleaved: false)
            try mic.start()
            phase = .listening
            WKInterfaceDevice.current().play(.start)
        } catch {
            file = nil
            discard(id)
            current = nil
            phase = .failed(error.localizedDescription)
        }
    }

    static var busyMessage: String { String(localized: "A recording is in progress: stop it to talk to Nuo.") }

    /// End of speech (double tap, or the button): the request leaves at once. Nil when it was queued or failed.
    func finish() async -> Delivery? {
        guard isListening, let current else { return nil }
        let ended = Date()
        demo?.cancel()
        // The last words still on their way from the microphone are written first.
        await mic.stopAndDrain()
        file?.close()
        file = nil
        level = 0
        WKInterfaceDevice.current().play(.click)
        if isDemo { return await demoDelivery(askId: current.id, botId: current.botId, endedAt: ended) }
        guard seconds >= CaptureRule.shortestRequest else {
            discard(current.id)
            phase = .idle
            return nil
        }
        let ask = WatchAsk(id: current.id, createdAt: ended, botId: current.botId, conversationId: current.conversationId,
                           audioFile: "\(current.id).m4a", seconds: seconds)
        self.current = nil
        return await send(ask, endedAt: ended)
    }

    /// A capture of the watch's button that ended under a minute: its file becomes a request to the general bot (no
    /// bot is named, the iPhone picks it) and leaves like a spoken one.
    func submit(audioAt url: URL, seconds: TimeInterval, endedAt: Date) async -> Delivery? {
        let id = UUID().uuidString.lowercased()
        WKInterfaceDevice.current().play(.click)
        if isDemo { return await demoDelivery(askId: id, botId: nil, endedAt: endedAt) }
        let name = "\(id).m4a"
        do {
            try FileManager.default.moveItem(at: url, to: WatchFiles.asks.appending(path: name))
        } catch {
            phase = .failed(String(localized: "The watch couldn't record your request. Try again."))
            WKInterfaceDevice.current().play(.failure)
            return nil
        }
        return await send(WatchAsk(id: id, createdAt: endedAt, botId: nil, conversationId: nil, audioFile: name, seconds: seconds),
                          endedAt: endedAt)
    }

    private func send(_ ask: WatchAsk, endedAt ended: Date) async -> Delivery? {
        queue.enqueue(ask)
        save()
        phase = .sending
        sendingLive = true
        sendingId = ask.id
        let outcome = await deliver(ask, speechEndedAt: ended)
        // A new request may have started meanwhile: its phase is not this one's to change.
        guard phase == .sending, sendingId == ask.id else { return outcome.delivery }
        sendingId = nil
        switch outcome {
        case let .delivered(delivery):
            phase = .idle
            return delivery
        case let .handedOver(id):
            // Too long for a live message, the iPhone in reach: still « on its way », and the answer opens on its word.
            phase = .sending
            sendingLive = false
            awaitingAck = (id, ended)
            Task { [weak self] in
                try? await Task.sleep(for: Self.ackTimeout)
                guard let self, self.awaitingAck?.id == id, self.phase == .sending else { return }
                self.phase = .queued
                self.queuedReason = String(localized: "The iPhone hasn't answered yet: your request will go as soon as possible.")
            }
        case let .queued(reason):
            phase = .queued
            queuedReason = reason
            WKInterfaceDevice.current().play(.retry)
        case let .refused(reason):
            phase = .failed(reason)
            WKInterfaceDevice.current().play(.failure)
        }
        return nil
    }

    func cancel() {
        guard isListening || current != nil else { return }
        stopListening()
        if let current { discard(current.id) }
        current = nil
        phase = .idle
    }

    private func stopListening() {
        demo?.cancel()
        mic.stop()
        file?.close()
        file = nil
        level = 0
    }

    /// A request typed with the watch's keyboard when the iPhone is away: it waits in the queue like a spoken one.
    func queueTyped(_ text: String, botId: String?, conversationId: String?) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        queue.enqueue(WatchAsk(createdAt: Date(), botId: botId, conversationId: conversationId, audioFile: nil, text: clean, seconds: 0))
        save()
        phase = .queued
        queuedReason = nil
        pump()
    }

    func resetPhase() {
        if !isListening, phase != .sending { phase = .idle }
    }

    /// The answer the ask screen opened: not opened twice.
    func consumeArrived() {
        arrived = nil
    }

    /// A request that was not sent, deleted after reading its text, its audio with it.
    func dismissFailure(_ id: String) {
        if let file = queue.remove(id)?.audioFile { try? FileManager.default.removeItem(at: WatchFiles.asks.appending(path: file)) }
        save()
    }

    /// « Envoyer maintenant »: its text goes again, as a new request.
    func sendAgain(_ id: String) {
        guard queue.requeue(id) != nil else { return }
        save()
        pump()
    }

    // MARK: - Delivery

    enum Outcome {
        case delivered(Delivery)
        /// Left as a file while the iPhone is in reach.
        case handedOver(String)
        case queued(String?)
        case refused(String)

        var delivery: Delivery? {
            if case let .delivered(delivery) = self { delivery } else { nil }
        }
    }

    /// Live to the iPhone when it answers; otherwise through the system's queue, acknowledged later.
    private func deliver(_ ask: WatchAsk, speechEndedAt: Date) async -> Outcome {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated else { return .queued(nil) }
        if let conversationId = ask.conversationId { PhoneTurnFeed.shared.reset(conversationId: conversationId) }
        let audio = ask.audioFile.flatMap { try? Data(contentsOf: WatchFiles.asks.appending(path: $0)) }
        if session.isReachable, (audio?.count ?? 0) <= Self.liveMessageLimit {
            inFlight.insert(ask.id)
            queue.markSending(ask.id)
            defer { inFlight.remove(ask.id) }
            var message = envelope(ask)
            message[RecordingLink.request] = RecordingLink.ask
            if let audio { message[RecordingLink.audio] = audio }
            let reply = await Self.send(Outgoing(values: message))
            if let reply, reply.ok, let conversationId = reply.conversationId, let botId = reply.botId {
                let text = reply.text ?? ""
                delivered(ask.id, conversationId: conversationId, botId: botId, transcript: text)
                return .delivered(Delivery(askId: ask.id, conversationId: conversationId, botId: botId, text: text, speechEndedAt: speechEndedAt))
            }
            if let reply, reply.queued {
                // The iPhone kept it and will send it once the gateway answers (or once unlocked); it acknowledges then.
                queue.markTransferred(ask.id)
                save()
                return .queued(Self.keptText(reply.reason ?? (reply.locked ? "locked" : nil)))
            }
            if let reason = reply?.error {
                refused(ask.id, reason: reason)
                return .refused(reason)
            }
            queue.markWaiting(ask.id)
        }
        handOver(ask)
        return session.isReachable ? .handedOver(ask.id) : .queued(nil)
    }

    /// Sends what waits: called at launch, when the iPhone comes back and after each request.
    func pump() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        phoneReachable = WCSession.default.isReachable
        let queued = Set(WCSession.default.outstandingFileTransfers.compactMap { $0.file.metadata?[RecordingLink.askId] as? String })
            .union(WCSession.default.outstandingUserInfoTransfers.compactMap { $0.userInfo[RecordingLink.askId] as? String })
        // Typed requests too old to send become readable failures; spoken ones go on, the iPhone turns them into text.
        if !queue.expireTyped().isEmpty { save() }
        // Waiting ones, and those delivered long ago with no word back: the iPhone ignores a copy it already sent.
        for ask in queue.due(excluding: inFlight.union(queued)) {
            handOver(ask)
        }
        scheduleWake()
    }

    /// Back when a request delivered without a word back is due again: a timer, not only an event.
    private func scheduleWake() {
        wake?.cancel()
        guard let due = queue.nextResend() else { return }
        wake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, due.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.pump()
        }
    }

    /// Into the system's transfer queue, which delivers it even if the app is closed by then.
    private func handOver(_ ask: WatchAsk) {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        var metadata = envelope(ask)
        metadata[RecordingLink.kind] = RecordingLink.ask
        if let name = ask.audioFile {
            let url = WatchFiles.asks.appending(path: name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                queue.remove(ask.id)
                save()
                return
            }
            session.transferFile(url, metadata: metadata)
        } else {
            session.transferUserInfo(metadata)
        }
        queue.markSending(ask.id)
        save()
    }

    private func envelope(_ ask: WatchAsk) -> [String: Any] {
        var payload: [String: Any] = [
            RecordingLink.askId: ask.id,
            RecordingLink.seconds: ask.seconds,
            RecordingLink.createdAt: ask.createdAt.timeIntervalSince1970,
        ]
        if let botId = ask.botId { payload[RecordingLink.botId] = botId }
        if let conversationId = ask.conversationId { payload[RecordingLink.conversationId] = conversationId }
        if let text = ask.text { payload[RecordingLink.text] = text }
        return payload
    }

    /// A WatchConnectivity message handed off the main actor as it is: nothing touches it once built.
    private struct Outgoing: @unchecked Sendable {
        let values: [String: Any]
    }

    private nonisolated static func send(_ message: Outgoing) async -> AskReply? {
        await withCheckedContinuation { continuation in
            WCSession.default.sendMessage(message.values, replyHandler: AskReply.resuming(continuation), errorHandler: { _ in
                continuation.resume(returning: nil)
            })
        }
    }

    // MARK: - From PhoneLink

    /// The iPhone sent a queued request to its bot, or tells why it never will.
    func receive(_ info: [String: Any]) {
        guard info[RecordingLink.kind] as? String == RecordingLink.askAck, let id = info[RecordingLink.askId] as? String,
              let ask = queue.ask(id: id), ask.state != .delivered
        else { return }
        // The live reply to this request is still on its way and settles it; the acknowledgement can overtake it.
        guard AskFollow.handlesAck(liveReplyPending: inFlight.contains(id)) else { return }
        if info[RecordingLink.queued] as? Bool == true {
            // The iPhone keeps it (locked, gateway away): no longer « en route », and why.
            queue.markTransferred(id)
            save()
            if awaitingAck?.id == id || sendingId == id, phase == .sending {
                awaitingAck = nil
                phase = .queued
                queuedReason = Self.keptText(info[RecordingLink.reason] as? String)
            }
            return
        }
        if let reason = info[RecordingLink.error] as? String {
            refused(id, reason: reason, transcript: info[RecordingLink.text] as? String)
            WKInterfaceDevice.current().play(.failure)
            return
        }
        let conversationId = info[RecordingLink.conversationId] as? String, botId = info[RecordingLink.botId] as? String
        let text = info[RecordingLink.text] as? String
        delivered(id, conversationId: conversationId, botId: botId, transcript: text)
        if let awaiting = awaitingAck, awaiting.id == id, let conversationId, let botId {
            awaitingAck = nil
            arrived = Delivery(askId: id, conversationId: conversationId, botId: botId, text: text ?? "", speechEndedAt: awaiting.endedAt)
            if phase == .sending { phase = .idle }
        } else if let conversationId, let botId, AskFollow.opensAnswer(askedAt: ask.createdAt, now: Date()) {
            // Kept by a locked iPhone and sent at the unlock: the user is still waiting for this answer.
            arrived = Delivery(askId: id, conversationId: conversationId, botId: botId, text: text ?? "", speechEndedAt: ask.createdAt)
        }
        if phase == .queued { phase = .idle }
        WKInterfaceDevice.current().play(.success)
    }

    /// Refused for good: whatever was said stays readable when the iPhone sent its text; the audio goes either way,
    /// nothing will ever send it.
    private func refused(_ id: String, reason: String, transcript: String? = nil) {
        let result = queue.markFailed(id, message: reason, transcript: transcript)
        if let file = result.audioFile {
            queue.dropAudio(id)
            try? FileManager.default.removeItem(at: WatchFiles.asks.appending(path: file))
        }
        for file in result.droppedAudio { try? FileManager.default.removeItem(at: WatchFiles.asks.appending(path: file)) }
        if awaitingAck?.id == id, phase == .sending {
            awaitingAck = nil
            phase = .failed(reason)
        }
        save()
    }

    func transferFinished(metadata: [String: Any]?, failed: Bool) {
        guard let id = metadata?[RecordingLink.askId] as? String else { return }
        if failed {
            queue.markWaiting(id)
        } else {
            // Delivered by the system: the wait for the iPhone's word starts now.
            queue.markTransferred(id)
        }
        save()
        scheduleWake()
    }

    func reachabilityChanged(_ reachable: Bool) {
        phoneReachable = reachable
        if reachable { pump() }
    }

    private func delivered(_ id: String, conversationId: String?, botId: String?, transcript: String?) {
        let file = queue.ask(id: id)?.audioFile
        queue.markDelivered(id, conversationId: conversationId, botId: botId, transcript: transcript)
        if let file { try? FileManager.default.removeItem(at: WatchFiles.asks.appending(path: file)) }
        save()
    }

    // MARK: - Audio

    private func consume(_ chunk: [Float], level: Float) {
        guard phase == .listening, let file,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: WatchMic.sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.count)),
              let channel = buffer.floatChannelData?[0]
        else { return }
        buffer.frameLength = AVAudioFrameCount(chunk.count)
        chunk.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: chunk.count) }
        do {
            try file.write(from: buffer)
        } catch {
            let id = current?.id
            stopListening()
            if let id { discard(id) }
            current = nil
            phase = .failed(String(localized: "The watch couldn't record your request. Try again."))
            WKInterfaceDevice.current().play(.failure)
            return
        }
        samples += chunk.count
        seconds = Double(samples) / WatchMic.sampleRate
        self.level = level
        if seconds >= Self.maxSeconds {
            // Nothing leaves on its own: a minute of a room is not a request until the user says so.
            stopListening()
            phase = .capped
            WKInterfaceDevice.current().play(.directionDown)
        }
    }

    private func discard(_ id: String) {
        try? FileManager.default.removeItem(at: WatchFiles.asks.appending(path: "\(id).m4a"))
    }

    private func save() {
        WatchFiles.save(queue, to: Self.queueURL)
    }

    /// `-demo`: the general bot's conversation, after the time a transcription takes.
    private func demoDelivery(askId: String, botId: String?, endedAt: Date) async -> Delivery {
        phase = .sending
        try? await Task.sleep(for: .seconds(AskDemoScript.transcription))
        phase = .idle
        let text = WatchDemoDirector.argument("-watchPrompt") ?? AskDemoScript.reminders
        return Delivery(askId: askId, conversationId: "c-general-demo", botId: botId ?? "general", text: text, speechEndedAt: endedAt)
    }

    private func playDemoLevels() {
        demo?.cancel()
        demo = Task { [weak self] in
            var tick = 0.0
            while let self, !Task.isCancelled, self.phase == .listening {
                tick += 1
                self.level = Float(0.4 + 0.35 * sin(tick * 0.9) + 0.1 * sin(tick * 2.7))
                self.seconds += 0.1
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// The watch's words for why the iPhone keeps a request.
    static func keptText(_ reason: String?) -> String? {
        switch reason {
        case "locked": String(localized: "Open Nuo on your iPhone (or unlock it): your request will go as soon as that's done.")
        case "gatewayDown": String(localized: "The gateway isn't responding: the iPhone keeps your request and sends it when it's back.")
        case "scope": RelayScope.waitingText
        case "relayLimit": RelayScope.limitText
        default: nil
        }
    }
}
