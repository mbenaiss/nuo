import Foundation

/// A line of a recording's transcript, with the voice the gateway heard (« 1 », « 2 »… in order of appearance).
struct RecordingLine: Codable, Hashable, Sendable, Identifiable {
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var speaker: String?

    var id: String { "\(start)-\(speaker ?? "")" }

    static func from(_ segments: [CloudTranscript.Segment], language: String?) -> [RecordingLine] {
        segments
            .map { RecordingLine(start: $0.start, end: max($0.end, $0.start), text: Disfluency.strip($0.text, language: language), speaker: $0.speaker) }
            .filter { !$0.text.isEmpty }
            .sorted { $0.start < $1.start }
    }

    /// « Voix 1 », or the name the user gave that voice.
    func label(names: [String: String]) -> String {
        guard let speaker else { return "Voix" }
        return names[speaker].flatMap { $0.isEmpty ? nil : $0 } ?? "Voix \(speaker)"
    }

    /// The label shown in the app; `label(names:)` stays French because it is written into the bot prompt and the note.
    func displayLabel(names: [String: String]) -> String {
        guard let speaker else { return String(localized: "Voice") }
        return names[speaker].flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Voice \(speaker)")
    }
}

/// Consecutive lines of one voice, shown as one paragraph.
struct RecordingTurn: Hashable, Sendable, Identifiable {
    var start: TimeInterval
    var end: TimeInterval
    var speaker: String?
    var text: String

    var id: TimeInterval { start }

    static let gap: TimeInterval = 20

    static func group(_ lines: [RecordingLine]) -> [RecordingTurn] {
        var turns: [RecordingTurn] = []
        for line in lines {
            if let last = turns.last, last.speaker == line.speaker, line.start - last.end < gap {
                turns[turns.count - 1].text += " " + line.text
                turns[turns.count - 1].end = max(last.end, line.end)
            } else {
                turns.append(RecordingTurn(start: line.start, end: line.end, speaker: line.speaker, text: line.text))
            }
        }
        return turns
    }
}

/// What was being said when a marker was set.
struct MarkerQuote: Hashable, Sendable, Identifiable {
    var marker: RecordingMarker
    var line: RecordingLine?

    var id: String { marker.id }

    /// People tap a moment or so after the words that struck them: within the first seconds of a line, the line before
    /// it (if it ended just before) is the one meant; in a silence, the line that just ended, else the one about to start.
    static func align(_ markers: [RecordingMarker], to lines: [RecordingLine]) -> [MarkerQuote] {
        let sorted = lines.sorted { $0.start < $1.start }
        return markers.sorted { $0.offset < $1.offset }.map { marker in
            MarkerQuote(marker: marker, line: line(at: marker.offset, in: sorted))
        }
    }

    static let reaction: TimeInterval = 2
    static let lookBack: TimeInterval = 10
    static let lookAhead: TimeInterval = 3

    private static func line(at t: TimeInterval, in lines: [RecordingLine]) -> RecordingLine? {
        let previous = lines.last { $0.end <= t }
        if let current = lines.last(where: { $0.start <= t && t <= $0.end }) {
            if t - current.start < reaction, let previous, previous != current, t - previous.end <= reaction + 1 { return previous }
            return current
        }
        if let previous, t - previous.end <= lookBack { return previous }
        if let next = lines.first(where: { $0.start > t }), next.start - t <= lookAhead { return next }
        return nil
    }
}

/// The note of a watch recording: built by the same rules as a Mac meeting note, with the moments flagged on the watch.
enum RecordingNotePrompt {
    static func transcriptText(_ lines: [RecordingLine], names: [String: String]) -> String {
        RecordingTurn.group(lines).map { turn in
            let line = RecordingLine(start: turn.start, end: turn.end, text: turn.text, speaker: turn.speaker)
            return "[\(NoteFormat.clock(turn.start))] \(line.label(names: names)) : \(turn.text)"
        }.joined(separator: "\n")
    }

    static func momentsText(_ quotes: [MarkerQuote], names: [String: String]) -> String {
        guard !quotes.isEmpty else { return "(aucun)" }
        return quotes.enumerated().map { index, quote in
            let said = quote.line.map { "\($0.label(names: names)) : « \($0.text) »" } ?? "(silence)"
            return "\(index + 1). [\(NoteFormat.clock(quote.marker.offset))] \(said)"
        }.joined(separator: "\n")
    }

