import AVFoundation
import Observation

/// Reads answers aloud with the best French voice installed on the watch.
@MainActor
@Observable
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private(set) var isSpeaking = false

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private lazy var voice: AVSpeechSynthesisVoice? = {
        let french = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "fr-FR" }
        return french.first { $0.quality == .premium }
            ?? french.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: "fr-FR")
    }()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        // Switching the session to playback would stop a recording, or a request being spoken.
        guard !text.isEmpty, !VoiceRecorder.shared.isActive, !AskCenter.shared.isListening else { return }
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        WatchAudioSession.acquire("speaker")
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        guard synthesizer.isSpeaking || isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.done() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.done() }
    }

    private func done() {
        isSpeaking = false
        WatchAudioSession.release("speaker")
    }
}
