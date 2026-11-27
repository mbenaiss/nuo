import Foundation
import Testing

/// A mic that "heard" a fixed recording.
private final class FakeMic: DictationMic {
    let recording: [Float]
    var level: Float { 0.4 }
    var engineID: ObjectIdentifier { ObjectIdentifier(self) }
    private(set) var started = false
    private(set) var stopped = false

    init(seconds: Double) {
        recording = Array(repeating: 0.05, count: Int(seconds * 16_000))
    }

    func start() throws { started = true }
    func stop() { stopped = true }
}

/// Engines that answer from a script, and can hold their answer until released.
@MainActor
private final class FakeDevice: DictationEnvironment {
    var answers: [TranscriptionEngine: [EngineAnswer]] = [:]
    var holds = false
    var recordingSeconds = 4.0
    var cloudEnabled = true
    var whisperReady = true
    var inBackground = false
    var preferredLanguage: String? = "fr"
    /// What the gateway says when asked whether it can transcribe: nil is no answer.
    var reachable: Bool? = true
    var holdsPermission = false
    var activationFails = false
    /// The warm-up waits on something it cannot cancel, like a token refresh to an unreachable gateway.
    var slowWarm = false
    private(set) var calls: [TranscriptionEngine] = []
    private(set) var feedback: [DictationFeedback] = []
    private(set) var mics: [FakeMic] = []
    private var held: [CheckedContinuation<Void, Never>] = []

    var waiting: Int { held.count }

    func release() {
        let continuations = held
        held = []
        continuations.forEach { $0.resume() }
    }

    func microphoneAllowed() async -> Bool {
        if holdsPermission { await withCheckedContinuation { held.append($0) } }
        return true
    }
    func activateSession() async throws {
        if activationFails { throw CocoaError(.featureUnsupported) }
    }
    func deactivateSession() async {}
    func makeMic() -> DictationMic {
        let mic = FakeMic(seconds: recordingSeconds)
        mics.append(mic)
        return mic
    }
    func warmCloud() async -> Bool? {
        if slowWarm {
            try? await Task.sleep(for: .seconds(5))
            return nil
        }
        return reachable
    }
    func prewarm() {}
    func terms(_ extra: [String]) -> [String] { ["Julie Martin"] + extra }
    func feedback(_ kind: DictationFeedback) { feedback.append(kind) }
    func beginBackgroundWindow() -> @MainActor () -> Void { {} }

    func transcribe(_ samples: [Float], with engine: TranscriptionEngine, terms: [String]) async -> EngineAnswer {
        calls.append(engine)
        let answer = answers[engine]?.isEmpty == false ? answers[engine]!.removeFirst() : .failed
        if holds { await withCheckedContinuation { held.append($0) } }
        return answer
    }
}

@MainActor
private final class Field {
    var text: String
    init(_ text: String = "") { self.text = text }
    var access: DictationField { DictationField(read: { self.text }, write: { self.text = $0 }) }
}

@MainActor
private func eventually(_ condition: () -> Bool) async {
    for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
}

@MainActor
struct DictationControllerTests {
    private let spoken = EngineAnswer.text("Euh, rappelle-moi d'appeler Julie Martin demain à 9 h pour la facture EDF.")
    private let written = "Rappelle-moi d'appeler Julie Martin demain à 9 h pour la facture EDF."

    @Test func stopWritesTheTranscriptionOnceAfterWhatTheFieldHeld() async {
        let device = FakeDevice()
        device.answers[.cloud] = [spoken]
        let controller = DictationController(environment: device)
        let field = Field("Note :")
        await controller.start(key: "composer-coach", vocabulary: ["Coach"], field: field.access)
        #expect(controller.phase == .listening && device.mics.first?.started == true)
        #expect(field.text == "Note :")
        controller.finish()
        await controller.settled()
        #expect(field.text == "Note : " + written)
        #expect(device.calls == [.cloud])
        #expect(device.mics.first?.stopped == true)
        #expect(controller.phase == .idle && controller.activeKey == nil)
        #expect(device.feedback == [.start, .success])
    }

    @Test func sendGoesOutOnceTheTextIsInTheField() async {
        let device = FakeDevice()
        device.answers[.cloud] = [spoken]
        let controller = DictationController(environment: device)
        let field = Field()
        var sent: [String] = []
        await controller.start(key: "home-dock", vocabulary: [], field: field.access)
        controller.finish { sent.append(field.text) }
        await controller.settled()
        #expect(sent == [written])
    }

