import Foundation
import Observation

/// The mic of one dictation: the whole take as 16 kHz mono floats.
protocol DictationMic: AnyObject {
    /// Smoothed 0...1 input level for the meter.
    var level: Float { get }
    var recording: [Float] { get }
    var engineID: ObjectIdentifier { get }
    func start() throws
    func stop()
}

/// What a dictation needs from the device and the network; tests stand in for it.
@MainActor
protocol DictationEnvironment: AnyObject, Sendable {
    func microphoneAllowed() async -> Bool
    func activateSession() async throws
    func deactivateSession() async
    func makeMic() -> DictationMic
    var cloudEnabled: Bool { get }
    var whisperReady: Bool { get }
    var inBackground: Bool { get }
    /// The language the user dictates in, when no engine says which one it heard.
    var preferredLanguage: String? { get }
    /// Whether the gateway has a transcription service: nil when it could not be asked (offline).
    func warmCloud() async -> Bool?
    /// A composer is about to be typed in.
    func prewarm()
    func terms(_ extra: [String]) -> [String]
    func transcribe(_ samples: [Float], with engine: TranscriptionEngine, terms: [String]) async -> EngineAnswer
    func feedback(_ kind: DictationFeedback)
    /// Keeps the app running until the returned closure is called.
    func beginBackgroundWindow() -> @MainActor () -> Void
}

enum EngineAnswer: Equatable, Sendable {
    /// `language`: the one the engine heard, when it says.
    case text(String, language: String? = nil)
    case failed
    /// The gateway has no transcription service: the next dictations skip it.
    case noService
}

enum DictationFeedback: Equatable { case start, success, failure }

/// Speech to text into a text field. The mic records while the user speaks, with only a level and a timer on screen;
/// at the end one transcription of the whole recording writes the text, once: the gateway's service first, Whisper or
/// Apple's recognizer on the device only when it fails. One dictation at a time, identified by the key of the field
/// that started it.
@MainActor
@Observable
final class DictationController {
    typealias Phase = DictationPhase

    private var ledger = DictationLedger()
    var phase: Phase { ledger.phase }
    var activeKey: String? { ledger.key }
    /// The engine at work while finishing.
    private(set) var engine: TranscriptionEngine?
    private(set) var level: Float = 0
    private(set) var startedAt: Date?
    var alert: String?
    private(set) var alertKey: String?

    /// A short message under a field after its dictation, gone on its own.
    struct Notice: Equatable {
        let key: String
        let text: String
        /// The take is still in memory: it can be transcribed again on the device.
        var canRetry = false
        let id = UUID()
    }

    private(set) var notice: Notice?
    /// How long a notice stays; the take kept for « Réessayer sur l'appareil » goes with it.
    var noticeDuration: Duration = .seconds(10)
    /// The notice's menu is open: its time does not run, so the take is still there when « Réessayer » is chosen.
    @ObservationIgnored private var noticeHeld = false

    /// The last take the cloud heard nothing in, kept only while its notice is on screen.
    private struct Take {
        let key: String
        let samples: [Float]
        let field: DictationField
        let terms: [String]
    }

    @ObservationIgnored private var lastTake: Take?

    @ObservationIgnored private let environment: DictationEnvironment
    @ObservationIgnored private var mic: DictationMic?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var terms: [String] = []
    @ObservationIgnored private var field: DictationField?
    /// The transcription under way, cancelled by ✕ and awaited by a start in another field.
    @ObservationIgnored private var finishing: Task<Void, Never>?
    /// Whether the gateway has a transcription service; nil until it answered once.
    @ObservationIgnored private(set) var cloudAvailable: Bool?
    @ObservationIgnored private var warmedAt = Date.distantPast
    /// Last time the gateway answered: a recent answer spares the check before the upload.
    @ObservationIgnored private var reachedAt: Date?

    private static let maxDuration: TimeInterval = 300
    /// Shorter than this is a tap on the button, not speech.
    static let minimumSamples = 16_000 * 3 / 10
    /// Longer than this, a take that gives no text says so.
    static let noticeAfterSamples = 16_000
    /// How long the gateway gets to answer before the device transcribes instead.
    var reachTimeout: Duration = .seconds(3)
    static var nothingHeard: String { String(localized: "No speech recognized") }
    static var notTranscribed: String { String(localized: "Transcription failed: neither your gateway nor the device could transcribe the recording. Try again.") }

    init(environment: DictationEnvironment) {
        self.environment = environment
    }

    func isActive(_ key: String) -> Bool { activeKey == key && phase != .idle }

    // MARK: - Warm up

