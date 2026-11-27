import Foundation

/// Removes hesitations (« euh », « heu », « hum », « hmm », « mmh », « um », « uh ») left in a transcript, whatever
/// engine wrote it. Only whole words go: « Heure », « Hummus », « 5 mm », « 5 um », « UM », « hum-hum », « a hum in the
/// engine », « « euh » », an e-mail address or a link stay, and « um », « uh », « erm » only go in French or English
/// (« um 9 Uhr », « um café »). The punctuation the hesitation brought goes with it, and a sentence it opened starts on a
/// capital again. One pass over the text.
enum Disfluency {
    /// « mm » alone is millimetres: a hum needs three m or an h.
    /// « um » and « hm » right after a number are micrometres and hectometres: never taken, even in a run (« 5 um, euh »).
    /// Longer ones (« 12 hmm ») are hesitations wherever they are.
    private static let fillers = #"e+u+h+m*|h+e+u+h*|h+u+m+|(?<!\p{N}[ \t\x{00A0}\x{202F}]{0,2})(?:hm|um)|h{2,}m+|h+m{2,}|u{2,}m+|u+m{2,}|m+h+|m{3,}h*|u+h+m*|e+r+m+"#
    /// A clause ending on a number, or a number and its unit (« 9 h », « 4 200 € », « 5 um »): a list goes on after it.
    private static let endsOnNumber = try! NSRegularExpression(
        pattern: #"\p{N}(?:[ \x{00A0}\x{202F}]?([\p{L}µ°]+|[€$£%]))?$"#)
    /// After a number, these are no unit: « le 12 à, euh, 14 h » loses its comma.
    private static let functionWords: Set<String> = [
        "à", "de", "du", "des", "en", "pour", "vers", "sur", "et", "ou", "au", "aux",
        "to", "for", "at", "of", "in", "on", "and", "or",
    ]
    private static let space = "[ \\t\u{00A0}\u{202F}]"
    /// Not inside a word, an address (`um@`, `euh.txt`) or a link (`?x=euh&y`).
    private static let filler = #"(?<![\p{L}\p{N}'’\-@_./\\=&#%+?])(?:"# + fillers + #")(?![\p{L}\p{N}'’\-@_/\\=&#%+])(?!\.\p{L})"#
    /// Hesitations in a row (« euh, hum, ») go as one.
    private static let pattern = try! NSRegularExpression(
        pattern: "(" + filler + "(?:" + space + "*(?:,|;|\\.\\.\\.|…)?" + space + "*" + filler + ")*)"
            + "((?:" + space + "*(?:\\.\\.\\.|…|[.!?,;]))*)",
        options: [.caseInsensitive])
    /// « hum » is also a word (« a hum in the engine », « hum the tune »): only taken out when punctuation sets it apart.
    private static let hum = try! NSRegularExpression(pattern: #"^h+u+m+$"#, options: [.caseInsensitive])
    /// Words in other languages too (German « um », Portuguese « um »).
    private static let english = try! NSRegularExpression(pattern: #"^(?:u+h+m*|u+m+|e+r+m+)$"#, options: [.caseInsensitive])
    private static let blanks = CharacterSet(charactersIn: " \t\u{00A0}\u{202F}")
    /// A comma after one of these was the speaker's own (« Oui, euh, non »), not one framing the hesitation.
    private static let interjections: Set<String> = [
        "oui", "non", "si", "bon", "bah", "ben", "alors", "donc", "bref", "enfin", "voilà", "voila", "ok", "okay", "d'accord",
        "bonjour", "bonsoir", "salut", "merci", "yes", "no", "so", "well", "hello", "hi", "thanks",
    ]

    /// `language` (ISO 639-1) is the language the text was heard in; without it « um », « uh » and « erm » stay.
    static func strip(_ text: String, language: String? = nil) -> String {
        let removesEnglish = language == "fr" || language == "en"
        let source = text as NSString
        let length = source.length
        var output = ""
        /// Where the text not copied yet starts, in UTF-16 units of `text`.
        var cursor = 0
        /// The next letter copied opens a sentence a hesitation started.
        var capitalize = false

        func character(at offset: Int) -> Character? {
            guard offset < length else { return nil }
            return Character(source.substring(with: source.rangeOfComposedCharacterSequence(at: offset)))
        }
        func isBlank(_ c: Character?) -> Bool { c.map { $0.unicodeScalars.allSatisfy { blanks.contains($0) } } ?? false }
        func skip(from offset: Int, newlines: Bool = false) -> Int {
            var at = offset
            while let c = character(at: at), isBlank(c) || newlines && c.isNewline { at += c.utf16.count }
            return at
        }
        func copy(upTo end: Int) {
            guard end > cursor else { return }
            var piece = source.substring(with: NSRange(location: cursor, length: end - cursor))
            cursor = end
            if capitalize, let index = piece.firstIndex(where: { !$0.isWhitespace }) {
                capitalize = false
                // « iPhone », « eBay » keep their lower-case first letter.
                let next = piece.index(after: index)
                if piece[index].isLowercase, next == piece.endIndex || !piece[next].isUppercase {
                    piece.replaceSubrange(index...index, with: piece[index].uppercased())
                }
            }
            output += piece
        }
        func lastSolid() -> Character? { output.last { !isBlank($0) } }
        func trimOutput() { while isBlank(output.last) { output.removeLast() } }

        for match in pattern.matches(in: text, range: NSRange(location: 0, length: length)) where match.range.location >= cursor {
            copy(upTo: match.range.location)
            let token = source.substring(with: match.range(at: 1))
            let trailing = source.substring(with: match.range(at: 2))
            var afterStart = skip(from: match.range.location + match.range.length)
            var afterFirst = character(at: afterStart)

            let previous = lastSolid()
            let words = token.split { !$0.isLetter }.map(String.init)
            let shouted = words.contains { $0.count >= 2 && $0 == $0.uppercased() }
            let quoted = (previous.map { "«“\"‘'".contains($0) } ?? false) && (afterFirst.map { "»”\"’'".contains($0) } ?? false)
            let setApart = (previous.map { ",.;:!?…(\n".contains($0) } ?? true)
                && (!trailing.trimmingCharacters(in: .whitespaces).isEmpty || afterFirst == nil || afterFirst == "\n" || afterFirst == ")")
            let onlyHum = words.allSatisfy { matches(hum, $0) }
            let foreign = !removesEnglish && words.contains { matches(english, $0) }
            if shouted || quoted || foreign || (onlyHum && !setApart) { continue }

            trimOutput()
            // « (euh) bon »: the brackets only held the hesitation.
            if output.last == "(", afterFirst == ")", trailing.isEmpty {
                output.removeLast()
                trimOutput()
                afterStart = skip(from: afterStart + 1)
                afterFirst = character(at: afterStart)
            }
            let opensSentence = output.isEmpty || output.hasSuffix("\n") || (output.last.map { ".!?".contains($0) } ?? false) && !output.hasSuffix("...")
            let closing = trailing.replacingOccurrences(of: "...", with: "").replacingOccurrences(of: "…", with: "")
            let mark = ["?", "!", "."].first { closing.contains($0) }

            if let mark, !opensSentence {
                // « D'accord, hum. » ends the sentence the hesitation was tacked onto, with its own spacing (« ? » in French).
                while let last = output.last, ",;".contains(last) { output.removeLast() }
                var spacing = ""
                if let at = trailing.lastIndex(of: Character(mark)), at > trailing.startIndex {
                    let before = trailing[trailing.index(before: at)]
                    if isBlank(before) { spacing = String(before) }
                }
                output += spacing + mark
                if afterFirst != nil { output += " " }
                cursor = afterStart
                continue
            }
            // « Je voudrais, euh, un café »: the commas only framed the hesitation, unless the speaker's own followed an
            // interjection (« Oui, euh, non »).
            if closing.contains(","), output.hasSuffix(",") {
                // Walked back from the comma, not split from the start: a long transcript stays one pass.
                let comma = output.index(before: output.endIndex)
                var start = comma
                while start > output.startIndex, !",.;:!?…\n".contains(output[output.index(before: start)]) { start = output.index(before: start) }
                let clause = output[start..<comma]
                let word = clause.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "’", with: "'")
                // « J'en veux 5, euh, 6 ou 7 », « 9 h, euh, 10 h »: a number (and its unit) on each side keeps the comma;
                // « le 12 à, euh, 14 h » does not end on one.
                let ending = String(clause).trimmingCharacters(in: .whitespaces)
                let numbers = endsOnQuantity(ending) && (afterFirst?.isNumber ?? false)
                if !interjections.contains(word), !numbers { output.removeLast() }
            }
            if output.isEmpty { afterStart = skip(from: afterStart, newlines: true) }
            afterFirst = character(at: afterStart)
            if opensSentence { capitalize = true }
            // Punctuation that follows (« (euh), y ») attaches to the word before, without a space.
            let attaches = afterFirst.map { ",;.!?…)".contains($0) } ?? false
            if !(output.isEmpty || afterFirst == nil || output.hasSuffix("\n") || afterFirst == "\n" || attaches) { output += " " }
            cursor = afterStart
        }
        copy(upTo: length)
        return output.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A number, alone or with one word or symbol after it that is not a small word: « 9 h », « 10 heures », « 2 L ».
    private static func endsOnQuantity(_ clause: String) -> Bool {
        let range = NSRange(location: 0, length: (clause as NSString).length)
        guard let match = endsOnNumber.firstMatch(in: clause, range: range) else { return false }
        let unit = match.range(at: 1)
        guard unit.location != NSNotFound else { return true }
        return !functionWords.contains((clause as NSString).substring(with: unit).lowercased())
    }

    private static func matches(_ regex: NSRegularExpression, _ word: String) -> Bool {
        regex.firstMatch(in: word, range: NSRange(location: 0, length: (word as NSString).length)) != nil
    }
}
