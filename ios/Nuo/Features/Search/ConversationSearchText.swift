import Foundation

/// Matching as the gateway's full-text index does it: every word of the query, without case or accents.
enum ConversationSearchText {
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
    }

    static func terms(_ query: String) -> [String] {
        fold(query).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static func matches(_ text: String, _ terms: [String]) -> Bool {
        let folded = fold(text)
        return !terms.isEmpty && terms.allSatisfy { folded.contains($0) }
    }

    /// The text around the first word found, on one line.
    static func excerpt(_ text: String, around terms: [String], radius: Int = 60) -> String {
        let line = oneLine(text)
        let folded = fold(line)
        guard let found = terms.compactMap({ folded.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) else {
            return line.count > radius * 2 ? String(line.prefix(radius * 2)) + "…" : line
        }
        let offset = folded.distance(from: folded.startIndex, to: found.lowerBound)
        let start = max(0, offset - radius)
        let end = min(line.count, offset + radius)
        let slice = line.dropFirst(start).prefix(end - start)
        return (start > 0 ? "…" : "") + slice.trimmingCharacters(in: .whitespaces) + (end < line.count ? "…" : "")
    }

    /// A snippet or a message as one line of a result list.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