    /// A composer is about to be typed in: open the connection to the gateway and its service now, so the text comes
    /// back sooner after the end.
    func prewarm() {
        guard !DictationDemo.isOn else { return }
        Task { await warmCloud() }
        environment.prewarm()
    }

    private func warmCloud() async {
        guard environment.cloudEnabled, Date().timeIntervalSince(warmedAt) > 20 else { return }
        warmedAt = Date()
        if await reach() == nil {
            // Offline or the gateway asleep: the end of the dictation checks again, briefly, before the device takes over.
            warmedAt = .distantPast
        }
    }

    /// Asks the gateway whether it can transcribe, within `timeout`; nil when it does not answer.
    @discardableResult
    private func reach(within timeout: Duration? = nil) async -> Bool? {
        let environment = self.environment
        let answer: Bool?
        if let timeout {
            // Not a task group: it would wait for a token refresh the warm-up cannot cancel.
            answer = await Deadline.first(within: timeout, otherwise: nil) { await environment.warmCloud() }
        } else {
            answer = await environment.warmCloud()
        }
        switch answer {
        case true?:
            reachedAt = Date()
            cloudAvailable = true
        case false?:
            cloudAvailable = false
        case nil:
            reachedAt = nil
        }
        return answer
    }

    // MARK: - Dictation

    func toggle(key: String, vocabulary: [String], field: DictationField) {
        if isActive(key) {
            if phase == .listening { finish() }
            return
        }
        Task { await start(key: key, vocabulary: vocabulary, field: field) }
    }

    func start(key: String, vocabulary: [String], field: DictationField) async {
        switch ledger.step(for: key) {
        case .already:
            return
        case .stopOther:
            if phase == .starting { cancel() } else { finish() }
            await finishing?.value
        case .waitForOther:
            await finishing?.value
        case .start:
            break
        }
        // Another start won the race while the previous dictation ended.
        guard phase == .idle else { return }
        let ticket = ledger.begin(key)
        self.field = field
        lastTake = nil
        notice = nil
        environment.feedback(.start)

        if DictationDemo.isOn {
            playDemo(ticket)
            return
        }
        // Cancelled (or replaced by another field) while the permission was asked: the mic must stay off.
        var starting: Bool { ledger.owns(ticket, in: .starting) }
        let allowed = await environment.microphoneAllowed()
        guard starting else { return }
        guard allowed else {
            fail(key: key, String(localized: "Allow the microphone for Nuo in Settings to dictate."))
            return
        }
        terms = environment.terms(vocabulary)

        let mic = environment.makeMic()
        do {
            try await environment.activateSession()
            guard starting else {
                if phase == .idle { await environment.deactivateSession() }
                return
            }
            try mic.start()
        } catch {
            await environment.deactivateSession()
            // Cancelled or replaced while the mic was opening: nothing to tell.
            guard starting else { return }
            fail(key: key, String(localized: "The microphone is not available."))
            return
        }
        guard ledger.listen(ticket) else {
            mic.stop()
            if phase == .idle { await environment.deactivateSession() }
            return
        }
        self.mic = mic
        startedAt = Date()
        tasks.append(Task { [weak self] in await self?.runLoop() })
        tasks.append(Task { [weak self] in await self?.warmCloud() })
    }

    /// Stops listening and writes the transcription into the field, then runs `then` (« send »).
    func finish(then: (@MainActor () -> Void)? = nil) {
        guard let ticket = ledger.finish() else { return }
        // Finishing after a lock or a call runs in the background: the transcription and the text landing in the
        // field must not be frozen by a suspension halfway.
        let endWindow = environment.beginBackgroundWindow()
        finishing = Task {
            await finishNow(ticket, then: then)
            endWindow()
        }
    }

    /// Drops the recording, or the transcription under way: the field keeps what it holds, nothing is written.
    func cancel() {
        guard phase != .idle else { return }
        // Synchronous, so a start right after it, or an answer arriving late, finds this dictation already gone.
        ledger.cancel()
        finishing?.cancel()
        finishing = nil
        mic?.stop()
        tearDown()
    }

    /// The field's screen goes away: a dictation still asking for the mic stops, one listening is transcribed.
    func leave(_ key: String) {
        guard isActive(key) else { return }
        if phase == .starting { cancel() } else { finish() }
    }

    /// The mic engine stopped on its own (headset unplugged, mic switched): keep what was heard.
    func micStopped(engineID: ObjectIdentifier) {
        guard mic?.engineID == engineID else { return }
        finish()
    }

    /// Waits for the transcription under way, if any.
    func settled() async {
        await finishing?.value
    }

    // MARK: - Loop

