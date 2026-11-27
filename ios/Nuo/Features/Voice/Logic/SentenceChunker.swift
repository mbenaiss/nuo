import Foundation

/// Cuts streamed assistant text into speakable sentences as early as possible.
/// Code blocks and `::card` lines are dropped; inline markdown is stripped at emission.
struct Sentence: Equatable, Sendable {
    /// Caption shown on screen.
    var text: String
    /// What the synthesizer reads.
    var speech: String
}

struct SentenceChunker {
    var maxSentenceLength = 220
    var minSentenceLength = 4

    private enum LineMode { case undetermined, text, skip, fence }

    private var lineMode: LineMode = .undetermined
    private var linePrefix = ""
    private var inCodeBlock = false
    private var speech = ""
    private var carry = ""

    init() {}

    /// Appends a streamed delta and returns every sentence that became complete.
    mutating func append(_ delta: String) -> [Sentence] {
        for character in delta {
            if character == "\n" {
                endLine()
                continue
            }
            switch lineMode {
            case .undetermined:
                linePrefix.append(character)
                resolveLineMode(final: false)
            case .text:
                speech.append(character)
            case .skip, .fence:
                break
            }
        }
        return extractSentences(flush: false)
    }

    /// Flushes whatever is left once the message is complete.
    mutating func finish() -> [Sentence] {
        if lineMode == .undetermined, !linePrefix.isEmpty { resolveLineMode(final: true) }
        lineMode = .undetermined
        linePrefix = ""
        inCodeBlock = false
        return extractSentences(flush: true)
    }

    mutating func reset() {
        self = SentenceChunker()
    }

    private mutating func resolveLineMode(final: Bool) {
        let trimmed = linePrefix.drop(while: { $0 == " " || $0 == "\t" })
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
            lineMode = .fence
            return
        }
        if inCodeBlock {
            if final || trimmed.count >= 3 || !("```".hasPrefix(trimmed) || "~~~".hasPrefix(trimmed)) {
                lineMode = .skip
            }
            return
        }
        if trimmed.hasPrefix("::") {
            lineMode = .skip
            return
        }
        let mayBecomeSpecial = "```".hasPrefix(trimmed) || "~~~".hasPrefix(trimmed) || "::".hasPrefix(trimmed)
        if final || !mayBecomeSpecial {
            lineMode = .text
            speech.append(linePrefix)
        }
    }

    private mutating func endLine() {
        if lineMode == .undetermined, !linePrefix.isEmpty { resolveLineMode(final: true) }
        if lineMode == .fence { inCodeBlock.toggle() }
        if lineMode == .text { speech.append("\n") }
        lineMode = .undetermined
        linePrefix = ""
    }

    private mutating func extractSentences(flush: Bool) -> [Sentence] {
        var sentences: [Sentence] = []
        while let end = nextBoundary(in: speech) {
            let raw = String(speech[..<end])
            speech.removeSubrange(..<end)
            emit(raw, into: &sentences)
        }
        if speech.count > maxSentenceLength, let cut = softBreak(in: speech) {
            let raw = String(speech[..<cut])
            speech.removeSubrange(..<cut)
            emit(raw, into: &sentences)
        }
        if flush {
            emit(speech, into: &sentences, force: true)
            speech = ""
        }
        return sentences
    }

    private mutating func emit(_ raw: String, into sentences: inout [Sentence], force: Bool = false) {
        var clean = SpeechTextCleaner.displayable(raw)
        if !carry.isEmpty {
            clean = clean.isEmpty ? carry : carry + " " + clean
            carry = ""
        }
        guard !clean.isEmpty else { return }
        // Fragments without words ("12.", "4:35.") sound choppy alone: glue them to the next sentence.
        if !force, clean.count < minSentenceLength, !clean.contains(where: \.isLetter) {
            carry = clean
            return
        }
        sentences.append(Sentence(text: clean, speech: SpeechTextCleaner.speakable(clean)))
    }

    /// Index just past a sentence terminator that is followed by whitespace (so "4.35" or "M.Dupont" never split).
    private func nextBoundary(in text: String) -> String.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character == "\n" {
                if text[..<index].contains(where: { !$0.isWhitespace }) { return next }
            } else if ".!?…;".contains(character) {
                var end = next
                while end < text.endIndex, ".!?…»\")".contains(text[end]) { end = text.index(after: end) }
                guard end < text.endIndex else { return nil }
                if text[end].isWhitespace, !isAbbreviation(text[..<index]) {
                    return end
                }
                index = end
                continue
            }
            index = next
        }
        return nil
    }

    private func isAbbreviation(_ head: Substring) -> Bool {
        let word = head.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
        let known: Set<String> = ["M", "Mme", "Mlle", "Dr", "St", "Ste", "etc", "cf", "p", "ex", "env", "min", "max", "vs", "av", "apr", "J.-C", "n°"]
        if known.contains(word) { return true }
        return word.count == 1 && word.first?.isUppercase == true
    }

    private func softBreak(in text: String) -> String.Index? {
        let window = text.prefix(maxSentenceLength)
        if let comma = window.lastIndex(where: { ",:—–".contains($0) }), window.distance(from: window.startIndex, to: comma) > 40 {
            return text.index(after: comma)
        }
        return window.lastIndex(of: " ")
    }
}
