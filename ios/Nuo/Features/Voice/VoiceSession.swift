@preconcurrency import AVFoundation
import Foundation
import Observation

/// Drives one hands-free conversation: listen → send the utterance → speak the streamed answer,
/// with barge-in at any time. The agent on the gateway stays the brain; this is only the voice.
@MainActor
@Observable
final class VoiceSession {
    enum Phase: Equatable {
        case starting
        case listening
        case thinking
        case speaking
        case paused
        case failed(VoiceFailure)
    }

    private(set) var phase: Phase = .starting
    private(set) var isMuted = false
    private(set) var userCaption = ""
    private(set) var botCaption = ""
    private(set) var tools: [ToolStep] = []
    private(set) var notice: String?
    private(set) var startedAt = Date()
    private(set) var voiceName = ""
    private(set) var voiceId = ""
    private(set) var stateChanges = 0

    let botName: String
    let conversationId: String
    @ObservationIgnored let meter: LevelMeter

    @ObservationIgnored private let transport: any ChatTransport
    @ObservationIgnored private let botVoiceId: String?
    @ObservationIgnored private let audio = VoiceAudioEngine()
    @ObservationIgnored private var transcriber: LiveTranscriber? {
        didSet { inputSink.set(transcriber) }
    }
    @ObservationIgnored private let inputSink = TranscriberSink()
    @ObservationIgnored private var speaker: VoiceSpeaker?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private var demoUtterance: String?

    @ObservationIgnored private var vad = VoiceActivityDetector()
    @ObservationIgnored private let bargeIn = BargeInPolicy()
    @ObservationIgnored private let endOfTurn = EndOfTurnDetector()
    @ObservationIgnored private var transcript = TranscriptAccumulator()
    @ObservationIgnored private var chunker = SentenceChunker()
    @ObservationIgnored private var fillers = FillerPicker()
    @ObservationIgnored private var lastVoiceAt: TimeInterval?
    @ObservationIgnored private var lastLevel: Float = -120
    @ObservationIgnored private var recentlySpoken: [String] = []

    @ObservationIgnored private var awaitingResponse = false
    @ObservationIgnored private var activeMessageId: String?
    @ObservationIgnored private var responseEnded = true
    @ObservationIgnored private var receivedAnswerText = false
    @ObservationIgnored private var thinkingSince: TimeInterval = 0
    @ObservationIgnored private var lastCommittedText = ""
    @ObservationIgnored private var carriedText = ""
    @ObservationIgnored private var interruptedAt: TimeInterval = 0
    @ObservationIgnored private var graphRestarts: [TimeInterval] = []
    @ObservationIgnored private var fillersSpoken = 0

    init(bot: Bot, conversationId: String, transport: any ChatTransport, demoUtterance: String? = nil) {
        self.botName = bot.config?.name ?? "Bot"
        self.botVoiceId = bot.config?.voice?.voiceId
        self.conversationId = conversationId
        self.transport = transport
        self.demoUtterance = demoUtterance
        self.meter = audio.meter
    }

    // MARK: - Lifecycle

