import Foundation

/// Bounded slices of a long text, so a message of hundreds of thousands of characters only lays out what is shown.
/// Lines are found on the UTF-8 view: a newline byte is always a scalar boundary and counting it never decodes the text.
enum TextExcerpt {
    struct Lines: Equatable {
        let text: Substring
        /// Lines of the full text left out of `text`.
        let hidden: Int
    }

    private static let newline = UInt8(ascii: "\n")

    static func lineCount<S: StringProtocol>(_ text: S) -> Int {
        text.utf8.reduce(1) { $1 == newline ? $0 + 1 : $0 }
    }

    /// The last `count` lines.
    static func lastLines(_ text: String, _ count: Int) -> Lines {
        let utf8 = text.utf8
        var index = utf8.endIndex
        var seen = 0
        while index > utf8.startIndex {
            let previous = utf8.index(before: index)
            if utf8[previous] == newline {
                seen += 1
                if seen == count { return Lines(text: text[index...], hidden: lineCount(text[..<previous])) }
            }
            index = previous
        }
        return Lines(text: text[...], hidden: 0)
    }

    /// The first `count` lines.
    static func firstLines(_ text: String, _ count: Int) -> Lines {
        let utf8 = text.utf8
        var seen = 0
        var index = utf8.startIndex
        while index < utf8.endIndex {
            if utf8[index] == newline {
                seen += 1
                if seen == count { return Lines(text: text[..<index], hidden: lineCount(text[utf8.index(after: index)...])) }
            }
            index = utf8.index(after: index)
        }
        return Lines(text: text[...], hidden: 0)
    }

    /// The start of a text longer than `maxCharacters` or `maxLines`, cut at the end of a line when one is close; nil
    /// when the whole text fits.
    static func preview(_ text: String, maxCharacters: Int, maxLines: Int) -> Substring? {
        let limit = text.index(text.startIndex, offsetBy: maxCharacters, limitedBy: text.endIndex) ?? text.endIndex
        let utf8 = text.utf8
        var lines = 1
        var lastBreak: String.Index?
        var index = utf8.startIndex
        while index < limit {
            if utf8[index] == newline {
                lines += 1
                if lines > maxLines { return text[..<index] }
                lastBreak = index
            }
            index = utf8.index(after: index)
        }
        guard limit < text.endIndex else { return nil }
        if let lastBreak, text.distance(from: lastBreak, to: limit) < maxCharacters / 4 { return text[..<lastBreak] }
        return text[..<limit]
    }

    /// The text in pieces of at most `maxCharacters`, split at line ends; a longer line is cut where it reaches the size.
    static func chunks(_ text: String, maxCharacters: Int) -> [Substring] {
        var result: [Substring] = []
        var start: String.Index?
        var end = text.startIndex
        var size = 0
        func flush() {
            if let start { result.append(text[start..<end]) }
            start = nil
            size = 0
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var rest = line
            var cutLine = false
            while let cut = rest.index(rest.startIndex, offsetBy: maxCharacters, limitedBy: rest.endIndex), cut < rest.endIndex {
                flush()
                result.append(rest[..<cut])
                rest = rest[cut...]
                cutLine = true
            }
            if cutLine && rest.isEmpty { continue }
            let length = rest.count
            if start != nil, size + 1 + length > maxCharacters { flush() }
            if start == nil {
                start = rest.startIndex
                size = length
            } else {
                size += 1 + length
            }
            end = rest.endIndex
        }
        flush()
        return result
    }
}
