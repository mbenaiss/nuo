import Foundation

/// A bot memory split into lines, so one fact can be edited or deleted and the whole text written back.
struct MemoryDocument: Equatable {
    struct Fact: Identifiable, Equatable {
        let line: Int
        var day: String? // YYYY-MM-DD, as the gateway writes it
        var text: String
        var id: Int { line }
        var date: Date? { day.flatMap(MemoryDocument.dayFormatter.date(from:)) }
    }

    private(set) var lines: [String]

    init(_ content: String) {
        var lines = content.components(separatedBy: "\n")
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        self.lines = lines
    }

    var content: String { lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n" }

    /// Lines in the `- [YYYY-MM-DD] fact` shape.
    var facts: [Fact] { lines.indices.compactMap(fact(at:)) }

    /// Anything else that is not blank (headings, free text), only editable in the raw editor.
    var otherLines: [String] {
        lines.indices.filter { fact(at: $0) == nil }.map { lines[$0] }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    func fact(at index: Int) -> Fact? {
        guard lines.indices.contains(index) else { return nil }
        let line = lines[index].trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("- ") else { return nil }
        let body = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }
        let head = String(body.prefix(10))
        if body.count > 11, Self.dayFormatter.date(from: head) != nil, body.dropFirst(10).first == " " {
            return Fact(line: index, day: head, text: String(body.dropFirst(11)).trimmingCharacters(in: .whitespaces))
        }
        return Fact(line: index, day: nil, text: body)
    }

    /// Where `fact` (read from an earlier copy of the memory) is now: the same day and text, nearest its old line.
    func index(of fact: Fact) -> Int? {
        func matches(_ index: Int) -> Bool {
            guard let candidate = self.fact(at: index) else { return false }
            return candidate.day == fact.day && candidate.text == fact.text
        }
        if matches(fact.line) { return fact.line }
        return lines.indices.filter(matches).min { abs($0 - fact.line) < abs($1 - fact.line) }
    }

    /// False when the fact is no longer in the text (removed or changed meanwhile).
    @discardableResult
    mutating func update(_ fact: Fact, text: String) -> Bool {
        guard let index = index(of: fact) else { return false }
        let clean = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        lines[index] = "- " + [fact.day, clean].compactMap { $0 }.joined(separator: " ")
        return true
    }

    @discardableResult
    mutating func remove(_ fact: Fact) -> Bool {
        guard let index = index(of: fact) else { return false }
        lines.remove(at: index)
        return true
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }()

    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }

    /// "12 oct.", or "12 oct. 2025" for another year.
    static func dayLabel(_ date: Date) -> String {
        var style = Date.FormatStyle(locale: .current).day().month(.abbreviated)
        style.timeZone = TimeZone(identifier: "UTC") ?? .current
        let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        return date.formatted(sameYear ? style : style.year())
    }

    /// "2 h ago", "yesterday", "5 d ago".
    static func updatedLabel(_ date: Date, now: Date = Date()) -> String {
        let interval = now.timeIntervalSince(date)
        if interval < 60 { return String(localized: "just now") }
        if interval < 3600 { return String(localized: "\(Int(interval / 60)) min ago") }
        if interval < 86400 { return String(localized: "\(Int(interval / 3600)) h ago") }
        if Calendar.current.isDateInYesterday(date) { return String(localized: "yesterday") }
        if interval < 30 * 86400 { return String(localized: "\(Int(interval / 86400)) d ago") }
        return String(localized: "on \(dayLabel(date))")
    }
}