    func start() async {
        guard !isClosed else { return }
        setPhase(.starting)
        startedAt = Date()

        let speaker = VoiceSpeaker(engine: audio, voice: VoiceCatalog.resolvedVoice(botVoiceId: botVoiceId))
        speaker.onItemAudible = { [weak self] item in self?.itemAudible(item) }
        speaker.onDrained = { [weak self] in self?.speakerDrained() }
        self.speaker = speaker
        voiceName = speaker.currentVoice?.name ?? ""
        voiceId = speaker.currentVoice?.identifier ?? ""

        listenToServer()
        observeAudioSession()
        startTicker()

        let demo = demoUtterance != nil
        guard await VoicePermissions.microphone() || demo else {
            fail(.microphoneDenied)
            return
        }
        do {
            try await Task.detached(priority: .userInitiated) { try VoiceAudioEngine.activateSession() }.value
            try startEngine()
        } catch {
            if !demo {
                fail(.audio(error.localizedDescription))
                return
            }
        }
        guard !isClosed else { return }

        let transcriber = LiveTranscriber()
        self.transcriber = transcriber
        do {
            _ = try await transcriber.start(locale: VoiceCatalog.recognitionLocale, inputFormat: audio.inputFormat)
            consumeTranscripts(transcriber)
        } catch {
            if !demo {
                fail(.transcription((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
                return
            }
        }
        guard !isClosed else { return }
        beginListening(resetTranscript: true)
        VoiceHaptics.ready()

        if let demoUtterance {
            self.demoUtterance = nil
            try? await Task.sleep(for: .milliseconds(700))
            userCaption = demoUtterance
            commit(text: demoUtterance)
        }
    }

    /// Releases the mic, the speech models and the audio session. The bot's answer keeps
    /// streaming into the chat, so nothing is cancelled server-side.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        speaker?.stop()
        speaker = nil
        audio.stop()
        let transcriber = transcriber
        self.transcriber = nil
        Task.detached {
            await transcriber?.stop()
            VoiceAudioEngine.deactivateSession()
        }
    }

    func retry() async {
        guard case .failed = phase else { return }
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        speaker?.stop()
        audio.stop()
        await transcriber?.stop()
        transcriber = nil
        await start()
    }

    // MARK: - User actions

    func tapOrb() {
        switch phase {
        case .listening:
            if isMuted {
                toggleMute()
            } else if !transcript.isEmpty || !carriedText.isEmpty {
                commit(text: transcript.text)
            }
        case .thinking, .speaking:
            interrupt()
        case .paused:
            resumeAfterInterruption()
        case .failed:
            Task { await retry() }
        case .starting:
            break
        }
    }

    func toggleMute() {
        isMuted.toggle()
        audio.inputEnabled = !isMuted
        vad.reset()
        lastVoiceAt = nil
        if !isMuted, phase == .listening { resetTranscript() }
        stateChanges += 1
    }

    func selectVoice(_ option: VoiceCatalog.Option) {
        VoiceCatalog.save(option.id)
        let voice = AVSpeechSynthesisVoice(identifier: option.id)
        speaker?.stop()
        speaker?.setVoice(voice)
        voiceName = voice?.name ?? option.name
        voiceId = option.id
    }

    func previewVoice(_ option: VoiceCatalog.Option) {
        selectVoice(option)
        speaker?.enqueue(String(localized: "Hello, it's \(botName). This is my new voice."), kind: .notice)
    }

    // MARK: - Turn taking

    private func beginListening(resetTranscript reset: Bool) {
        if reset { resetTranscript() }
        botCaption = ""
        setPhase(.listening)
    }

    private func resetTranscript() {
        let now = ProcessInfo.processInfo.systemUptime
        let marker = transcriber?.beginTurn() ?? (boundary: 0, turn: 0)
        transcript.reset(boundary: marker.boundary, turn: marker.turn, now: now)
        lastVoiceAt = nil
        vad.reset()
        userCaption = ""
    }

    private func commit(text: String) {
        let text = [carriedText, text.trimmingCharacters(in: .whitespacesAndNewlines)]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !text.isEmpty else { return }
        carriedText = ""
        lastCommittedText = text
        userCaption = text
        resetTranscript()
        userCaption = text
        botCaption = ""
        tools = []
        notice = nil
        chunker.reset()
        awaitingResponse = true
        activeMessageId = nil
        responseEnded = false
        receivedAnswerText = false
        fillersSpoken = 0
        thinkingSince = ProcessInfo.processInfo.systemUptime
        setPhase(.thinking)

        let event = ClientEvent.prompt(conversationId: conversationId, text: text, voice: true)
        Task { [weak self, transport] in
            do {
                try await transport.send(event)
            } catch {
                self?.serverFailed(String(localized: "Message not sent: \(error.localizedDescription)"))
            }
        }
    }

    private func interrupt() {
        // Cut off before the bot said anything: the user was not done, so their next words extend the same turn.
        let stillThinking = phase == .thinking && !receivedAnswerText
        carriedText = stillThinking ? lastCommittedText : ""
        interruptedAt = ProcessInfo.processInfo.systemUptime
        speaker?.stop()
        if awaitingResponse || activeMessageId != nil {
            let event = ClientEvent.cancel(conversationId: conversationId)
            Task { [transport] in try? await transport.send(event) }
        }
        awaitingResponse = false
        activeMessageId = nil
        responseEnded = true
        chunker.reset()
        botCaption = ""
        VoiceHaptics.interrupt()
        // Keep what the user already said: it is the start of their next turn.
        let kept = bargeIn.isUserSpeech(transcript.text, recentlySpoken: recentlySpoken)
        beginListening(resetTranscript: !kept)
        userCaption = [carriedText, kept ? transcript.text : ""].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func finishResponse() {
        guard responseEnded, !(speaker?.isActive ?? false), phase == .thinking || phase == .speaking else { return }
        let userAlreadyTalking = bargeIn.isUserSpeech(transcript.text, recentlySpoken: recentlySpoken)
        beginListening(resetTranscript: !userAlreadyTalking)
        if userAlreadyTalking { userCaption = transcript.text }
    }

    // MARK: - Audio input

    private func startEngine() throws {
        let sink = inputSink
        try audio.start { [weak self] buffer, db, time in
            sink.append(buffer)
            Task { @MainActor [weak self] in self?.handleLevel(db, at: time) }
        }
        audio.inputEnabled = !isMuted
    }

    private func handleLevel(_ db: Float, at time: TimeInterval) {
        guard !isMuted, phase != .paused else { return }
        lastLevel = db
        _ = vad.process(level: db, at: time)
        if vad.voiceDuration(at: time) > 0 { lastVoiceAt = time }

        if phase == .thinking || phase == .speaking {
            if bargeIn.shouldInterrupt(
                transcript: transcript.text,
                recentlySpoken: recentlySpoken,
                voiceDuration: vad.voiceDuration(at: time),
                level: db,
                noiseFloor: vad.noiseFloor
            ) {
                interrupt()
            }
        }
    }

    private func consumeTranscripts(_ transcriber: LiveTranscriber) {
        let stream = transcriber.updates
        tasks.append(Task { [weak self] in
            for await update in stream {
                guard let self else { return }
                self.handleTranscript(update)
            }
        })
    }

    private func handleTranscript(_ update: TranscriptUpdate) {
        guard !isMuted, phase != .paused else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard transcript.apply(update, now: now) else { return }
        switch phase {
        case .listening:
            userCaption = [carriedText, transcript.text].filter { !$0.isEmpty }.joined(separator: " ")
        case .thinking, .speaking:
            if bargeIn.isUserSpeech(transcript.text, recentlySpoken: recentlySpoken) {
                interrupt()
            }
        default:
            break
        }
    }

    private func startTicker() {
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                self?.tick()
            }
        })
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        switch phase {
        case .listening where !isMuted:
            if endOfTurn.isTurnOver(transcript: transcript, lastVoice: lastVoiceAt, now: now) {
                commit(text: transcript.text)
            } else if !carriedText.isEmpty, transcript.isEmpty, now - interruptedAt > 2.5, lastVoiceAt.map({ now - $0 > 1.5 }) ?? true {
                // Interrupted by a noise rather than more words: send what was already said.
                commit(text: "")
            }
        case .thinking:
            guard !receivedAnswerText, !(speaker?.isActive ?? false) else { return }
            let waited = now - thinkingSince
            if fillersSpoken == 0, waited >= 1.5 {
                fillersSpoken = 1
                speaker?.enqueue(fillers.next(long: false), kind: .filler)
            } else if fillersSpoken == 1, waited >= 9 {
                fillersSpoken = 2
                speaker?.enqueue(fillers.next(long: true), kind: .filler)
            }
        default:
            break
        }
    }