    static func build(title: String, startedAt: Date, duration: TimeInterval, lines: [RecordingLine], markers: [RecordingMarker],
                      template: MeetingTemplate, userName: String, names: [String: String] = [:]) -> String {
        let me = userName.trimmingCharacters(in: .whitespaces).isEmpty ? "moi" : userName
        let voices = Set(lines.compactMap(\.speaker)).count
        var structure = NotePrompt.standardStructure(heading: "Titre")
        let moments = [
            "## Moments clés",
            "(un point par repère, dans l'ordre : `- **[mm:ss]** « la phrase dite à ce moment-là, corrigée » — pourquoi c'est important en une phrase` ; « Aucun » sans repère)",
        ]
        structure.insert(contentsOf: moments, at: 4)
        return NotePrompt.compose(
            request: "Rédige le compte rendu de l'enregistrement que je viens de faire avec ma montre, à partir de sa transcription et des moments que j'ai marqués pendant l'enregistrement.",
            kindLabel: "Type d'enregistrement",
            template: template,
            header: [
                "Titre prévu : \(title.isEmpty ? "(à déduire de la conversation)" : "voir <titre>")",
                "Date : \(NoteFormat.longDate(startedAt)) · durée \(max(1, Int((duration / 60).rounded()))) min",
                "Voix entendues : \(voices == 0 ? "inconnu" : String(voices))",
            ],
            rules: [
                NotePrompt.answerRule,
                NotePrompt.recognitionRule(speakers: "Les intervenants sont numérotés « Voix 1 », « Voix 2 »… dans l'ordre où ils parlent. J'en fais partie (\(me)) : quand le contexte permet de savoir qui est qui, utilise les noms ; sinon garde « Voix N »."),
                "Les moments marqués sont ceux que j'ai jugés importants pendant l'enregistrement : chacun figure dans « Moments clés » avec son heure et la phrase dite, et ce qu'il contient se retrouve aussi dans le résumé, les décisions ou les actions.",
                NotePrompt.noInventionRule,
                NotePrompt.dataRule(tags: ["titre", "moments_marques", "transcription"]),
            ],
            structure: structure,
            blocks: [
                .init(tag: "titre", content: title.isEmpty ? "(aucun)" : title),
                .init(tag: "moments_marques", content: momentsText(MarkerQuote.align(markers, to: lines), names: names)),
                .init(tag: "transcription", content: transcriptText(lines, names: names)),
            ])
    }

    /// The document saved in the gateway's docs (`reunions/`), where the Mac lists its meetings: the note, then the
    /// moments and the transcript, so it reads on its own.
    static func document(note: String, lines: [RecordingLine], markers: [RecordingMarker], names: [String: String]) -> String {
        var parts = [note.trimmingCharacters(in: .whitespacesAndNewlines)]
        if !note.contains("## Moments clés"), !markers.isEmpty {
            let quotes = MarkerQuote.align(markers, to: lines)
            parts.append("## Moments clés\n" + quotes.map { quote in
                "- **[\(NoteFormat.clock(quote.marker.offset))]** " + (quote.line.map { "« \($0.text) »" } ?? "(silence)")
            }.joined(separator: "\n"))
        }
        if !lines.isEmpty {
            parts.append("## Transcription\n" + RecordingTurn.group(lines).map { turn in
                let line = RecordingLine(start: turn.start, end: turn.end, text: turn.text, speaker: turn.speaker)
                return "**[\(NoteFormat.clock(turn.start))] \(line.label(names: names))** : \(turn.text)"
            }.joined(separator: "\n\n"))
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    /// `reunions/YYYY-MM-DD-<slug>.md`, from the note's title.
    static func documentBase(note: String, fallbackTitle: String, startedAt: Date) -> String {
        let heading = note.components(separatedBy: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) }
        return "reunions/\(NoteFormat.day(startedAt))-\(NoteFormat.slug(heading ?? (fallbackTitle.isEmpty ? "enregistrement" : fallbackTitle)))"
    }

    /// The first message of « Demander à un bot »: the note and the transcript as context, then room for the question.
    static func askContext(title: String, startedAt: Date, note: String?, lines: [RecordingLine], names: [String: String]) -> String {
        var text = "Voici l'enregistrement du \(NoteFormat.longDate(startedAt)) dont le titre est dans <titre>. Lis le compte rendu et la transcription, réponds seulement « Prêt » puis attends mes questions. "
            + NotePrompt.dataRule(tags: ["titre", "compte_rendu", "transcription"])
        text += "\n\n<titre>\n\(title)\n</titre>"
        if let note, !note.isEmpty { text += "\n\n<compte_rendu>\n\(note)\n</compte_rendu>" }
        text += "\n\n<transcription>\n\(transcriptText(lines, names: names))\n</transcription>"
        return text
    }
}

extension RecordingNotePrompt {
    /// « Voix 2 » becomes the name the user gave that voice, in the note too; « Voix 12 » is left alone.
    static func renaming(_ note: String, voice: String, to name: String) -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let pattern = try? Regex("Voix \(NSRegularExpression.escapedPattern(for: voice))(?![0-9])") else { return note }
        return note.replacing(pattern, with: clean)
    }

