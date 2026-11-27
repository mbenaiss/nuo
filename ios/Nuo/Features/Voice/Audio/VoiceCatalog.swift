@preconcurrency import AVFoundation
import Foundation

/// Lists the installed system voices for the conversation language and remembers the user's pick.
enum VoiceCatalog {
    static let preferenceKey = "nuo.voice.voiceIdentifier"

    struct Option: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let language: String
        let quality: Quality

        enum Quality: Int, Comparable, Sendable {
            case standard = 1, enhanced = 2, premium = 3

            static func < (lhs: Quality, rhs: Quality) -> Bool { lhs.rawValue < rhs.rawValue }

            var label: String {
                switch self {
                case .premium: String(localized: "Premium")
                case .enhanced: String(localized: "Enhanced")
                case .standard: String(localized: "Standard")
                }
            }
        }
    }

    /// Language of the conversation: the device language, French when the device has no voice for it.
    static var languageCode: String {
        let code = Locale.current.language.languageCode?.identifier ?? "fr"
        let hasVoice = AVSpeechSynthesisVoice.speechVoices().contains { $0.language.hasPrefix(code) }
        return hasVoice ? code : "fr"
    }

    static var recognitionLocale: Locale {
        languageCode == (Locale.current.language.languageCode?.identifier ?? "") ? Locale.current : Locale(identifier: "fr-FR")
    }

    static func options(language: String = languageCode) -> [Option] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { voice in
                voice.language.hasPrefix(language)
                    && !voice.voiceTraits.contains(.isNoveltyVoice)
                    && !voice.voiceTraits.contains(.isPersonalVoice)
            }
            .map { Option(id: $0.identifier, name: $0.name, language: $0.language, quality: quality(of: $0)) }
            .sorted { lhs, rhs in
                if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
                let lhsRegion = lhs.language == preferredRegion(language)
                let rhsRegion = rhs.language == preferredRegion(language)
                if lhsRegion != rhsRegion { return lhsRegion }
                return lhs.name < rhs.name
            }
    }

    /// The saved voice if still installed, else the bot's configured voice if it is a system voice, else the best one.
    static func resolvedVoice(botVoiceId: String?) -> AVSpeechSynthesisVoice? {
        if let saved = UserDefaults.standard.string(forKey: preferenceKey), let voice = AVSpeechSynthesisVoice(identifier: saved) {
            return voice
        }
        if let botVoiceId, let voice = AVSpeechSynthesisVoice(identifier: botVoiceId) {
            return voice
        }
        if let best = options().first, let voice = AVSpeechSynthesisVoice(identifier: best.id) {
            return voice
        }
        return AVSpeechSynthesisVoice(language: "fr-FR")
    }

    static func save(_ identifier: String) {
        UserDefaults.standard.set(identifier, forKey: preferenceKey)
    }

    static var hasHighQualityVoice: Bool {
        options().contains { $0.quality >= .enhanced }
    }

    /// Native sample rate of the voice's synthesized buffers, so playback needs no resampling.
    static func sampleRate(of voice: AVSpeechSynthesisVoice?) -> Double? {
        voice?.audioFileSettings[AVSampleRateKey] as? Double
    }

    private static func preferredRegion(_ language: String) -> String {
        language == "fr" ? "fr-FR" : (Locale.current.language.languageCode?.identifier == language ? Locale.current.identifier(.bcp47) : language)
    }

    private static func quality(of voice: AVSpeechSynthesisVoice) -> Option.Quality {
        switch voice.quality {
        case .premium: .premium
        case .enhanced: .enhanced
        default: .standard
        }
    }
}
