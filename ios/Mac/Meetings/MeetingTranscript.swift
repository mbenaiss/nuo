import Foundation

enum MeetingSpeaker: String, Codable, Sendable {
    case me, them

    var label: String { self == .me ? "Moi" : "Eux" }
}

struct MeetingSegment: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    var speaker: MeetingSpeaker
    /// Seconds since the meeting started.
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    /// Which of the other participants spoke, "1", "2"…, when the transcription told their voices apart.
    var voice: String?
}

/// Consecutive segments of one speaker, shown and sent to the bot as one paragraph.
struct MeetingTurn: Identifiable, Hashable, Sendable {
    var id: UUID
    var speaker: MeetingSpeaker
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var voice: String?

    /// What the bot reads: « Eux » becomes « Eux · voix 2 » once several voices were heard on their side.
    func label(meName: String, voices: Int) -> String {
        guard speaker == .them else { return meName }
        guard voices > 1, let voice else { return "Eux" }
        return "Eux · voix \(voice)"
    }

    func displayLabel(meName: String, voices: Int) -> String {
        guard speaker == .them else { return meName }
        guard voices > 1, let voice else { return String(localized: "Them") }
        return String(localized: "Them · voice \(voice)")
    }
}

/// The transcript of both streams, in order of speech.
struct MeetingTranscript: Codable, Sendable {
    /// A pause longer than this starts a new paragraph even when the same person keeps talking.
    static let turnGap: TimeInterval = 20

    private(set) var segments: [MeetingSegment] = []
    /// The longest segment so far, which bounds how far back an overlapping one can start; -1 until measured (a
    /// transcript read from disk). Never shrinks: a wider window stays exact.
    private var longest: TimeInterval = -1

    private enum CodingKeys: String, CodingKey { case segments }

    var isEmpty: Bool { segments.isEmpty }
    /// Distinct voices told apart on the others' side.
    var voiceCount: Int { Set(segments.compactMap { $0.speaker == .them ? $0.voice : nil }).count }
    var wordCount: Int { segments.reduce(0) { $0 + $1.text.split(separator: " ").count } }

    var turns: [MeetingTurn] {
        var turns: [MeetingTurn] = []
        for segment in segments {
            if let last = turns.last, last.speaker == segment.speaker, last.voice == segment.voice, segment.start - last.end < Self.turnGap {
                turns[turns.count - 1].text += " " + segment.text
                turns[turns.count - 1].end = max(last.end, segment.end)
            } else {
                turns.append(MeetingTurn(id: segment.id, speaker: segment.speaker, start: segment.start, end: segment.end, text: segment.text,
                                         voice: segment.voice))
            }
        }
        return turns
    }

    /// The two streams are transcribed separately, a chunk at a time: segments arrive in any order.
    /// `language`, the one the text was heard in, decides whether « um » or « uh » are hesitations.
    mutating func insert(_ text: String, speaker: MeetingSpeaker, start: TimeInterval, end: TimeInterval, voice: String? = nil,
                         language: String? = nil) {
        let clean = Disfluency.strip(text, language: language)
        guard !clean.isEmpty else { return }
        let segment = MeetingSegment(speaker: speaker, start: start, end: max(end, start), text: clean, voice: speaker == .them ? voice : nil)
        if longest < 0 { longest = segments.map { $0.end - $0.start }.max() ?? 0 }
        longest = max(longest, segment.end - segment.start)
        // Without headphones the mic hears the other side too: the same words then show up in both streams.
        if speaker == .me, isEcho(segment) { return }
        segments.insert(segment, at: index(after: start))
        if speaker == .them {
            // Only the user's lines around this one can have become its echo: a two-hour meeting stays quick.
            let window = index(from: segment.start - Self.echoWindow - longest)..<index(after: segment.end + Self.echoWindow)
            let echoes = window.filter {
                let mine = segments[$0]
                return mine.speaker == .me && mine.start <= segment.end + Self.echoWindow && mine.end >= segment.start - Self.echoWindow && isEcho(mine)
            }
            for position in echoes.reversed() { segments.remove(at: position) }
        }
    }

    /// The mic hears the speakers a moment later.
    private static let echoWindow: TimeInterval = 4

    /// The first segment starting at or after `time` (segments are sorted by start).
    private func index(from time: TimeInterval) -> Int {
        var low = 0, high = segments.count
        while low < high {
            let middle = (low + high) / 2
            if segments[middle].start < time { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// The first segment starting after `time`.
    private func index(after time: TimeInterval) -> Int {
        var low = 0, high = segments.count
        while low < high {
            let middle = (low + high) / 2
            if segments[middle].start <= time { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// Whether most words of a « Moi » segment were said by « Eux » around the same time.
    private func isEcho(_ mine: MeetingSegment) -> Bool {
        let window = index(from: mine.start - Self.echoWindow - max(longest, 0))..<index(after: mine.end + Self.echoWindow)
        let nearby = window.map { segments[$0] }.filter { $0.speaker == .them && $0.end >= mine.start - Self.echoWindow && $0.start <= mine.end + Self.echoWindow }
        guard !nearby.isEmpty else { return false }
        let words = Self.words(mine.text)
        guard words.count >= 3 else { return false }
        let theirs = nearby.reduce(into: Set<String>()) { $0.formUnion(Self.words($1.text)) }
        return Double(words.intersection(theirs).count) / Double(words.count) >= 0.6
    }

    private static let french = Locale(identifier: "fr")

    private static func words(_ text: String) -> Set<String> {
        Set(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: french)
            .split { !$0.isLetter && !$0.isNumber }
            .filter { $0.count > 2 }
            .map(String.init))
    }

    /// What the bot reads: the labels stay French, the prompt refers to them.
    func plainText(meName: String) -> String {
        let voices = voiceCount
        return turns.map { "[\(MeetingFormat.clock($0.start))] \($0.label(meName: meName, voices: voices)) : \($0.text)" }.joined(separator: "\n")
    }

    /// The same lines with the labels in the app's language, for what the user copies.
    func displayText(meName: String) -> String {
        let voices = voiceCount
        return turns.map { "[\(MeetingFormat.clock($0.start))] \($0.displayLabel(meName: meName, voices: voices)): \($0.text)" }.joined(separator: "\n")
    }

    /// The lines of one stream transcribed in the cloud: times are moved from the voice-only audio that was sent back to
    /// the meeting's clock.
    mutating func insert(cloud segments: [CloudTranscript.Segment], speaker: MeetingSpeaker, map: MeetingSpeech.Compacted, startOffset: TimeInterval,
                         language: String? = nil) {
        for segment in segments {
            let start = startOffset + map.sourceTime(segment.start)
            let end = startOffset + map.sourceTime(segment.end)
            insert(segment.text, speaker: speaker, start: start, end: end, voice: segment.speaker, language: language)
        }
    }
}

enum MeetingFormat {
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// « 3 min », « 45 s ».
    static func remaining(_ seconds: TimeInterval) -> String {
        seconds >= 60 ? "\(Int((seconds / 60).rounded(.up))) min" : "\(max(5, Int(seconds))) s"
    }
}