    // MARK: - Speaker callbacks

    private func itemAudible(_ item: VoiceSpeaker.Item) {
        recentlySpoken.append(item.text)
        if recentlySpoken.count > 3 { recentlySpoken.removeFirst(recentlySpoken.count - 3) }
        botCaption = item.text
        if item.kind == .answer, phase == .thinking { setPhase(.speaking) }
    }

    private func speakerDrained() {
        if responseEnded {
            finishResponse()
        } else if phase == .speaking {
            // The answer is still streaming but we spoke everything we had.
            setPhase(.thinking)
            thinkingSince = ProcessInfo.processInfo.systemUptime
        }
    }

    // MARK: - Server events

    private func listenToServer() {
        let stream = transport.events()
        tasks.append(Task { [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { return }
                self.handle(event)
            }
        })
    }

    private func handle(_ event: ServerEvent) {
        switch event {
        case let .messageStart(cid, messageId, _, _, _):
            guard cid == conversationId, awaitingResponse else { return }
            awaitingResponse = false
            activeMessageId = messageId
        case let .messageDelta(cid, messageId, text):
            guard cid == conversationId, messageId == activeMessageId else { return }
            receivedAnswerText = true
            for sentence in chunker.append(text) { speaker?.enqueue(sentence.text, speech: sentence.speech, kind: .answer) }
        case let .toolStart(cid, messageId, toolCallId, title, kind):
            guard cid == conversationId, messageId == activeMessageId else { return }
            tools.removeAll { $0.toolCallId == toolCallId }
            tools.append(ToolStep(toolCallId: toolCallId, title: title, kind: kind, status: .running))
        case let .toolEnd(cid, messageId, toolCallId, status, durationMs):
            guard cid == conversationId, messageId == activeMessageId,
                  let index = tools.firstIndex(where: { $0.toolCallId == toolCallId }) else { return }
            tools[index].status = status
            tools[index].durationMs = durationMs
        case let .messageEnd(cid, messageId, _, _, stopReason, _, _, _):
            guard cid == conversationId, messageId == activeMessageId else { return }
            activeMessageId = nil
            if stopReason == .cancelled, !receivedAnswerText {
                // A late end for a turn we cancelled earlier: our own answer is still coming.
                awaitingResponse = true
                return
            }
            for sentence in chunker.finish() { speaker?.enqueue(sentence.text, speech: sentence.speech, kind: .answer) }
            responseEnded = true
            if stopReason == .error, !receivedAnswerText {
                speakNotice(String(localized: "Sorry, I could not answer. You can try again."))
            }
            if !(speaker?.isActive ?? false) { finishResponse() }
        case let .permissionRequest(cid, _, title, _, _):
            guard cid == conversationId else { return }
            notice = String(localized: "Permission requested: \(title)")
            speakNotice(String(localized: "\(botName) needs your permission. Switch to the keyboard to answer."))
        case let .error(cid, message):
            guard cid == nil || cid == conversationId, awaitingResponse || activeMessageId != nil else { return }
            serverFailed(message)
        case .messageUser, .thoughtDelta, .notification, .pong, .context, .notice, .turnPhase, .turnsSnapshot, .deviceRequest, .subagent, .toolDetail, .alert:
            break
        }
    }