    @Test func cancelWhileListeningKeepsTheFieldAndTranscribesNothing() async {
        let device = FakeDevice()
        let controller = DictationController(environment: device)
        let field = Field("Brouillon du compte rendu")
        await controller.start(key: "composer-cobot", vocabulary: [], field: field.access)
        controller.cancel()
        #expect(controller.phase == .idle)
        #expect(field.text == "Brouillon du compte rendu")
        #expect(device.mics.first?.stopped == true)
        #expect(device.calls.isEmpty)
    }

    @Test func cancelRightAfterSendWritesAndSendsNothingEvenWhenTheAnswerComesLate() async {
        let device = FakeDevice()
        device.answers[.cloud] = [spoken, .text("Prépare une séance de fractionné pour jeudi.")]
        device.holds = true
        let controller = DictationController(environment: device)
        let field = Field()
        var sent: [String] = []
        await controller.start(key: "composer-coach", vocabulary: [], field: field.access)
        controller.finish { sent.append(field.text) }
        await eventually { device.waiting == 1 }
        controller.cancel()
        #expect(controller.phase == .idle)

        // A new dictation in the same field, while the old answer is still on its way.
        await controller.start(key: "composer-coach", vocabulary: [], field: field.access)
        controller.finish()
        await eventually { device.waiting == 2 }
        device.release()
        await controller.settled()
        await eventually { field.text != "" }
        #expect(field.text == "Prépare une séance de fractionné pour jeudi.")
        #expect(sent.isEmpty)
    }

    @Test func aFailedCloudFallsBackOnTheDevice() async {
        let device = FakeDevice()
        device.answers[.cloud] = [.failed]
        device.answers[.whisper] = [.text("Peux-tu décaler le rendez-vous chez le kiné à vendredi ?")]
        let controller = DictationController(environment: device)
        let field = Field()
        await controller.start(key: "composer-coach", vocabulary: [], field: field.access)
        controller.finish()
        await controller.settled()
        #expect(device.calls == [.cloud, .whisper])
        #expect(field.text == "Peux-tu décaler le rendez-vous chez le kiné à vendredi ?")
    }

    @Test func aGatewayWithoutServiceIsSkippedNextTime() async {
        let device = FakeDevice()
        device.answers[.cloud] = [.noService]
        device.answers[.whisper] = [.text("Ajoute du pain à la liste."), .text("Et du lait.")]
        let controller = DictationController(environment: device)
        let field = Field()
        await controller.start(key: "reminder-quick-entry", vocabulary: [], field: field.access)
        controller.finish()
        await controller.settled()
        await controller.start(key: "reminder-quick-entry", vocabulary: [], field: field.access)
        controller.finish()
        await controller.settled()
        #expect(device.calls == [.cloud, .whisper, .whisper])
        #expect(field.text == "Ajoute du pain à la liste. Et du lait.")
    }

    @Test func whenEveryEngineFailsTheFieldStaysAndTheUserIsTold() async {
        let device = FakeDevice()
        device.whisperReady = false
        let controller = DictationController(environment: device)
        let field = Field("Facture EDF")
        await controller.start(key: "composer-coach", vocabulary: [], field: field.access)
        controller.finish()
        await controller.settled()
        #expect(device.calls == [.cloud, .apple])
        #expect(field.text == "Facture EDF")
        #expect(controller.alertKey == "composer-coach" && controller.alert != nil)
        #expect(device.feedback.last == .failure)
    }

    @Test func anotherFieldWaitsForTheTextOfTheFirst() async {
        let device = FakeDevice()
        device.answers[.cloud] = [spoken]
        device.holds = true
        let controller = DictationController(environment: device)
        let home = Field()
        let composer = Field("Pour Coach :")
        await controller.start(key: "home-dock", vocabulary: [], field: home.access)
        controller.finish()
        await eventually { device.waiting == 1 }
        let second = Task { await controller.start(key: "composer-coach", vocabulary: [], field: composer.access) }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(controller.activeKey == "home-dock" && controller.phase == .finishing)
        device.release()
        await second.value
        #expect(home.text == written)
        #expect(composer.text == "Pour Coach :")
        #expect(controller.activeKey == "composer-coach" && controller.phase == .listening)
        controller.cancel()
    }