    /// A name given before becomes the new one, as a whole word only: « Marc » → « Marco » leaves « Marcel » alone.
    static func replacingName(_ note: String, from old: String, to new: String) -> String {
        let from = old.trimmingCharacters(in: .whitespacesAndNewlines), to = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !from.isEmpty, !to.isEmpty, from != to,
              let pattern = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])\(NSRegularExpression.escapedPattern(for: from))(?![\\p{L}\\p{N}])")
        else { return note }
        return pattern.stringByReplacingMatches(in: note, range: NSRange(note.startIndex..., in: note),
                                                withTemplate: NSRegularExpression.escapedTemplate(for: to))
    }
}

/// The bot that writes the notes. It reads other people's words, so it is never picked by default among the bots
/// that reach every other bot or run any tool unasked. By default the bot made for it (slug `comptes-rendus`, without
/// any tool), else another bot without any tool, else none; the user's choice comes first.
enum NoteBotChoice {
    static let dedicatedSlug = "comptes-rendus"

    static func isEligible(_ bot: Bot) -> Bool {
        bot.published != nil && bot.config?.overview != true && bot.config?.permissionPolicy != .auto
    }

    private static func isCobot(_ bot: Bot) -> Bool {
        bot.slug == "cobot" || bot.id == "cobot" || bot.config?.name.lowercased() == "cobot"
    }

    /// The default when the user chose nothing (or a bot that is gone): among the bots without any tool, the dedicated
    /// one first; none, and the note waits for the user's choice. Read only is not enough, nor the dedicated slug alone:
    /// such a bot still reads files and uses the gateway's own tools.
    static func defaultBot(in bots: [Bot]) -> Bot? {
        let toolless = bots.filter { isEligible($0) && $0.config?.noTools == true }
        return toolless.first { $0.slug == dedicatedSlug } ?? toolless.first { !isCobot($0) }
    }

    static func pick(bots: [Bot], chosenId: String?) -> Bot? {
        if let chosenId, let chosen = bots.filter(isEligible).first(where: { $0.id == chosenId }) { return chosen }
        return defaultBot(in: bots)
    }
}

/// How a recording reaches the gateway, which takes 64 MB in one upload. Up to 2 h 50 the AAC at 48 kbit/s goes as
/// it is; up to 5 h 40 it is encoded again at 24 kbit/s, still clear for the recognition, to stay one job (one
/// numbering of the voices). Beyond, parts of 5 h 40 at most, overlapping by two minutes: the voices heard in the
/// overlap tie the numbering of a part to the one before, and the parts are joined in a silence of that window.
enum RecordingParts {
    static let directSeconds: TimeInterval = 2 * 3600 + 50 * 60
    static let singleJobSeconds: TimeInterval = 5 * 3600 + 40 * 60
    static let overlap: TimeInterval = 120

    struct Part: Equatable, Sendable {
        var index: Int
        var start: TimeInterval
        var duration: TimeInterval
    }

    struct Plan: Equatable, Sendable {
        var bitRate: Int
        var parts: [Part]
        /// The audio as assembled goes up untouched.
        var isDirect: Bool { bitRate == 48_000 && parts.count == 1 }
    }

    static func plan(duration: TimeInterval) -> Plan {
        if duration <= directSeconds { return Plan(bitRate: 48_000, parts: [Part(index: 0, start: 0, duration: duration)]) }
        return Plan(bitRate: 24_000, parts: parts(duration: duration, maxSeconds: singleJobSeconds, overlap: overlap))
    }

    /// Parts of `maxSeconds` at most, each starting `overlap` before the end of the previous one.
    static func parts(duration: TimeInterval, maxSeconds: TimeInterval, overlap: TimeInterval = 0) -> [Part] {
        guard duration > maxSeconds else { return [Part(index: 0, start: 0, duration: duration)] }
        let count = Int(((duration - overlap) / (maxSeconds - overlap)).rounded(.up))
        let step = (duration - overlap) / Double(count)
        return (0..<count).map { index in
            let start = Double(index) * step
            return Part(index: index, start: start, duration: index == count - 1 ? duration - start : step + overlap)
        }
    }

    /// The job of a part: the recording's own id for the first part of the first pass, so recordings sent before
    /// parts existed are found again; a stable variation of it otherwise.
    static func jobId(recordingId: String, part: Int, generation: Int = 0) -> String {
        guard part > 0 || generation > 0, let uuid = UUID(uuidString: recordingId) else { return recordingId.lowercased() }
        var bytes = uuid.uuid
        bytes.14 ^= UInt8(truncatingIfNeeded: generation)
        bytes.15 ^= UInt8(truncatingIfNeeded: part &+ 1)
        return UUID(uuid: bytes).uuidString.lowercased()
    }

