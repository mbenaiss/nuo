import Foundation

/// What the quick-add field understood.
struct ParsedReminder: Equatable {
    var title: String
    var dueAt: Date?
    var `repeat`: String?
    var list: String?
    var priority = 0
    var place: Place?
    /// `arrive` | `leave` when `place` is set.
    var placeTrigger: String?
    /// Recognised phrases, to highlight them in the field.
    var matches: [String] = []
    /// `#Projet` or `#Domaine` naming an existing one; quick add may also set it from the screen it is on.
    var destination: ReminderDestination?
    /// « 🇯🇵 Voyage au Japon », set only when the text named it.
    var destinationLabel: String?
    /// Carried from the « Un jour » screen to the editor.
    var someday = false

    var hasExtras: Bool { dueAt != nil || `repeat` != nil || list != nil || priority > 0 || place != nil || destinationLabel != nil }
}

/// Patterns compiled once: the quick-add fields parse on every keystroke, several times per render, and compiling
/// their few dozen patterns each time cost milliseconds. `NSRegularExpression` is immutable and thread-safe.
enum ParserRegex {
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSRegularExpression> = {
        let cache = NSCache<NSString, NSRegularExpression>()
        cache.countLimit = 300
        return cache
    }()

    static let dateDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    static func compiled(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        let key = "\(options.rawValue)|\(pattern)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        cache.setObject(regex, forKey: key)
        return regex
    }
}

/// French quick-add parsing: « demain 9h », « lundi », « dans 2 h », « le 12 novembre à 14h30 »,
/// « tous les lundis 8h », « #lumen », « !! ». Our own rules first, `NSDataDetector` for what is left.
enum ReminderParser {
    static let defaultHour = 9
    private static let weekdays = ["dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi"]
    private static let months = ["janvier", "fevrier", "mars", "avril", "mai", "juin", "juillet", "aout", "septembre", "octobre", "novembre", "decembre"]
    private static let numberWords = ["un": 1, "une": 1, "deux": 2, "trois": 3, "quatre": 4, "cinq": 5, "six": 6, "dix": 10, "quinze": 15, "vingt": 20, "trente": 30]

    private static let weekdayPattern = "(lundi|mardi|mercredi|jeudi|vendredi|samedi|dimanche)"
    private static let monthPattern = "(janvier|f[ée]vrier|mars|avril|mai|juin|juillet|ao[uû]t|septembre|octobre|novembre|d[ée]cembre)"

    private struct Working {
        var text: String
        var matches: [String] = []

        /// Removes the first match of `pattern` and returns its capture groups (nil for missing groups).
        mutating func take(_ pattern: String) -> [String?]? {
            guard let regex = ParserRegex.compiled(pattern, options: [.caseInsensitive]) else { return nil }
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: range), let whole = Range(match.range, in: text) else { return nil }
            let groups = (0..<match.numberOfRanges).map { index -> String? in
                Range(match.range(at: index), in: text).map { String(text[$0]) }
            }
            matches.append(String(text[whole]).trimmingCharacters(in: .whitespaces))
            text.replaceSubrange(whole, with: " ")
            return groups
        }