    private func speakNotice(_ text: String) {
        speaker?.enqueue(text, kind: .notice)
    }

    private func serverFailed(_ message: String) {
        awaitingResponse = false
        activeMessageId = nil
        responseEnded = true
        notice = message
        VoiceHaptics.error()
        speakNotice(String(localized: "Sorry, something went wrong."))
        if !(speaker?.isActive ?? false) { finishResponse() }
    }

    private func fail(_ failure: VoiceFailure) {
        speaker?.stop()
        setPhase(.failed(failure))
        VoiceHaptics.error()
    }

    private func setPhase(_ newPhase: Phase) {
        guard phase != newPhase else { return }
        phase = newPhase
        stateChanges += 1
    }

    // MARK: - Audio session events

    private func observeAudioSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            MainActor.assumeIsolated {
                guard let self, let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                switch type {
                case .began:
                    self.pauseForInterruption()
                case .ended:
                    if AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume) {
                        self.resumeAfterInterruption()
                    }
                @unknown default:
                    break
                }
            }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] note in
            nonisolated(unsafe) let object = note.object
            MainActor.assumeIsolated {
                guard let self, self.audio.owns(object) else { return }
                self.rebuildAudioGraph()
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task {
                    try? await Task.detached { try VoiceAudioEngine.activateSession() }.value
                    self.rebuildAudioGraph()
                }
            }
        })
    }

    private func pauseForInterruption() {
        guard phase != .paused, !isClosed else { return }
        if phase == .thinking || phase == .speaking { interrupt() }
        speaker?.stop()
        audio.stop()
        setPhase(.paused)
    }

    private func resumeAfterInterruption() {
        guard phase == .paused, !isClosed else { return }
        Task {
            do {
                try await Task.detached { try VoiceAudioEngine.activateSession() }.value
                try startEngine()
                beginListening(resetTranscript: true)
            } catch {
                fail(.audio(error.localizedDescription))
            }
        }
    }

    // Route changes (AirPods in/out) rebuild the voice-processing unit; the old graph is dead.
    private func rebuildAudioGraph() {
        guard !isClosed, phase != .paused else { return }
        // Enabling voice processing itself triggers a configuration change on some routes:
        // cap restarts so a flapping route can never spin the engine forever.
        let now = ProcessInfo.processInfo.systemUptime
        graphRestarts = graphRestarts.filter { now - $0 < 10 }
        guard graphRestarts.count < 4 else { return }
        graphRestarts.append(now)
        do {
            try audio.restart()
            audio.inputEnabled = !isMuted
            speaker?.replayAfterEngineReset()
        } catch {
            fail(.audio(error.localizedDescription))
        }
    }
}

/// Hands mic buffers to the current transcriber from the audio thread.
final class TranscriberSink: @unchecked Sendable {
    private let lock = NSLock()
    private var transcriber: LiveTranscriber?

    func set(_ transcriber: LiveTranscriber?) { lock.withLock { self.transcriber = transcriber } }

    func append(_ buffer: AVAudioPCMBuffer) {
        let transcriber = lock.withLock { self.transcriber }
        transcriber?.append(buffer)
    }
}

enum VoiceFailure: Equatable {
    case microphoneDenied
    case audio(String)
    case transcription(String)

    var message: String {
        switch self {
        case .microphoneDenied: String(localized: "Nuo has no access to the microphone. Allow it in Settings to talk to your bot.")
        case .audio(let detail): String(localized: "The microphone is not responding (\(detail)). Tap the orb to retry.")
        case .transcription(let detail): detail
        }
    }

    var needsSettings: Bool { self == .microphoneDenied || message.contains(String(localized: "Settings")) }
}

enum VoicePermissions {
    nonisolated static func microphone() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }
}