    @Test func whatIsTypedDuringTheTranscriptionStays() async {
        let device = FakeDevice()
        device.answers[.cloud] = [.text("d'appeler Julie Martin demain.")]
        device.holds = true
        let controller = DictationController(environment: device)
        let field = Field()
        await controller.start(key: "composer-coach", vocabulary: [], field: field.access)
        controller.finish()
        await eventually { device.waiting == 1 }
        field.text = "Rappelle-moi"
        device.release()
        await controller.settled()
        #expect(field.text == "Rappelle-moi d'appeler Julie Martin demain.")
    }

    @Test func aGatewayThatDoesNotAnswerIsSkippedAtOnce() async {
        let device = FakeDevice()
        device.reachable = nil
        device.answers[.whisper] = [.text("Rappelle-moi d'appeler le plombier.")]
        let controller = DictationController(environment: device)
        let field = Field()
        await controller.start(key: "composer-coach", vocabulary: [], field: field.access)
        controller.finish()
        await controller.settled()
        #expect(device.calls == [.whisper])
        #expect(field.text == "Rappelle-moi d'appeler le plombier.")
    }

    @Test func anEmptyAnswerFromTheCloudIsSilenceNotAFailure() async {
        let device = FakeDevice()
        device.recordingSeconds = 12
        device.answers[.cloud] = [.text("")]
        device.answers[.whisper] = [.text("Merci d'avoir regardé cette vidéo.")]
        let controller = DictationController(environment: device)
        let field = Field()
        await controller.start(key: "composer-coach", vocabulary: [], field: field.access)
        controller.finish()
        await controller.settled()
        // Whisper would have made a sentence up from the noise.
        #expect(device.calls == [.cloud])
        #expect(field.text == "")
    }

    @Test func nothingHeardIsAShortNoteUnderTheFieldNotADialog() async {
        let device = FakeDevice()
        device.answers[.cloud] = [.text("")]
        let controller = DictationController(environment: device)
        let field = Field("Courses :")
        await controller.start(key: "composer-coach", vocabulary: [], field: field.access)
        controller.finish()
        await controller.settled()
        #expect(field.text == "Courses :")
        #expect(controller.alert == nil)
        #expect(controller.notice?.key == "composer-coach" && controller.notice?.text == DictationController.nothingHeard)
    }

    @Test func theDeviceCanTryAgainOnATakeTheCloudHeardNothingIn() async {
        let device = FakeDevice()
        device.answers[.cloud] = [.text("")]
        device.answers[.whisper] = [.text("Rappelle-moi d'appeler Julie Martin demain.")]
        let controller = DictationController(environment: device)
        let field = Field()
        await controller.start(key: "composer-coach", vocabulary: [], field: field.access)
        controller.finish()
        await controller.settled()
        #expect(controller.notice?.canRetry == true)
        controller.retryOnDevice()
        await controller.settled()
        #expect(device.calls == [.cloud, .whisper])
        #expect(field.text == "Rappelle-moi d'appeler Julie Martin demain.")
        #expect(controller.notice == nil)
        // The take is gone once used.
        controller.retryOnDevice()
        await controller.settled()
        #expect(device.calls == [.cloud, .whisper])
    }

    @Test func theKeptTakeGoesWithItsNotice() async {
        let device = FakeDevice()
        device.answers[.cloud] = [.text("")]
        device.answers[.whisper] = [.text("Ajoute du pain.")]
        let controller = DictationController(environment: device)
        controller.noticeDuration = .milliseconds(50)
        let field = Field()
        await controller.start(key: "composer-coach", vocabulary: [], field: field.access)
        controller.finish()
        await controller.settled()
        await eventually { controller.notice == nil }
        controller.retryOnDevice()
        await controller.settled()
        #expect(device.calls == [.cloud])
        #expect(field.text == "")
    }

    @Test func aRetryBothEnginesFailIsAFailureNotSilence() async {
        let device = FakeDevice()
        device.answers[.cloud] = [.text("")]
        device.answers[.whisper] = [.failed]
        device.answers[.apple] = [.failed]
        let controller = DictationController(environment: device)
        await controller.start(key: "composer-coach", vocabulary: [], field: Field().access)
        controller.finish()
        await controller.settled()
        controller.retryOnDevice()
        await controller.settled()
        #expect(device.calls == [.cloud, .whisper, .apple])
        #expect(controller.alert == DictationController.notTranscribed && controller.notice == nil)
    }

