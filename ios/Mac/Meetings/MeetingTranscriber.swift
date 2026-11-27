import Foundation

/// Transcribes the two streams of a finished meeting on the Mac, when the gateway cannot: a chunk at a time, so a long
/// recording never sits in memory. Each chunk ends at a pause and keeps only its voiced parts; Whisper decodes it in the
/// language of the meeting with the names and the previous sentences as a prompt, Apple's recognizer in the language
/// chosen beforehand.
actor MeetingTranscriber {
    enum Engine: Sendable {
        case whisper
        case apple(Locale)
    }

    struct Stream: Sendable {
        let speaker: MeetingSpeaker
        let writer: MeetingStreamWriter
        var cursor = 0
    }

    /// The lines of one chunk and the cursors once it is read: kept together so the transcript and the place to resume
    /// from are always saved at the same point.
    struct Chunk: Sendable {
        var lines: [Line]
        var cursors: [Int]
    }

    struct Line: Sendable, Equatable {
        var speaker: MeetingSpeaker
        var start: TimeInterval
        var end: TimeInterval
        var text: String
    }

    private static let rate = Int(MeetingStreamWriter.sampleRate)
    /// Longest chunk; without any pause it ends at the quietest moment of its last 15 s.
    static let maximumChunk = 90 * rate
    private static let searchFrom = 15 * rate / MeetingSpeech.frame

    private var streams: [Stream]
    private var engine: Engine
    private let fixedLanguage: String?
    private let fallbackLanguage: String
    private let vocabulary: String
    private var context: [MeetingSpeaker: String] = [:]
    /// The language the meeting is held in, once known.
    private(set) var language: String?

    init(streams: [Stream], engine: Engine = .whisper, language: String?, fallbackLanguage: String, vocabulary: String) {
        self.streams = streams
        self.engine = engine
        self.fixedLanguage = language
        self.fallbackLanguage = fallbackLanguage
        self.vocabulary = vocabulary
        self.language = language
        if case let .apple(locale) = engine { self.language = locale.language.languageCode?.identifier }
    }

    /// The supported variant of the Apple locale, known once its model is installed.
    func useApple(_ locale: Locale) {
        engine = .apple(locale)
        language = locale.language.languageCode?.identifier
    }

    /// Recorded samples not transcribed yet, all streams together.
    var backlog: Int { pending.reduce(0, +) }

    private var pending: [Int] {
        streams.map { max(0, MeetingStreamReader.frameCount($0.writer.url) - $0.cursor) }
    }

    /// Samples already transcribed, per stream, in the order of `streams`.
    var cursors: [Int] { streams.map(\.cursor) }

    /// Transcribes the next chunk; nil once everything recorded is.
    /// Calls run one after the other: the actor is reentrant across the engine's await, and two calls would otherwise
    /// read the same chunk from the same cursor.
    func next() async throws -> Chunk? {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        let pending = self.pending
        // The stream furthest behind first, so both progress.
        for index in streams.indices.sorted(by: { pending[$0] > pending[$1] }) {
            guard let samples = try chunk(of: streams[index]) else { continue }
            let stream = streams[index]
            let lines = try await MeetingDeadline.run(seconds: MeetingDeadline.seconds(forSamples: samples.count, rate: Self.rate)) {
                try await self.transcribe(samples, stream: stream)
            }
            try Task.checkCancellation()
            streams[index].cursor += samples.count
            return Chunk(lines: lines, cursors: cursors)
        }
        return nil
    }

    private var running = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        guard running else {
            running = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty { running = false } else { waiting.removeFirst().resume() }
    }

    private func chunk(of stream: Stream) throws -> [Float]? {
        let available = MeetingStreamReader.frameCount(stream.writer.url) - stream.cursor
        guard available > 0 else { return nil }
        var samples = try MeetingStreamReader.read(stream.writer.url, from: stream.cursor, count: min(available, Self.maximumChunk))
        guard !samples.isEmpty else { return nil }
        if samples.count == available { return samples }
        let energy = MeetingSpeech.energy(samples)
        let threshold = MeetingSpeech.threshold(energy)
        if let cut = MeetingSpeech.cut(energy, threshold: threshold, after: Self.searchFrom) {
            samples = Array(samples.prefix(cut * MeetingSpeech.frame))
        } else if samples.count >= Self.maximumChunk {
            let quiet = MeetingSpeech.quietest(energy, in: energy.count - Self.searchFrom..<energy.count)
            samples = Array(samples.prefix(max(1, quiet) * MeetingSpeech.frame))
        } else {
            return nil
        }
        return samples
    }

    private func transcribe(_ samples: [Float], stream: Stream) async throws -> [Line] {
        let energy = MeetingSpeech.energy(samples)
        let regions = MeetingSpeech.regions(energy, threshold: MeetingSpeech.threshold(energy))
        // Less than a second of voice: a cough, a click, a door.
        guard regions.reduce(0, { $0 + $1.count }) >= 10 else { return [] }
        let compacted = MeetingSpeech.compact(samples, regions: regions)
        let audio = MeetingSpeech.normalized(compacted.samples)
        var prompt = ""
        let segments: [WhisperPass.Segment]
        switch engine {
        case .whisper:
            let language = await language(of: audio)
            prompt = self.prompt(for: stream.speaker)
            segments = try await WhisperEngine.shared.transcribe(audio, language: language, prompt: prompt).segments
        case let .apple(locale):
            segments = try await AppleFileTranscriber.transcribe(audio, locale: locale)
        }
        let base = (stream.writer.startOffset ?? 0) + Double(stream.cursor) / Double(Self.rate)
        var lines: [Line] = []
        for segment in segments {
            let text = WhisperText.clean(WhisperText.withoutSoundTags(segment.text))
            guard !text.isEmpty, !Self.repeats(text, of: prompt) else { continue }
            let start = base + compacted.sourceTime(segment.start)
            let end = base + compacted.sourceTime(segment.end ?? segment.start + 2)
            lines.append(Line(speaker: stream.speaker, start: start, end: max(end, start), text: text))
        }
        if !lines.isEmpty {
            context[stream.speaker] = String(((context[stream.speaker] ?? "") + " " + lines.map(\.text).joined(separator: " ")).suffix(400))
        }
        return lines
    }

    /// Detected once, on the first chunk with enough voice. A chunk clearly in another language (a meeting switching
    /// to English) is transcribed in that one: forcing the wrong language makes Whisper translate.
    private func language(of audio: [Float]) async -> String {
        if let fixedLanguage { return fixedLanguage }
        guard audio.count >= 5 * Self.rate, let guess = await WhisperEngine.shared.guessLanguage(audio) else {
            return language ?? fallbackLanguage
        }
        guard let current = language else {
            language = guess.probability > 0.5 ? guess.language : fallbackLanguage
            return language ?? fallbackLanguage
        }
        return guess.language != current && guess.probability > 0.85 ? guess.language : current
    }

    /// The names (spelling of proper nouns) and the speaker's last sentences (continuity across chunks).
    private func prompt(for speaker: MeetingSpeaker) -> String {
        [vocabulary, String((context[speaker] ?? "").suffix(240))]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Whisper sometimes reads its prompt back on a chunk with little voice. A short reply (« oui, d'accord ») may
    /// really be said twice, so only a longer sentence counts.
    static func repeats(_ text: String, of prompt: String) -> Bool {
        func fold(_ value: String) -> String {
            String(value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .map { $0.isLetter || $0.isNumber ? $0 : " " })
                .split(separator: " ")
                .joined(separator: " ")
        }
        let folded = fold(text)
        return folded.split(separator: " ").count >= 4 && fold(prompt).contains(folded)
    }
}