    private func runLoop() async {
        while phase == .listening, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
            guard phase == .listening, let mic else { return }
            level = mic.level
            if let startedAt, Date().timeIntervalSince(startedAt) > Self.maxDuration {
                finish()
                return
            }
        }
    }

    // MARK: - Finish

    private func finishNow(_ ticket: Int, then: (@MainActor () -> Void)?) async {
        var current: Bool { ledger.owns(ticket, in: .finishing) && !Task.isCancelled }
        level = 0
        let mic = self.mic
        mic?.stop()
        self.mic = nil
        let key = activeKey
        let field = self.field
        // The mic is free and other audio comes back while the text is on its way.
        await environment.deactivateSession()
        guard current else { return }
        let samples = mic?.recording ?? []
        let spoken = samples.count >= Self.minimumSamples
        let outcome = spoken ? await transcribe(samples, ticket: ticket) : .text("", language: nil)
        // Cancelled or replaced meanwhile: nothing is written.
        guard current, ledger.end(ticket) else { return }
        let text = Disfluency.strip(outcome.text, language: outcome.language ?? environment.preferredLanguage)
        let answered = engine
        tearDown()
        if let field { field.write(DictationLedger.compose(field.read(), text)) }
        if let key {
            if case .failed = outcome {
                alertKey = key
                alert = Self.notTranscribed
            } else if samples.count > Self.noticeAfterSamples, text.isEmpty {
                // Said on screen too: a Mac gives no haptic feedback. The take waits a moment in case the device hears it.
                let retry = environment.whisperReady && answered != .whisper
                if retry, let field { lastTake = Take(key: key, samples: samples, field: field, terms: terms) }
                show(Notice(key: key, text: Self.nothingHeard, canRetry: retry))
            }
        }
        environment.feedback(text.isEmpty ? .failure : .success)
        if !text.isEmpty { then?() }
    }

    enum Outcome {
        case text(String, language: String?)
        case failed

        var text: String {
            if case let .text(text, _) = self { return text }
            return ""
        }

        var language: String? {
            if case let .text(_, language) = self { return language }
            return nil
        }
    }

    private func show(_ notice: Notice) {
        self.notice = notice
        noticeHeld = false
        let step: Duration = .milliseconds(100)
        let duration = noticeDuration
        Task { [weak self] in
            var left = duration
            while left > .zero {
                try? await Task.sleep(for: step)
                guard let self, self.notice == notice else { return }
                if !self.noticeHeld { left -= step }
            }
            guard let self, self.notice == notice else { return }
            self.notice = nil
            self.lastTake = nil
        }
    }

    /// The notice's menu opens or closes.
    func holdNotice(_ held: Bool) {
        noticeHeld = held
    }

    /// The notice was closed by hand: its take goes with it.
    func dismissNotice() {
        notice = nil
        lastTake = nil
        noticeHeld = false
    }

    /// « Réessayer sur l'appareil »: Whisper on the take the cloud heard nothing in; the take is dropped after.
    func retryOnDevice() {
        guard let take = lastTake, phase == .idle else { return }
        lastTake = nil
        notice = nil
        let ticket = ledger.begin(take.key)
        _ = ledger.listen(ticket)
        _ = ledger.finish()
        field = take.field
        let environment = self.environment
        // Like `finish()`: a lock or a call meanwhile must not freeze the text on its way.
        let endWindow = environment.beginBackgroundWindow()
        finishing = Task {
            defer { endWindow() }
            var answer = EngineAnswer.failed
            for engine in [TranscriptionEngine.whisper, .apple] {
                self.engine = engine
                answer = await environment.transcribe(take.samples, with: engine, terms: take.terms)
                guard ledger.owns(ticket, in: .finishing), !Task.isCancelled else { return }
                if case .text = answer { break }
            }
            guard ledger.end(ticket) else { return }
            tearDown()
            guard case let .text(heard, language) = answer else {
                // Neither engine answered: that is not « nothing heard ».
                alertKey = take.key
                alert = Self.notTranscribed
                environment.feedback(.failure)
                return
            }
            let text = Disfluency.strip(heard, language: language ?? environment.preferredLanguage)
            take.field.write(DictationLedger.compose(take.field.read(), text))
            if text.isEmpty { show(Notice(key: take.key, text: Self.nothingHeard)) }
            environment.feedback(text.isEmpty ? .failure : .success)
        }
    }

    /// Each engine in turn until one answers: the gateway, then Whisper, then Apple's recognizer. An empty text from
    /// the gateway is an answer (nobody spoke): Whisper would make sentences up from the noise.
    private func transcribe(_ samples: [Float], ticket: Int) async -> Outcome {
        var order = TranscriptionEngine.order(cloudEnabled: environment.cloudEnabled, cloudAvailable: cloudAvailable,
                                              whisperReady: environment.whisperReady, inBackground: environment.inBackground)
        // A gateway that did not answer lately gets a few seconds, not the whole upload's wait.
        if order.first == .cloud, reachedAt.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
            self.engine = .cloud
            if await reach(within: reachTimeout) != true { order.removeAll { $0 == .cloud } }
            guard ledger.owns(ticket, in: .finishing), !Task.isCancelled else { return .text("", language: nil) }
        }
        for engine in order {
            self.engine = engine
            let answer = await environment.transcribe(samples, with: engine, terms: terms)
            guard ledger.owns(ticket, in: .finishing), !Task.isCancelled else { return .text("", language: nil) }
            switch answer {
            case let .text(text, language):
                if engine == .cloud { cloudAvailable = true }
                return .text(text, language: language)
            case .noService:
                cloudAvailable = false
            case .failed:
                continue
            }
        }
        return .failed
    }

    /// Frees the mic and the screen state of the dictation that just ended; the ledger already says it is over.
    private func tearDown() {
        tasks.forEach { $0.cancel() }
        tasks = []
        if mic != nil {
            mic = nil
            let environment = self.environment
            Task { await environment.deactivateSession() }
        }
        engine = nil
        level = 0
        startedAt = nil
        field = nil
    }

    private func fail(key: String, _ message: String) {
        ledger.cancel()
        tearDown()
        alertKey = key
        alert = message
        environment.feedback(.failure)
    }

    // MARK: - Demo

    /// Listens with a moving level; `-demoDictationFinishing` then holds the transcribing state, `-demoDictationDone`
    /// writes the demo text into the field.
    private func playDemo(_ ticket: Int) {
        startedAt = Date().addingTimeInterval(-6)
        _ = ledger.listen(ticket)
        tasks.append(Task { [weak self] in
            var tick = 0
            while let self, self.phase == .listening, !Task.isCancelled {
                tick += 1
                self.level = Float(0.35 + 0.3 * sin(Double(tick) * 0.7) + Double.random(in: 0...0.25))
                if DictationDemo.finishes, tick == 30 {
                    _ = self.ledger.finish()
                    self.engine = .cloud
                    self.level = 0
                    guard DictationDemo.writesText || DictationDemo.hearsNothing else { return }
                    try? await Task.sleep(for: .milliseconds(1400))
                    let key = self.activeKey
                    guard self.ledger.end(ticket) else { return }
                    if DictationDemo.hearsNothing, let field = self.field, let key {
                        self.lastTake = Take(key: key, samples: [], field: field, terms: [])
                        self.field = nil
                        self.startedAt = nil
                        self.engine = nil
                        self.show(Notice(key: key, text: Self.nothingHeard, canRetry: true))
                        return
                    }
                    if let field = self.field { field.write(DictationLedger.compose(field.read(), Disfluency.strip(DictationDemo.text))) }
                    self.field = nil
                    self.startedAt = nil
                    self.engine = nil
                    return
                }
                try? await Task.sleep(for: .milliseconds(90))
            }
        })
    }
}

