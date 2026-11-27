import SwiftUI

/// `#id` tags of machine tools in a composer text.
/// The composer asks on every keystroke and a pasted text can be hundreds of thousands of characters long: each lookup
/// reads only what it needs instead of running a regex over the whole text.
enum ToolTag {
    /// Text after a trailing `#` that starts the text or follows a space, while the tag is being typed.
    static func query(in text: String) -> String? {
        let scalars = text.unicodeScalars
        var index = scalars.endIndex
        while index > scalars.startIndex {
            let previous = scalars.index(before: index)
            let scalar = scalars[previous]
            if scalar == "#" {
                guard previous == scalars.startIndex || scalars[scalars.index(before: previous)].properties.isWhitespace else { return nil }
                return String(scalars[index...]).lowercased()
            }
            guard isTagScalar(scalar, uppercase: true) else { return nil }
            index = previous
        }
        return nil
    }

    /// Replaces the tag being typed by `#id `.
    static func insert(_ tool: MachineTool, into text: String) -> String {
        guard let query = query(in: text) else { return text + "#\(tool.id) " }
        return String(text.dropLast(query.count + 1)) + "#\(tool.id) "
    }

    struct Parsed {
        var leading: [String]
        var rest: String
    }

    /// Splits the tags that open the message (shown as chips) from the remaining text.
    static func parse(_ text: String, known: Set<String>) -> Parsed? {
        guard !known.isEmpty, text.contains("#") else { return nil }
        var leading: [String] = []
        var rest = Substring(text)
        while let match = rest.prefixMatch(of: /#([a-z0-9_\-]+)(?:\s+|$)/), known.contains(String(match.1)) {
            leading.append(String(match.1))
            rest = rest[match.range.upperBound...]
        }
        let parsed = Parsed(leading: leading, rest: String(rest))
        if leading.isEmpty, !inlineTags(in: parsed.rest, known: known) { return nil }
        return parsed
    }

    static func inlineTags(in text: String, known: Set<String>) -> Bool {
        tags(in: text).contains { known.contains($0.id) }
    }

    static func styled(_ text: String, known: Set<String>) -> AttributedString {
        var result = AttributedString(text)
        for tag in tags(in: text) where known.contains(tag.id) {
            guard let lower = AttributedString.Index(tag.range.lowerBound, within: result),
                  let upper = AttributedString.Index(tag.range.upperBound, within: result) else { continue }
            result[lower..<upper].font = .body.monospaced().weight(.semibold)
            result[lower..<upper].backgroundColor = .white.opacity(0.16)
        }
        return result
    }

    /// Every `#id` that starts the text or follows a space, with the range of `#id`.
    static func tags(in text: String) -> [(id: String, range: Range<String.Index>)] {
        let scalars = text.unicodeScalars
        var found: [(id: String, range: Range<String.Index>)] = []
        var index = scalars.startIndex
        var afterSpace = true
        while index < scalars.endIndex {
            let scalar = scalars[index]
            guard scalar == "#", afterSpace else {
                afterSpace = scalar.properties.isWhitespace
                index = scalars.index(after: index)
                continue
            }
            let start = scalars.index(after: index)
            var end = start
            while end < scalars.endIndex, isTagScalar(scalars[end], uppercase: false) { end = scalars.index(after: end) }
            if end > start { found.append((String(scalars[start..<end]), index..<end)) }
            afterSpace = false
            index = end > start ? end : start
        }
        return found
    }

    private static func isTagScalar(_ scalar: Unicode.Scalar, uppercase: Bool) -> Bool {
        switch scalar {
        case "a"..."z", "0"..."9", "_", "-": true
        case "A"..."Z": uppercase
        default: false
        }
    }
}
