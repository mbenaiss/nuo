@preconcurrency import AVFoundation
import Foundation
#if canImport(UIKit)
import UIKit
#endif

extension DictationController {
    static let shared = DictationController(environment: LiveDictationEnvironment())
}

/// The real mic, the gateway's transcription, Whisper and Apple's recognizer on the device.
@MainActor
final class LiveDictationEnvironment: DictationEnvironment {
    private var observers: [NSObjectProtocol] = []

    init() {
        observeInterruptions()
    }

    func microphoneAllowed() async -> Bool { await AVAudioApplication.requestRecordPermission() }

    func activateSession() async throws {
        try await Task.detached { try DictationRecorder.activateSession() }.value
    }

    func deactivateSession() async {
        await Task.detached { DictationRecorder.deactivateSession() }.value
    }

    func makeMic() -> DictationMic { DictationRecorder() }

    var cloudEnabled: Bool { DictationModelStore.shared.useCloud }

    var whisperReady: Bool {
        let store = DictationModelStore.shared
        return WhisperModel.allCases.contains { store.readyFolder($0) != nil }
    }

    /// « Auto » is French first.
    var preferredLanguage: String? { DictationModelStore.shared.language.whisperCode ?? "fr" }

    var inBackground: Bool {
        #if os(iOS)
        UIApplication.shared.applicationState == .background
        #else
        false
        #endif
    }

    func warmCloud() async -> Bool? {
        guard let client = PushManager.shared.api as? NuoClient else { return nil }
        do {
            _ = try await client.warmTranscription(timeout: 5)
            return true
        } catch NuoError.notFound {
            return false
        } catch {
            return nil
        }
    }

    /// Whisper is only loaded when it is the engine of choice.
    func prewarm() {
        #if os(macOS)
        // A Mac has room and a steady connection: Whisper is there offline when the gateway is not.
        DictationModelStore.shared.downloadIfMissing()
        #endif
        if !DictationModelStore.shared.useCloud { Task { _ = await loadWhisper() } }
    }

    func terms(_ extra: [String]) -> [String] { DictationVocabulary.terms(extra: extra) }

    func transcribe(_ samples: [Float], with engine: TranscriptionEngine, terms: [String]) async -> EngineAnswer {
        let started = ContinuousClock.now
        let answer: EngineAnswer
        switch engine {
        case .cloud: answer = await cloudPass(samples, terms: terms)
        case .whisper: answer = await whisperPass(samples, terms: terms) ?? .failed
        case .apple: answer = await applePass(samples) ?? .failed
        }
        if case let .text(text, _) = answer {
            let seconds = Double(samples.count) / Double(WhisperEngine.sampleRate)
            dictationLog.notice("\(engine.rawValue, privacy: .public): \(text.count) chars in \((ContinuousClock.now - started).seconds, format: .fixed(precision: 2), privacy: .public) s for \(seconds, format: .fixed(precision: 1), privacy: .public) s of audio")
        }
        return answer
    }

    func feedback(_ kind: DictationFeedback) {
        switch kind {
        case .start: Haptics.tap()
        case .success: Haptics.success()
        case .failure: Haptics.error()
        }
    }

    func beginBackgroundWindow() -> @MainActor () -> Void {
        #if os(iOS)
        let window = BackgroundWindow()
        window.id = UIApplication.shared.beginBackgroundTask(withName: AppIdentity.local(.dictationFinishTask)) {
            MainActor.assumeIsolated { window.end() }
        }
        return { window.end() }
        #else
        return {}
        #endif
    }

    // MARK: - Engines

