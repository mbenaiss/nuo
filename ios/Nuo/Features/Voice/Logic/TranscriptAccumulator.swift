import Foundation

/// One update from a live transcriber. `end` is the audio time (seconds since the stream started)
/// the result covers up to, or `nil` when the engine does not report time ranges.
struct TranscriptUpdate: Sendable, Equatable {
    var text: String
    var isFinal: Bool
    var start: TimeInterval?
    var end: TimeInterval?
    /// Engines that restart per turn bump this; updates from an older turn are stale.
    var turn: Int = 0
}

/// Builds the user's current utterance from final + volatile transcriber results, ignoring
/// anything that belongs to audio before the last turn boundary.
struct TranscriptAccumulator {
    private(set) var finals: [String] = []
    private(set) var volatile = ""
    private(set) var boundary: TimeInterval = 0
    private(set) var turn = 0
    private(set) var lastChange: TimeInterval = 0

    var text: String {
        (finals + [volatile])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var isEmpty: Bool { text.isEmpty }
    var hasPendingVolatile: Bool { !volatile.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Returns true when the visible text changed.
    @discardableResult
    mutating func apply(_ update: TranscriptUpdate, now: TimeInterval) -> Bool {
        guard update.turn >= turn else { return false }
        // Results that began before the boundary belong to the previous utterance (or to the bot's echo).
        if let start = update.start, start < boundary - 0.15 { return false }
        if let end = update.end, end <= boundary { return false }
        let before = text
        if update.isFinal {
            finals.append(update.text)
            volatile = ""
        } else {
            volatile = update.text
        }
        let changed = text != before
        if changed { lastChange = now }
        return changed
    }

    /// Starts a new utterance: drops everything heard so far.
    mutating func reset(boundary: TimeInterval, turn: Int, now: TimeInterval) {
        finals = []
        volatile = ""
        self.boundary = boundary
        self.turn = turn
        lastChange = now
    }
}

/// Decides when the user has finished talking.
struct EndOfTurnDetector {
    /// Silence after the last voiced buffer that ends the turn.
    var silence: TimeInterval = 0.9
    /// Shorter silence accepted once the transcriber has already finalized everything.
    var silenceWhenFinal: TimeInterval = 0.6
    /// Transcript must have stopped moving for this long (the recognizer lags the audio).
    var transcriptSettle: TimeInterval = 0.35
    /// Fallback when the VAD missed the speech entirely (quiet mic): transcript frozen this long.
    var transcriptOnlyTimeout: TimeInterval = 1.6

    /// `lastVoice` is the last time the VAD heard voice during this turn, nil if it never did.
    func isTurnOver(transcript: TranscriptAccumulator, lastVoice: TimeInterval?, now: TimeInterval) -> Bool {
        guard !transcript.isEmpty else { return false }
        let settled = now - transcript.lastChange
        guard settled >= transcriptSettle else { return false }
        if let lastVoice {
            let quiet = now - lastVoice
            if quiet >= silence { return true }
            return !transcript.hasPendingVolatile && quiet >= silenceWhenFinal
        }
        return settled >= transcriptOnlyTimeout
    }
}

/// Short spoken fillers so a slow answer never feels like a dropped call.
struct FillerPicker {
    static var first: [String] {
        [String(localized: "Let me look…"), String(localized: "One second…"), String(localized: "Let's see…"), String(localized: "Let me check…"),
         String(localized: "Hmm, let me have a look…"), String(localized: "Okay, I'm looking…")]
    }
    static var longer: [String] {
        [String(localized: "This is taking a little longer…"), String(localized: "I'm still on it…"), String(localized: "Just a moment longer…")]
    }

    private var lastFirst: String?
    private var lastLonger: String?

    mutating func next(long: Bool) -> String {
        let pool = long ? Self.longer : Self.first
        let previous = long ? lastLonger : lastFirst
        let choice = pool.filter { $0 != previous }.randomElement() ?? pool[0]
        if long { lastLonger = choice } else { lastFirst = choice }
        return choice
    }
}
