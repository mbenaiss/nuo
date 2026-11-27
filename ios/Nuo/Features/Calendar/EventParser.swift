import Foundation

enum EventRecurrence: Hashable, Sendable {
    case daily
    case weekdays
    /// Weekdays 0 = Sunday … 6 = Saturday.
    case weekly([Int])
    case monthly
    case yearly

    var label: String {
        switch self {
        case .daily: String(localized: "Every day")
        case .weekdays: String(localized: "Weekdays")
        case let .weekly(days):
            if days.count == 1, let day = days.first { String(localized: "Every \(AgendaCalendar.current.weekdaySymbols[day])") }
            else { String(localized: "Weekly on \(days.sorted { ($0 + 6) % 7 < ($1 + 6) % 7 }.map { AgendaCalendar.current.shortWeekdaySymbols[$0] }.formatted(.list(type: .and)))") }
        case .monthly: String(localized: "Every month")
        case .yearly: String(localized: "Every year")
        }
    }

    /// From the 5-field cron the reminder parser produces.
    init?(cron: String) {
        let fields = cron.split(separator: " ").map(String.init)
        guard fields.count == 5 else { return nil }
        switch (fields[2], fields[3], fields[4]) {
        case ("*", "*", "*"): self = .daily
        case ("*", "*", "1,2,3,4,5"), ("*", "*", "1-5"): self = .weekdays
        case let ("*", "*", days): self = .weekly(days.split(separator: ",").compactMap { Int($0) }.map { $0 % 7 })
        case (_, "*", "*"): self = .monthly
        default: self = .yearly
        }
    }
}

/// What the quick-entry field understood.
struct ParsedEvent: Equatable, Sendable {
    var title: String
    var start: Date
    var end: Date
    var allDay = false
    /// A date or a time was typed (otherwise the event starts at the next half hour).
    var hasWhen = false
    var location: String?
    /// `/pro` or `#pro`: the calendar's short name as typed, and the calendar it designates.
    var calendarHint: String?
    var calendarId: String?
    var recurrence: EventRecurrence?
    var alarmMinutes: Int?
    var attendees: [String] = []
    var meet = false
    /// Recognised phrases, for highlighting.
    var matches: [String] = []

    var duration: TimeInterval { end.timeIntervalSince(start) }
    /// Invitations can only be sent by Google: EventKit cannot add attendees.
    var needsGoogle: Bool { !attendees.isEmpty || meet }
}

/// Fantastical-like French parsing for events: « Dentiste jeudi 14h au 8 rue des Lilas »,
/// « Point Lumen Studio tous les lundis 9h /pro », « vol Paris Rome 18 juillet 14h40-17h05 », « 1h30 », « de 14h à 16h »,
/// « vendredi toute la journée », « rappel 15 min avant », « avec jean@exemple.fr », « en visio ».
/// Event-only phrases are taken first; dates, times and repeats are left to `ReminderParser`.
enum EventParser {
    private static let numberWords = ["un": 1, "une": 1, "deux": 2, "trois": 3, "quatre": 4, "cinq": 5, "dix": 10, "quinze": 15, "vingt": 20, "trente": 30]
    private static let months = ["janvier", "fevrier", "mars", "avril", "mai", "juin", "juillet", "aout", "septembre", "octobre", "novembre", "decembre"]
    private static let monthPattern = "(janvier|fevrier|mars|avril|mai|juin|juillet|aout|septembre|octobre|novembre|decembre)"
    private static let hourPattern = #"(\d{1,2})\s?(?:h|:)\s?(\d{2})?"#

    /// Text being consumed: patterns run on an accent- and case-folded copy of the same length, so they are
    /// written without accents and still cut the original text.
    private struct Working {
        // Folded once per change of the text rather than for each of the dozen patterns tried on it.
        var text: String {
            didSet { folded = Self.fold(text) }
        }
        private(set) var folded: String
        var matches: [String] = []

        init(text: String) {
            self.text = text
            folded = Self.fold(text)
        }

        private static func fold(_ text: String) -> String {
            String(text.map { character -> Character in
                let value = String(character).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: ValueFormat.locale)
                return value.count == 1 ? value.first! : character
            }).replacingOccurrences(of: "’", with: "'")
        }