    /// The lines of one part, on the recording's clock.
    static func shift(_ lines: [RecordingLine], by offset: TimeInterval) -> [RecordingLine] {
        lines.map { RecordingLine(start: $0.start + offset, end: $0.end + offset, text: $0.text, speaker: $0.speaker) }
    }

    /// The new part's voices as numbered so far: pairs that spoke together longest in the window first, a pair only
    /// when it shares at least 3 s and half of the new voice's speech there; a voice without a match gets a number
    /// never used before.
    static func matchVoices(before: [RecordingLine], after: [RecordingLine], window: ClosedRange<TimeInterval>, existing: Set<String>) -> [String: String] {
        func clipped(_ line: RecordingLine) -> ClosedRange<TimeInterval>? {
            let start = max(line.start, window.lowerBound), end = min(line.end, window.upperBound)
            return start < end ? start...end : nil
        }
        var talk: [String: TimeInterval] = [:]
        for line in after { if let speaker = line.speaker, let range = clipped(line) { talk[speaker, default: 0] += range.upperBound - range.lowerBound } }
        var shared: [String: [String: TimeInterval]] = [:]
        for new in after {
            guard let newSpeaker = new.speaker, let a = clipped(new) else { continue }
            for old in before {
                guard let oldSpeaker = old.speaker, let b = clipped(old) else { continue }
                let common = min(a.upperBound, b.upperBound) - max(a.lowerBound, b.lowerBound)
                if common > 0 { shared[newSpeaker, default: [:]][oldSpeaker, default: 0] += common }
            }
        }
        let pairs = shared.flatMap { new, olds in olds.map { (new: new, old: $0.key, seconds: $0.value) } }
            .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : ($0.new, $0.old) < ($1.new, $1.old) }
        var names: [String: String] = [:]
        var taken: Set<String> = []
        for pair in pairs where names[pair.new] == nil && !taken.contains(pair.old) {
            guard pair.seconds >= 3, pair.seconds >= 0.5 * (talk[pair.new] ?? 0) else { continue }
            names[pair.new] = pair.old
            taken.insert(pair.old)
        }
        var next = (existing.compactMap(Int.init).max() ?? 0) + 1
        for speaker in Set(after.compactMap(\.speaker)).sorted(by: { (Int($0) ?? 0, $0) < (Int($1) ?? 0, $1) }) where names[speaker] == nil {
            while existing.contains(String(next)) { next += 1 }
            names[speaker] = String(next)
            next += 1
        }
        return names
    }

    /// The earlier lines up to a silence of the window, the new part's from there, its voices renumbered.
    static func join(before: [RecordingLine], after: [RecordingLine], window: ClosedRange<TimeInterval>, existing: Set<String>) -> [RecordingLine] {
        let names = matchVoices(before: before, after: after, window: window, existing: existing)
        let renamed = after.map { RecordingLine(start: $0.start, end: $0.end, text: $0.text, speaker: $0.speaker.flatMap { names[$0] }) }
        let cut = silence(in: window, lines: before + renamed)
        return (before.filter { $0.start < cut } + renamed.filter { $0.start >= cut }).sorted { $0.start < $1.start }
    }

    /// The middle of the longest stretch of the window where nobody speaks in either part.
    static func silence(in window: ClosedRange<TimeInterval>, lines: [RecordingLine]) -> TimeInterval {
        let spans = lines.compactMap { line -> (TimeInterval, TimeInterval)? in
            let start = max(line.start, window.lowerBound), end = min(line.end, window.upperBound)
            return start < end ? (start, end) : nil
        }.sorted { $0.0 < $1.0 }
        var best = (length: -1.0, middle: (window.lowerBound + window.upperBound) / 2)
        var cursor = window.lowerBound
        for (start, end) in spans + [(window.upperBound, window.upperBound)] {
            if start > cursor, start - cursor > best.length { best = (start - cursor, (start + cursor) / 2) }
            cursor = max(cursor, end)
        }
        return best.middle
    }

    /// All parts on one clock and one numbering of the voices.
    static func merge(_ parts: [Int: [RecordingLine]], plan: [Part]) -> [RecordingLine] {
        var joined: [RecordingLine] = []
        for part in plan {
            guard let lines = parts[part.index] else { continue }
            if joined.isEmpty || part.index == 0 {
                joined = lines.sorted { $0.start < $1.start }
                continue
            }
            let window = part.start...(part.start + overlap)
            joined = join(before: joined, after: lines, window: window, existing: Set(joined.compactMap(\.speaker)))
        }
        return joined
    }
}

/// Stretches of a recording filled with silence (pieces that never came or could not be read): what the recognition
/// may hear there is not what was said.
enum SilenceGaps {
    static func drop(_ lines: [RecordingLine], in gaps: [ClosedRange<TimeInterval>]) -> [RecordingLine] {
        lines.filter { line in !gaps.contains { $0.contains(line.start) } }
    }
}