        /// Same as `take`, but matched on an accent- and case-folded copy (one character for one), so patterns
        /// are written without accents and still remove the original text.
        mutating func takeFolded(_ pattern: String) -> [String?]? {
            let folded = String(text.map { character -> Character in
                let value = String(character).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
                return value.count == 1 ? value.first! : character
            }).replacingOccurrences(of: "’", with: "'")
            guard folded.count == text.count, let regex = ParserRegex.compiled(pattern),
                  let match = regex.firstMatch(in: folded, range: NSRange(folded.startIndex..., in: folded)),
                  let foldedWhole = Range(match.range, in: folded) else { return nil }
            let groups = (0..<match.numberOfRanges).map { index -> String? in
                Range(match.range(at: index), in: folded).map { String(folded[$0]) }
            }
            let start = text.index(text.startIndex, offsetBy: folded.distance(from: folded.startIndex, to: foldedWhole.lowerBound))
            let end = text.index(start, offsetBy: folded.distance(from: foldedWhole.lowerBound, to: foldedWhole.upperBound))
            matches.append(String(text[start..<end]).trimmingCharacters(in: .whitespaces))
            text.replaceSubrange(start..<end, with: " ")
            return groups
        }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR")).replacingOccurrences(of: "’", with: "'")
    }

    /// « en arrivant à la maison », « quand je pars du bureau », « en quittant la salle de sport », « @Maison ».
    private static func takePlace(_ work: inout Working, places: [Place]) -> (Place, String)? {
        let named = places.map { (place: $0, folded: fold($0.name)) }.filter { !$0.folded.isEmpty }.sorted { $0.folded.count > $1.folded.count }
        guard !named.isEmpty else { return nil }
        let names = named.map { NSRegularExpression.escapedPattern(for: $0.folded) }.joined(separator: "|")
        func place(_ folded: String?) -> Place? {
            guard let folded else { return nil }
            return named.first { $0.folded == folded }?.place
        }
        let arrive = #"\s(?:en arrivant|quand j'arrive|quand je rentre|en rentrant|a mon arrivee)\s+(?:a la |au |aux |a l'|a |chez |la |le |l')?("# + names + #")(?=\s)"#
        if let groups = work.takeFolded(arrive), let found = place(groups[1]) { return (found, "arrive") }
        let leave = #"\s(?:en partant|quand je pars|en sortant|quand je sors|en quittant|quand je quitte|a mon depart)\s+(?:de la |du |des |de l'|d'|de |la |le |l')?("# + names + #")(?=\s)"#
        if let groups = work.takeFolded(leave), let found = place(groups[1]) { return (found, "leave") }
        if let groups = work.takeFolded(#"\s@("# + names + #")(?=\s)"#), let found = place(groups[1]) { return (found, "arrive") }
        return nil
    }

    private struct Container {
        let destination: ReminderDestination
        let label: String
        let folded: String
        /// Letters and digits only: « #voyage-au-japon » and « #VoyageAuJapon » both match.
        let key: String
        let words: [String]
    }

    private static func key(_ folded: String) -> String { String(folded.filter { $0.isLetter || $0.isNumber }) }

    private static func containers(projects: [ReminderProject], areas: [ReminderArea]) -> [Container] {
        func make(_ destination: ReminderDestination, _ title: String, _ emoji: String?) -> Container {
            let folded = fold(title.trimmingCharacters(in: .whitespaces))
            let words = folded.split { !($0.isLetter || $0.isNumber) }.map(String.init)
            let label = emoji.map { $0.isEmpty ? title : "\($0) \(title)" } ?? title
            return Container(destination: destination, label: label, folded: folded, key: key(folded), words: words)
        }
        // Projects first: « #japon » files in the project, not in an area of the same name.
        return projects.map { make(.project($0.id, heading: nil), $0.title, $0.emoji) } + areas.map { make(.area($0.id), $0.title, $0.emoji) }
    }

    /// « #Voyage au Japon » (full name, spaces allowed), else « #japon » matched on the name, its start or one of its words.
    private static func takeContainer(_ work: inout Working, projects: [ReminderProject], areas: [ReminderArea]) -> Container? {
        let named = containers(projects: projects, areas: areas).filter { !$0.key.isEmpty }
        guard !named.isEmpty else { return nil }
        let names = named.map(\.folded).filter { $0.contains(" ") }.sorted { $0.count > $1.count }
        if !names.isEmpty, let groups = work.takeFolded(#"\s#("# + names.map(NSRegularExpression.escapedPattern).joined(separator: "|") + #")(?=\s)"#),
           let found = named.first(where: { $0.folded == groups[1] }) {
            return found
        }
        var probe = work
        guard let groups = probe.take(#"\s#([\p{L}\p{N}_-]+)(?=\s)"#), let tag = groups[1].map({ key(fold($0)) }), !tag.isEmpty else { return nil }
        let found = named.first { $0.key == tag }
            ?? (tag.count >= 2 ? named.filter { $0.key.hasPrefix(tag) }.min { $0.key.count < $1.key.count } : nil)
            ?? named.first { $0.words.contains(tag) }
        if found != nil { work = probe }
        return found
    }

    static func parse(_ input: String, places: [Place] = [], projects: [ReminderProject] = [], areas: [ReminderArea] = [],
                      now: Date = Date(), calendar: Calendar = .current) -> ParsedReminder {
        var work = Working(text: " " + input + " ")
        var result = ParsedReminder(title: input)

        if let (place, trigger) = takePlace(&work, places: places) {
            result.place = place
            result.placeTrigger = trigger
        }

        if let container = takeContainer(&work, projects: projects, areas: areas) {
            result.destination = container.destination
            result.destinationLabel = container.label
        } else if let groups = work.take(#"\s#([\p{L}\p{N}_-]+)(?=\s)"#), let name = groups[1] {
            result.list = name.prefix(1).uppercased() + name.dropFirst()
        }
        if let groups = work.take(#"\s(!{1,3})(?=\s)"#), let marks = groups[1] {
            result.priority = marks.count
        }

        // Repeats
        var repeatKind: RepeatKind?
        if work.take(#"\s(?:tous les jours|chaque jour|quotidiennement)(?=\s)"#) != nil {
            repeatKind = .daily
        } else if work.take(#"\s(?:en semaine|du lundi au vendredi|les jours ouvr[ée]s)(?=\s)"#) != nil {
            repeatKind = .weekdays([1, 2, 3, 4, 5])
        } else if let groups = work.take(#"\s(?:tous les|chaque)\s+((?:\#(weekdayPattern)s?(?:\s*(?:,|et)\s*)?)+)(?=\s)"#), let list = groups[1] {
            let found = weekdays.enumerated().filter { list.lowercased().contains($0.element) }.map(\.offset)
            repeatKind = .weekdays(found)
        } else if work.take(#"\s(?:toutes les semaines|chaque semaine|hebdomadaire)(?=\s)"#) != nil {
            repeatKind = .weekly
        } else if let groups = work.take(#"\s(?:le (\d{1,2})(?:er)? de chaque mois|tous les (\d{1,2})(?:er)? du mois|tous les mois|chaque mois|mensuellement)(?=\s)"#) {
            repeatKind = .monthly(Int(groups[1] ?? groups[2] ?? ""))
        } else if work.take(#"\s(?:tous les ans|chaque ann[ée]e|annuellement)(?=\s)"#) != nil {
            repeatKind = .yearly
        }

        // Absolute offsets win over everything else.
        var due: Date?
        if let groups = work.take(#"\sdans\s+(\d+|une?|deux|trois|quatre|cinq|six|dix|quinze|vingt|trente)\s*(minutes?|min|heures?|h|jours?|j|semaines?|mois)(?=\s)"#),
           let amountText = groups[1], let unit = groups[2]?.lowercased() {
            let amount = Int(amountText) ?? numberWords[amountText.lowercased()] ?? 1
            let component: Calendar.Component = unit.hasPrefix("min") ? .minute : unit.hasPrefix("h") ? .hour
                : unit.hasPrefix("j") ? .day : unit.hasPrefix("s") ? .weekOfYear : .month
            due = calendar.date(byAdding: component, value: amount, to: now)
            if [.day, .weekOfYear, .month].contains(component), let date = due {
                due = calendar.date(bySettingHour: defaultHour, minute: 0, second: 0, of: date)
            }
        }

        var day: Date?
        var impliedHour: Int?
        if due == nil {
            if work.take(#"\s(?:apr[eè]s-demain|apr[eè]s demain)(?=\s)"#) != nil {
                day = calendar.date(byAdding: .day, value: 2, to: now)
            } else if let groups = work.take(#"\sdemain(?:\s+(matin|midi|soir|apr[eè]s-midi))?(?=\s)"#) {
                day = calendar.date(byAdding: .day, value: 1, to: now)
                impliedHour = groups[1].map(hour(forMoment:))
            } else if work.take(#"\sce soir(?=\s)"#) != nil {
                day = now
                impliedHour = 19
            } else if work.take(#"\sce matin(?=\s)"#) != nil {
                day = now
                impliedHour = 9
            } else if work.take(#"\scet? apr[eè]s-midi(?=\s)"#) != nil {
                day = now
                impliedHour = 14
            } else if work.take(#"\s(?:aujourd'hui|aujourd’hui|auj)(?=\s)"#) != nil {
                day = now
            } else if let groups = work.take(#"\s(?:le\s+)?(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?(?=\s)"#),
                      let d = groups[1].flatMap({ Int($0) }), let m = groups[2].flatMap({ Int($0) }) {
                day = date(day: d, month: m, year: groups[3].flatMap { Int($0) }, now: now, calendar: calendar)
            } else if let groups = work.take(#"\s(?:le\s+)?(\d{1,2})(?:er)?\s+\#(monthPattern)(?:\s+(\d{4}))?(?=\s)"#),
                      let d = groups[1].flatMap({ Int($0) }), let name = groups[2] {
                let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                if let index = months.firstIndex(of: folded) {
                    day = date(day: d, month: index + 1, year: groups[3].flatMap { Int($0) }, now: now, calendar: calendar)
                }
            } else if let groups = work.take(#"\s(?:le\s+|ce\s+)?\#(weekdayPattern)(\s+prochain)?(?:\s+(matin|midi|soir|apr[eè]s-midi))?(?=\s)"#),
                      let name = groups[1]?.lowercased(), let weekday = weekdays.firstIndex(of: name) {
                day = next(weekday: weekday, after: now, calendar: calendar, skipThisWeek: groups[2] != nil)
                impliedHour = groups[3].map(hour(forMoment:))
            } else if let groups = work.take(#"\sle\s+(\d{1,2})(?:er)?(?=\s)"#), let d = groups[1].flatMap({ Int($0) }) {
                day = date(day: d, month: nil, year: nil, now: now, calendar: calendar)
            }
        }

        var time: (hour: Int, minute: Int)?
        if due == nil {
            if work.take(#"\s(?:à\s+|a\s+|vers\s+)?midi(?=\s)"#) != nil {
                time = (12, 0)
            } else if work.take(#"\s(?:à\s+|a\s+|vers\s+)?minuit(?=\s)"#) != nil {
                time = (23, 59)
            } else if let groups = work.take(#"\s(?:à\s+|a\s+|vers\s+)?(\d{1,2})\s?(?:h|:)\s?(\d{2})?(?=\s)"#),
                      let h = groups[1].flatMap({ Int($0) }), (0...23).contains(h) {
                time = (h, groups[2].flatMap { Int($0) }.map { min($0, 59) } ?? 0)
            }
        }

        // Whatever date words are left (English, "next Friday"…).
        if due == nil, day == nil, time == nil, repeatKind == nil,
           let detector = ParserRegex.dateDetector {
            let range = NSRange(work.text.startIndex..., in: work.text)
            if let match = detector.firstMatch(in: work.text, range: range), let date = match.date, let whole = Range(match.range, in: work.text) {
                work.matches.append(String(work.text[whole]))
                work.text.replaceSubrange(whole, with: " ")
                due = date
            }
        }

        if let repeatKind {
            let at = time ?? impliedHour.map { ($0, 0) } ?? (defaultHour, 0)
            let rule = repeatKind.cron(hour: at.hour, minute: at.minute, anchor: day ?? now, calendar: calendar)
            result.repeat = rule
            if let day {
                result.dueAt = calendar.date(bySettingHour: at.hour, minute: at.minute, second: 0, of: day)
            } else {
                result.dueAt = CronSpec(rule)?.next(after: now, timeZone: calendar.timeZone)
            }
        } else if let due {
            result.dueAt = due
        } else if let day {
            let at = time ?? impliedHour.map { ($0, 0) } ?? (defaultHour, 0)
            result.dueAt = calendar.date(bySettingHour: at.hour, minute: at.minute, second: 0, of: day)
        } else if let time {
            var date = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: now) ?? now
            if date <= now { date = calendar.date(byAdding: .day, value: 1, to: date) ?? date }
            result.dueAt = date
        }

        result.title = work.text
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;-–")))
        if result.title.isEmpty { result.title = input.trimmingCharacters(in: .whitespaces) }
        if let first = result.title.first, first.isLowercase, input.trimmingCharacters(in: .whitespaces).first?.isUppercase == true {
            result.title = first.uppercased() + result.title.dropFirst()
        }
        result.matches = work.matches
        return result
    }

    private static func hour(forMoment moment: String) -> Int {
        switch moment.lowercased() {
        case "matin": 9
        case "midi": 12
        case "soir": 19
        default: 14
        }
    }

    private static func date(day: Int, month: Int?, year: Int?, now: Date, calendar: Calendar) -> Date? {
        let today = calendar.dateComponents([.year, .month, .day], from: now)
        var components = DateComponents(year: year.map { $0 < 100 ? 2000 + $0 : $0 } ?? today.year, month: month ?? today.month, day: day, hour: 12)
        guard var date = calendar.date(from: components), calendar.component(.day, from: date) == day else { return nil }
        if year == nil, calendar.startOfDay(for: date) < calendar.startOfDay(for: now) {
            if month == nil {
                date = calendar.date(byAdding: .month, value: 1, to: date) ?? date
            } else {
                components.year = (components.year ?? 0) + 1
                date = calendar.date(from: components) ?? date
            }
        }
        return date
    }

    private static func next(weekday: Int, after now: Date, calendar: Calendar, skipThisWeek: Bool) -> Date {
        let current = calendar.component(.weekday, from: now) - 1
        var delta = (weekday - current + 7) % 7
        if delta == 0 { delta = 7 }
        if skipThisWeek && delta < 7 && weekday != 0 && current != 0 && weekday > current { delta += 7 }
        return calendar.date(byAdding: .day, value: delta, to: now) ?? now
    }
}

private enum RepeatKind {
    case daily
    case weekdays([Int])
    case weekly
    case monthly(Int?)
    case yearly

    func cron(hour: Int, minute: Int, anchor: Date, calendar: Calendar) -> String {
        switch self {
        case .daily: return "\(minute) \(hour) * * *"
        case let .weekdays(days):
            let list = days.isEmpty ? [calendar.component(.weekday, from: anchor) - 1] : days
            return "\(minute) \(hour) * * \(list.sorted().map(String.init).joined(separator: ","))"
        case .weekly: return "\(minute) \(hour) * * \(calendar.component(.weekday, from: anchor) - 1)"
        case let .monthly(day): return "\(minute) \(hour) \(day ?? calendar.component(.day, from: anchor)) * *"
        case .yearly: return "\(minute) \(hour) \(calendar.component(.day, from: anchor)) \(calendar.component(.month, from: anchor)) *"
        }
    }
}
