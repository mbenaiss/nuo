import Foundation

enum TurnLabels {
    /// "42 s", "3 min", "1 h 05".
    static func elapsed(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds) s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        return String(format: "%d h %02d", minutes / 60, minutes % 60)
    }

    /// The program or tool behind a step title: "gog calendar events --week" → "gog", "mcp__nuo__schedules_list" → "schedules_list".
    static func toolName(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "`"))
        if text.hasPrefix("mcp__"), let last = text.components(separatedBy: "__").last, !last.isEmpty { text = last }
        let first = text.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? text
        let name = first.trimmingCharacters(in: CharacterSet(charactersIn: ":()")).split(separator: "/").last.map(String.init) ?? first
        return name.count > 28 ? String(name.prefix(27)) + "…" : name
    }

    /// A step description on one line, cut at a word boundary when longer than `limit`; nil when empty.
    static func description(_ detail: String?, limit: Int = 60) -> String? {
        guard let detail else { return nil }
        let line = detail.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !line.isEmpty else { return nil }
        guard line.count > limit else { return line }
        var cut = String(line.prefix(limit - 1))
        let endsOnWord = line[line.index(line.startIndex, offsetBy: limit - 1)] == " "
        if !endsOnWord, let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) >= limit / 2 {
            cut = String(cut[..<space])
        }
        while let last = cut.unicodeScalars.last, CharacterSet.whitespaces.union(.punctuationCharacters).contains(last) { cut.removeLast() }
        return cut + "…"
    }

    /// How long a turn may show only a generic status (« réfléchit… ») before the line appears: short turns
    /// never flash it, while a specific status (a tool, its description, the answer) shows at once.
    static let genericDelay: TimeInterval = 1.2

    static func isGeneric(phase: TurnPhase, tool: String?, detail: String?, steps: Int) -> Bool {
        switch phase {
        case .queued: true
        case .thinking: steps == 0
        case .working: description(detail) == nil && tool == nil
        case .answering, .waitingPermission: false
        }
    }

    static func steps(_ count: Int) -> String {
        String(localized: "\(count) steps")
    }

    static func status(bot: String, phase: TurnPhase, tool: String?, detail: String? = nil, steps: Int) -> String {
        switch phase {
        case .queued: return String(localized: "\(bot) is getting ready…")
        case .thinking: return steps > 0 ? String(localized: "\(bot) is thinking… (\(Self.steps(steps)))") : String(localized: "\(bot) is thinking…")
        case .working:
            if let text = description(detail) {
                return steps > 1 ? String(localized: "\(bot): \(text) (\(Self.steps(steps)))") : String(localized: "\(bot): \(ongoing(text))")
            }
            let name = tool.map(toolName) ?? String(localized: "a tool")
            return steps > 1 ? String(localized: "\(bot) is using \(name) (\(Self.steps(steps)))") : String(localized: "\(bot) is using \(name)…")
        case .answering: return String(localized: "\(bot) is writing…")
        case .waitingPermission: return String(localized: "\(bot) is waiting for your permission")
        }
    }

    /// Short form for list rows and badges.
    static func short(phase: TurnPhase, tool: String?, detail: String? = nil) -> String {
        switch phase {
        case .queued, .thinking: String(localized: "thinking…")
        case .working: description(detail, limit: 40).map(ongoing) ?? tool.map { String(localized: "using \(toolName($0))…") } ?? String(localized: "working…")
        case .answering: String(localized: "writing…")
        case .waitingPermission: String(localized: "waiting for your permission")
        }
    }

    private static func ongoing(_ text: String) -> String {
        text.hasSuffix("…") ? text : text + "…"
    }
}