    private func cloudPass(_ samples: [Float], terms: [String]) async -> EngineAnswer {
        guard let client = PushManager.shared.api as? NuoClient else { return .failed }
        let seconds = Double(samples.count) / Double(WhisperEngine.sampleRate)
        let languages = TranscriptionForm.languages(DictationModelStore.shared.language.whisperCode)
        let clock = ContinuousClock.now
        let encoded = await Task.detached(priority: .userInitiated) { () -> Data? in
            let url = URL.temporaryDirectory.appending(path: "dictation-\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: url) }
            return try? AACWriter.encode(samples, to: url)
        }.value
        guard let audio = encoded else { return .failed }
        let encodedIn = (ContinuousClock.now - clock).seconds
        let form = TranscriptionForm(audio: audio, filename: "dictation.m4a", language: languages.language, otherLanguages: languages.others,
                                     keyterms: terms, seconds: seconds)
        let timeout = TranscriptionDeadline.seconds(forAudio: seconds, bytes: audio.count)
        do {
            let transcript = try await client.transcribe(form, timeout: timeout)
            dictationLog.notice("cloud: \(audio.count) bytes encoded in \(encodedIn * 1000, format: .fixed(precision: 0), privacy: .public) ms, round trip \((ContinuousClock.now - clock).seconds, format: .fixed(precision: 2), privacy: .public) s, provider \(transcript.ms ?? -1) ms (\(transcript.provider ?? "?", privacy: .public) \(transcript.model ?? "?", privacy: .public))")
            return .text(transcript.text.trimmingCharacters(in: .whitespacesAndNewlines), language: transcript.language)
        } catch NuoError.notFound {
            return .noService
        } catch {
            dictationLog.error("cloud transcription failed: \(String(describing: error), privacy: .public)")
            return .failed
        }
    }

    private func whisperPass(_ samples: [Float], terms: [String]) async -> EngineAnswer? {
        await WhisperEngine.shared.hold()
        defer { Task { await WhisperEngine.shared.release() } }
        guard await loadWhisper() else { return nil }
        let language = await resolveLanguage(samples)
        do {
            let pass = try await WhisperEngine.shared.transcribe(samples, language: language, prompt: DictationVocabulary.prompt(terms))
            return .text(pass.text, language: pass.language)
        } catch {
            dictationLog.error("Whisper pass failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func applePass(_ samples: [Float]) async -> EngineAnswer? {
        do {
            let locale = try await AppleFileTranscriber.prepare(DictationModelStore.shared.language.appleLocale)
            let segments = try await AppleFileTranscriber.transcribe(samples, locale: locale)
            return .text(WhisperText.join(segments.map(\.text)), language: locale.language.languageCode?.identifier)
        } catch {
            dictationLog.error("Apple pass failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Loads the selected model, or the other one if only that one is downloaded. False when none is ready.
    private func loadWhisper() async -> Bool {
        let store = DictationModelStore.shared
        let candidates = [store.selected] + WhisperModel.allCases.filter { $0 != store.selected }
        guard let model = candidates.first(where: { store.readyFolder($0) != nil }), let folder = store.readyFolder(model) else { return false }
        if await WhisperEngine.shared.isReady(model) { return true }
        do {
            try await WhisperEngine.shared.load(model, folder: folder, holding: true)
            return true
        } catch {
            dictationLog.error("Whisper load failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func resolveLanguage(_ samples: [Float]) async -> String {
        if let code = DictationModelStore.shared.language.whisperCode { return code }
        let head = Array(samples.prefix(WhisperEngine.sampleRate * 4))
        guard head.count >= WhisperEngine.sampleRate * 2 else { return "fr" }
        return await WhisperEngine.shared.detectLanguage(head)
    }

    // MARK: - Interruptions

    /// Locking the screen or leaving the app does not stop a dictation: the `audio` background mode keeps the mic
    /// running. Only a real audio interruption (call, Siri) ends it, keeping what was heard.
    private func observeInterruptions() {
        let center = NotificationCenter.default
        #if os(iOS)
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init) == .began
            guard began else { return }
            MainActor.assumeIsolated { DictationController.shared.finish() }
        })
        #endif
        // Route change (headset unplugged, mic switched): the engine stops on its own, keep what was heard.
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { note in
            guard let engine = (note.object as AnyObject?).map(ObjectIdentifier.init) else { return }
            MainActor.assumeIsolated { DictationController.shared.micStopped(engineID: engine) }
        })
    }
}

#if os(iOS)
@MainActor
private final class BackgroundWindow {
    var id = UIBackgroundTaskIdentifier.invalid

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
#endif

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

/// Proper nouns a transcription would otherwise spell phonetically: the user's first name, bots, areas and projects.
@MainActor
enum DictationVocabulary {
    static var botNames: [String] = []

    /// At most 100: past that the cloud service bills every request as at least 20 s.
    static func terms(extra: [String], limit: Int = 100) -> [String] {
        let reminders = RemindersStore.shared
        let userName = UserNamePreference.standard.load()
        let candidates = [userName] + extra + botNames + reminders.areas.map(\.title) + reminders.projects.filter(\.isOpen).map(\.title)
        return DictationTerms.unique(candidates, limit: limit)
    }

    /// The terms as a Whisper prompt.
    static func prompt(_ terms: [String]) -> String {
        let kept = Array(terms.prefix(30))
        return kept.isEmpty ? "" : kept.joined(separator: ", ") + "."
    }

    static func prompt(extra: [String]) -> String { prompt(terms(extra: extra)) }
}