    @Test func theNoticeWaitsWhileItsChoiceIsOpen() async {
        let device = FakeDevice()
        device.answers[.cloud] = [.text("")]
        device.answers[.whisper] = [.text("Ajoute du pain à la liste.")]
        let controller = DictationController(environment: device)
        controller.noticeDuration = .milliseconds(150)
        let field = Field()
        await controller.start(key: "composer-coach", vocabulary: [], field: field.access)
        controller.finish()
        await controller.settled()
        controller.holdNotice(true)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(controller.notice?.canRetry == true)
        controller.holdNotice(false)
        controller.retryOnDevice()
        await controller.settled()
        #expect(field.text == "Ajoute du pain à la liste.")
    }

    @Test func aTakeUnderASecondSaysNothing() async {
        let device = FakeDevice()
        device.recordingSeconds = 0.6
        device.answers[.cloud] = [.text("")]
        let controller = DictationController(environment: device)
        await controller.start(key: "composer-coach", vocabulary: [], field: Field().access)
        controller.finish()
        await controller.settled()
        #expect(device.calls == [.cloud])
        #expect(controller.notice == nil && controller.alert == nil)
    }

    @Test func aGatewayStuckOnATokenRefreshStillGivesWayWithinTheLimit() async {
        let device = FakeDevice()
        device.slowWarm = true
        device.answers[.whisper] = [.text("Rappelle-moi d'appeler Julie Martin.")]
        let controller = DictationController(environment: device)
        controller.reachTimeout = .milliseconds(200)
        let field = Field()
        await controller.start(key: "composer-coach", vocabulary: [], field: field.access)
        let clock = ContinuousClock.now
        controller.finish()
        await controller.settled()
        #expect(ContinuousClock.now - clock < .seconds(1))
        #expect(device.calls == [.whisper])
        #expect(field.text == "Rappelle-moi d'appeler Julie Martin.")
    }

    @Test func umStaysInAGermanDictation() async {
        let device = FakeDevice()
        device.answers[.cloud] = [.text("Wir treffen uns um 9 Uhr.", language: "de")]
        let controller = DictationController(environment: device)
        let field = Field()
        await controller.start(key: "composer-coach", vocabulary: [], field: field.access)
        controller.finish()
        await controller.settled()
        #expect(field.text == "Wir treffen uns um 9 Uhr.")
    }

    @Test func leavingTheScreenWhileTheMicIsAskedForNeverOpensIt() async {
        let device = FakeDevice()
        device.holdsPermission = true
        let controller = DictationController(environment: device)
        let field = Field()
        let starting = Task { await controller.start(key: "home-dock", vocabulary: [], field: field.access) }
        await eventually { device.waiting == 1 }
        #expect(controller.phase == .starting)
        controller.leave("home-dock")
        #expect(controller.phase == .idle)
        device.release()
        await starting.value
        #expect(device.mics.isEmpty)
        #expect(controller.alert == nil)
    }

    @Test func aMicFailingAfterACancelSaysNothing() async {
        let device = FakeDevice()
        device.holdsPermission = true
        device.activationFails = true
        let controller = DictationController(environment: device)
        let field = Field()
        let starting = Task { await controller.start(key: "composer-coach", vocabulary: [], field: field.access) }
        await eventually { device.waiting == 1 }
        controller.cancel()
        device.release()
        await starting.value
        #expect(controller.alert == nil)
        // Without the cancel, the same failure is explained.
        device.holdsPermission = false
        await controller.start(key: "composer-coach", vocabulary: [], field: field.access)
        #expect(controller.alert == "The microphone is not available.")
    }

    @Test func aTapWithoutSpeechTranscribesNothing() async {
        let device = FakeDevice()
        device.recordingSeconds = 0.1
        let controller = DictationController(environment: device)
        let field = Field("Courses")
        await controller.start(key: "composer-coach", vocabulary: [], field: field.access)
        controller.finish()
        await controller.settled()
        #expect(device.calls.isEmpty)
        #expect(field.text == "Courses")
    }
}