        mutating func take(_ pattern: String, keep: Bool = false) -> [String?]? {
            let folded = self.folded
            guard folded.count == text.count, let regex = ParserRegex.compiled(pattern),
                  let match = regex.firstMatch(in: folded, range: NSRange(folded.startIndex..., in: folded)),
                  let whole = Range(match.range, in: folded) else { return nil }
            func original(_ range: Range<String.Index>) -> Range<String.Index> {
                let start = text.index(text.startIndex, offsetBy: folded.distance(from: folded.startIndex, to: range.lowerBound))
                let end = text.index(start, offsetBy: folded.distance(from: range.lowerBound, to: range.upperBound))
                return start..<end
            }
            let groups = (0..<match.numberOfRanges).map { index -> String? in
                Range(match.range(at: index), in: folded).map { String(text[original($0)]) }
            }
            let range = original(whole)
            matches.append(String(text[range]).trimmingCharacters(in: .whitespaces))
            if !keep { text.replaceSubrange(range, with: " ") }
            return groups
        }

        /// Blanks a span given in characters (same in the folded and the original text).
        mutating func remove(offsets: Range<Int>) {
            let start = text.index(text.startIndex, offsetBy: offsets.lowerBound)
            let end = text.index(start, offsetBy: offsets.count)
            matches.append(String(text[start..<end]).trimmingCharacters(in: .whitespaces))
            text.replaceSubrange(start..<end, with: " ")
        }
    }

    static func parse(_ input: String, calendars: [CalendarInfo] = [], now: Date = Date(), calendar: Calendar = AgendaCalendar.current) -> ParsedEvent {
        var work = Working(text: " " + input.replacingOccurrences(of: "\n", with: " ") + " ")
        let defaultStart = nextHalfHour(after: now, calendar: calendar)
        var result = ParsedEvent(title: input, start: defaultStart, end: defaultStart.addingTimeInterval(Double(CalendarMetrics.defaultDurationMinutes) * 60))

        // Attendees: the address leaves the title, the person's name stays (« Point avec Jean Dupont »).
        while let range = work.text.range(of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, options: .regularExpression) {
            let email = String(work.text[range])
            result.attendees.append(email.lowercased())
            work.matches.append(email)
            work.text.replaceSubrange(range, with: displayName(email))
        }

        if let groups = work.take(#"\s/([\p{L}\p{N}_-]+)(?=\s)"#), let hint = groups[1] {
            result.calendarHint = hint
        }
        if work.take(#"\s(?:en visio|visio|en visioconference|google meet|avec meet|meet)(?=\s)"#) != nil {
            result.meet = true
        }

        // Alerts before durations: « rappel 15 min avant » is not a 15-minute event.
        if let groups = work.take(#"\s(?:avec\s+)?(?:un\s+)?(?:rappel|alerte|notif(?:ication)?)\s+(\d{1,3}|une?|deux|cinq|dix|quinze|trente)\s*(min(?:utes?)?|mn|h(?:eures?)?|j(?:ours?)?)\s+avant(?=\s)"#),
           let amountText = groups[1], let unit = groups[2] {
            let amount = Int(amountText) ?? numberWords[amountText] ?? 1
            result.alarmMinutes = unit.hasPrefix("h") ? amount * 60 : unit.hasPrefix("j") ? amount * 1440 : amount
        } else if work.take(#"\s(?:avec\s+)?(?:un\s+)?(?:rappel|alerte)\s+la veille(?=\s)"#) != nil {
            result.alarmMinutes = 1440
        } else if work.take(#"\s(?:avec\s+)?(?:un\s+)?(?:rappel|alerte)\s+(?:a l'heure|au debut)(?=\s)"#) != nil {
            result.alarmMinutes = 0
        }

        if work.take(#"\s(?:toute la journee|journee entiere|toute la journee|all day|la journee)(?=\s)"#) != nil {
            result.allDay = true
        }

        // « du 3 au 5 novembre »: several whole days.
        var dayRange: (Date, Date)?
        if let groups = work.take(#"\s(?:du\s+)(\d{1,2})(?:er)?(?:\s+\#(monthPattern))?\s+au\s+(\d{1,2})(?:er)?\s+\#(monthPattern)(?=\s)"#),
           let d1 = groups[1].flatMap({ Int($0) }), let d2 = groups[3].flatMap({ Int($0) }), let m2 = groups[4].map(fold).flatMap({ months.firstIndex(of: $0) }) {
            let m1 = groups[2].map(fold).flatMap { months.firstIndex(of: $0) } ?? m2
            if let first = date(day: d1, month: m1 + 1, now: now, calendar: calendar), var last = date(day: d2, month: m2 + 1, now: now, calendar: calendar) {
                if last < first { last = calendar.date(byAdding: .year, value: 1, to: last) ?? last }
                dayRange = (first, last)
                result.allDay = true
            }
        }

        // « 14h40-17h05 », « de 14h à 16h », « entre 9h et 10h ».
        var timeRange: ((Int, Int), (Int, Int))?
        if let groups = work.take(#"\s(?:de\s+|entre\s+)?(?:a\s+)?\#(hourPattern)\s*(?:-|–|a|jusqu'a|et)\s*\#(hourPattern)(?=\s)"#),
           let h1 = groups[1].flatMap({ Int($0) }), let h2 = groups[3].flatMap({ Int($0) }), (0...23).contains(h1), (0...24).contains(h2) {
            timeRange = ((h1, groups[2].flatMap { Int($0) } ?? 0), (h2 % 24, groups[4].flatMap { Int($0) } ?? 0))
        }

        var duration: Int?
        if let groups = work.take(#"\s(?:pendant|durant|pour|sur)\s+(\d{1,2})\s?h\s?(\d{2})?(?=\s)"#), let h = groups[1].flatMap({ Int($0) }) {
            duration = h * 60 + (groups[2].flatMap { Int($0) } ?? 0)
        } else if let groups = work.take(#"(?<!dans)\s(?:pendant\s+|durant\s+|pour\s+)?(\d{1,3})\s?(?:min|minutes|mn)(?=\s)"#), let m = groups[1].flatMap({ Int($0) }) {
            duration = m
        } else if timeRange == nil {
            // Two bare times: the second one is an end time when later, a duration otherwise (« 14h 1h30 »).
            let tokens = timeTokens(in: work.folded)
            if tokens.count >= 2 {
                let first = tokens[0], second = tokens[1]
                let firstValue = first.hour * 60 + first.minute, secondValue = second.hour * 60 + second.minute
                work.remove(offsets: second.offsets)
                if secondValue > firstValue {
                    timeRange = ((first.hour, first.minute), (second.hour, second.minute))
                    work.remove(offsets: first.offsets)
                } else {
                    duration = secondValue
                }
            }
        }

        let hasTime = timeRange != nil || work.folded.range(of: #"\s(?:a\s+|vers\s+)?(?:\d{1,2}\s?(?:h|:)\s?\d{0,2}|midi|minuit)(?=\s)|ce soir|ce matin|cet? apres-midi|(?:matin|soir|apres-midi)(?=\s)|dans\s+\d+\s*(?:min|h)"#, options: .regularExpression) != nil
        let rest = ReminderParser.parse(work.text, now: now, calendar: calendar)
        work.matches += rest.matches
        if result.calendarHint == nil, let list = rest.list { result.calendarHint = list.lowercased() }
        result.recurrence = rest.repeat.flatMap(EventRecurrence.init(cron:))

        var title = rest.title
        if let (location, keepsTitle, stripped) = takeLocation(title) {
            result.location = location
            work.matches.append(location)
            if !keepsTitle { title = stripped }
        }
        result.title = AgendaText.capitalized(title.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;-–"))))
        if result.title.isEmpty { result.title = AgendaText.capitalized(input.trimmingCharacters(in: .whitespaces)) }

        let minutes = duration ?? CalendarMetrics.defaultDurationMinutes
        if let (first, last) = dayRange {
            result.start = calendar.startOfDay(for: first)
            result.end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: last)) ?? last
            result.hasWhen = true
        } else if result.allDay || (rest.dueAt != nil && !hasTime) {
            let day = calendar.startOfDay(for: rest.dueAt ?? now)
            result.allDay = true
            result.start = day
            result.end = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            result.hasWhen = true
        } else if let ((h1, m1), (h2, m2)) = timeRange {
            var day = calendar.startOfDay(for: rest.dueAt ?? now)
            var start = calendar.date(bySettingHour: h1, minute: m1, second: 0, of: day) ?? now
            if rest.dueAt == nil, start < now {
                day = calendar.date(byAdding: .day, value: 1, to: day) ?? day
                start = calendar.date(bySettingHour: h1, minute: m1, second: 0, of: day) ?? start
            }
            var end = calendar.date(bySettingHour: h2, minute: m2, second: 0, of: day) ?? start
            if end <= start { end = calendar.date(byAdding: .day, value: 1, to: end) ?? end }
            result.start = start
            result.end = end
            result.hasWhen = true
        } else if let due = rest.dueAt {
            result.start = due
            result.end = due.addingTimeInterval(Double(minutes) * 60)
            result.hasWhen = true
        } else {
            result.end = result.start.addingTimeInterval(Double(minutes) * 60)
        }

        result.calendarId = resolveCalendar(result.calendarHint, in: calendars)?.id
        result.matches = work.matches.filter { !$0.isEmpty }
        return result
    }

    // MARK: Helpers

    static func fold(_ text: String) -> String { ReminderParser.fold(text) }

    /// `/pro` designates « Pro Lumen Studio »: a calendar whose title (or one of its words) starts with the hint.
    static func resolveCalendar(_ hint: String?, in calendars: [CalendarInfo]) -> CalendarInfo? {
        guard let hint = hint.map(fold), !hint.isEmpty else { return nil }
        let candidates = calendars.filter { $0.enabled && $0.allowsModifications && !$0.isBusyOnly }
        if let exact = candidates.first(where: { fold($0.title) == hint }) { return exact }
        if let prefix = candidates.first(where: { fold($0.title).hasPrefix(hint) }) { return prefix }
        return candidates.first { fold($0.title).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0.hasPrefix(hint) } }
    }

    /// « au Café de Flore », « à Station F », « chez Sami » at the end of the title, followed by a capital.
    private static func takeLocation(_ title: String) -> (location: String, keepsTitle: Bool, stripped: String)? {
        let pattern = #"\s(au|aux|à la|à l'|à l’|à|a|chez|@)\s*([A-ZÀ-ÖØ-Ý0-9][^@]*)$"#
        guard let regex = ParserRegex.compiled(pattern),
              let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              let whole = Range(match.range, in: title), let prepositionRange = Range(match.range(at: 1), in: title),
              let placeRange = Range(match.range(at: 2), in: title) else { return nil }
        let place = String(title[placeRange]).trimmingCharacters(in: .whitespaces)
        guard !place.isEmpty else { return nil }
        let preposition = String(title[prepositionRange])
        return (place, preposition == "chez", String(title[..<whole.lowerBound]))
    }

    /// « jean.dupont@exemple.fr » → « Jean Dupont ».
    static func displayName(_ email: String) -> String {
        let local = email.split(separator: "@").first.map(String.init) ?? email
        return local.split(whereSeparator: { ".-_+".contains($0) }).map { AgendaText.capitalized(String($0)) }.joined(separator: " ")
    }

    /// Bare times (« 14h », « à 9:30 ») with their character offsets in the folded text.
    private static func timeTokens(in folded: String) -> [(hour: Int, minute: Int, offsets: Range<Int>)] {
        guard let regex = ParserRegex.compiled(#"\s(?:a\s+)?(\d{1,2})\s?(?:h|:)\s?(\d{2})?(?=\s)"#) else { return [] }
        return regex.matches(in: folded, range: NSRange(folded.startIndex..., in: folded)).compactMap { match in
            guard let whole = Range(match.range, in: folded),
                  let hours = Range(match.range(at: 1), in: folded).flatMap({ Int(folded[$0]) }), (0...23).contains(hours) else { return nil }
            let minutes = Range(match.range(at: 2), in: folded).flatMap { Int(folded[$0]) } ?? 0
            let lower = folded.distance(from: folded.startIndex, to: whole.lowerBound)
            return (hours, min(minutes, 59), lower..<(lower + folded.distance(from: whole.lowerBound, to: whole.upperBound)))
        }
    }

    private static func date(day: Int, month: Int, now: Date, calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year], from: now)
        components.month = month
        components.day = day
        components.hour = 12
        guard var date = calendar.date(from: components) else { return nil }
        if calendar.startOfDay(for: date) < calendar.startOfDay(for: now) { date = calendar.date(byAdding: .year, value: 1, to: date) ?? date }
        return date
    }

    static func nextHalfHour(after date: Date, calendar: Calendar) -> Date {
        let minute = calendar.component(.minute, from: date)
        let base = calendar.date(bySetting: .second, value: 0, of: date) ?? date
        let delta = minute < 30 ? 30 - minute : 60 - minute
        return calendar.date(byAdding: .minute, value: delta, to: base) ?? date
    }
}
