import Foundation

/// Energy-based voice activity detector with an adaptive noise floor.
/// Feed it one level per audio buffer (dBFS) with a monotonic timestamp.
struct VoiceActivityDetector {
    struct Config: Sendable {
        /// dB above the noise floor that counts as voice.
        var margin: Float = 11
        /// Never treat anything quieter than this as voice, however quiet the room.
        var absoluteMinimum: Float = -52
        /// Voice must last this long before it counts as speech (filters clicks and coughs).
        var minimumSpeech: TimeInterval = 0.22
        /// Silence after speech that closes the utterance.
        var endSilence: TimeInterval = 0.9
        /// Once speaking, tolerate dips this many dB under the threshold (hysteresis).
        var hysteresis: Float = 5
    }

    enum Event: Equatable, Sendable {
        case speechStarted
        case speechEnded(duration: TimeInterval)
    }

    private enum State: Equatable {
        case idle
        case onset(start: TimeInterval)
        case speaking(start: TimeInterval, lastVoice: TimeInterval)
    }

    var config: Config
    private(set) var noiseFloor: Float = -60
    private var state: State = .idle

    init(config: Config = Config()) {
        self.config = config
    }

    var isSpeaking: Bool {
        if case .speaking = state { return true }
        return false
    }

    var threshold: Float { max(noiseFloor + config.margin, config.absoluteMinimum) }

    /// How long the current voice burst has lasted (onset included), 0 when silent.
    func voiceDuration(at time: TimeInterval) -> TimeInterval {
        switch state {
        case .idle: 0
        case .onset(let start), .speaking(let start, _): time - start
        }
    }

    /// Time of the last voiced buffer while speaking, nil otherwise.
    var lastVoiceTime: TimeInterval? {
        if case .speaking(_, let lastVoice) = state { return lastVoice }
        return nil
    }

    mutating func process(level: Float, at time: TimeInterval) -> Event? {
        let level = level.isFinite ? max(level, -120) : -120
        switch state {
        case .idle:
            adaptFloor(to: level)
            if level > threshold { state = .onset(start: time) }
            return nil
        case .onset(let start):
            if level <= threshold {
                state = .idle
                adaptFloor(to: level)
                return nil
            }
            if time - start >= config.minimumSpeech {
                state = .speaking(start: start, lastVoice: time)
                return .speechStarted
            }
            return nil
        case .speaking(let start, let lastVoice):
            if level > threshold - config.hysteresis {
                state = .speaking(start: start, lastVoice: time)
                return nil
            }
            if time - lastVoice >= config.endSilence {
                state = .idle
                return .speechEnded(duration: lastVoice - start)
            }
            return nil
        }
    }

    mutating func reset() {
        state = .idle
    }

    // Falls fast (a quieter room is trusted at once) and rises slowly (speech must not raise its own bar).
    private mutating func adaptFloor(to level: Float) {
        let rate: Float = level < noiseFloor ? 0.2 : 0.015
        noiseFloor += (level - noiseFloor) * rate
        noiseFloor = min(max(noiseFloor, -90), -25)
    }
}

/// Decides whether what the mic hears while the bot talks is the user cutting in or the bot's own echo.
struct BargeInPolicy {
    /// Sustained loud voice needed to interrupt on energy alone.
    var energyDuration: TimeInterval = 0.3
    /// Extra margin over the floor required on energy alone while the bot is audible.
    var energyMargin: Float = 18

    func shouldInterrupt(transcript: String, recentlySpoken: [String], voiceDuration: TimeInterval, level: Float, noiseFloor: Float) -> Bool {
        if isUserSpeech(transcript, recentlySpoken: recentlySpoken) { return true }
        return voiceDuration >= energyDuration && level > noiseFloor + energyMargin
    }

    /// Non-empty transcript that is not just the bot's own words picked up again.
    func isUserSpeech(_ transcript: String, recentlySpoken: [String]) -> Bool {
        let heard = Self.words(transcript).filter { $0.count >= 2 }
        guard !heard.isEmpty else { return false }
        let spoken = Set(recentlySpoken.flatMap(Self.words))
        guard !spoken.isEmpty else { return true }
        let foreign = heard.filter { !spoken.contains($0) }
        return Double(foreign.count) / Double(heard.count) >= 0.5
    }

    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }
}