/// `-demo -demoDictation "texte"` shows a dictation in progress in the first composer, without a mic.
enum DictationDemo {
    private static var arguments: [String] { ProcessInfo.processInfo.arguments }
    static var isOn: Bool { arguments.contains("-demo") && arguments.contains("-demoDictation") }
    static var text: String {
        guard let index = arguments.firstIndex(of: "-demoDictation"), index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") else {
            return String(localized: "demo.dictation.utterance", defaultValue: "Uh, remind me to call Julie Martin tomorrow at 9 am about the EDF bill.")
        }
        return arguments[index + 1]
    }
    static var finishes: Bool { isOn && (arguments.contains("-demoDictationFinishing") || writesText || hearsNothing) }
    /// `-demoDictationNothingHeard`: the take ends with « Aucune parole reconnue » and its retry.
    static var hearsNothing: Bool { isOn && arguments.contains("-demoDictationNothingHeard") }
    /// `-demoDictationField`: the dictation runs in the mic button of a small field (a reminder's quick entry).
    static var inSmallField: Bool { isOn && arguments.contains("-demoDictationField") }
    static var writesText: Bool { isOn && arguments.contains("-demoDictationDone") }
    /// `-demoDictationHome`: the dictation runs in the home field instead of a chat composer.
    static var onHome: Bool { isOn && arguments.contains("-demoDictationHome") }
    static var opensSettings: Bool { arguments.contains("-demo") && arguments.contains("-demoDictationSettings") }
}
