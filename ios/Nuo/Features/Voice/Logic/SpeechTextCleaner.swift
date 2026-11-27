import Foundation

/// Turns a markdown fragment into plain text a speech synthesizer can read aloud.
/// Line-level structures (code fences, `::card` lines) are filtered upstream by `SentenceChunker`.
enum SpeechTextCleaner {
    /// What the synthesizer reads: the caption plus symbols rewritten as words.
    static func speakable(_ markdown: String) -> String {
        var text = displayable(markdown)
        text = text.replacing(/\s*(→|->|=>)\s*/, with: ", ")
        text = text.replacing(/(\d)\s*[×x]\s*(\d)/) { String(localized: "\(String($0.output.1)) times \(String($0.output.2))") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Plain caption text: markdown, links and emoji removed, typography kept.
    static func displayable(_ markdown: String) -> String {
        var text = markdown

        text = text.replacing(/!\[[^\]]*\]\([^)]*\)/, with: "")
        text = text.replacing(/\[([^\]]+)\]\([^)]*\)/) { String($0.output.1) }
        text = text.replacing(/https?:\/\/\S+/, with: "")
        text = text.replacing(/`([^`]*)`/) { String($0.output.1) }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { cleanLine(String($0)) }
        text = lines.filter { !$0.isEmpty }.joined(separator: " ")

        text = text.replacing("**", with: "")
            .replacing("__", with: "")
            .replacing("~~", with: "")
            .replacing("*", with: "")
            .replacing("`", with: "")
        text = text.replacing(/(^|[^\p{L}\p{N}])_([^_]+)_(?![\p{L}\p{N}])/) { "\($0.output.1)\($0.output.2)" }

        text = removeEmoji(text)
        text = text.replacing(/\s+/, with: " ")
        text = text.replacing(/\s+([,.…])/) { String($0.output.1) }
        text = text.replacing(/^[\s,;:.]+/, with: "")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanLine(_ raw: String) -> String {
        var line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { return "" }
        if line.wholeMatch(of: /\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?/) != nil { return "" }
        if line.wholeMatch(of: /[-*_=]{3,}/) != nil { return "" }
        line = line.replacing(/^#{1,6}\s*/, with: "")
        line = line.replacing(/^>\s*/, with: "")
        line = line.replacing(/^[-*+•]\s+(\[[ xX]\]\s+)?/, with: "")
        line = line.replacing(/^\d{1,2}[.)]\s+/, with: "")
        if line.contains("|") {
            line = line.split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        }
        return line
    }

    private static func removeEmoji(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let props = scalar.properties
            let isPictographic = props.isEmojiPresentation || (props.isEmoji && scalar.value > 0x238C)
            let isJoiner = scalar.value == 0x200D || scalar.value == 0xFE0F || (0x1F3FB...0x1F3FF).contains(scalar.value)
            if isPictographic || isJoiner { continue }
            scalars.append(scalar)
        }
        return String(scalars)
    }
}
