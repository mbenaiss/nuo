import Foundation

/// A parsed 5-field cron expression (minute hour day-of-month month day-of-week), as the gateway runs it.
struct CronSpec: Equatable {
    let minutes: Set<Int>
    let hours: Set<Int>
    let days: Set<Int>
    let months: Set<Int>
    let weekdays: Set<Int> // 0 = Sunday
    let daysRestricted: Bool
    let weekdaysRestricted: Bool

    init?(_ expression: String) {
        let fields = expression.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5,
              let minutes = Self.parse(fields[0], 0...59),
              let hours = Self.parse(fields[1], 0...23),
              let days = Self.parse(fields[2], 1...31),
              let months = Self.parse(fields[3], 1...12),
              let weekdays = Self.parse(fields[4], 0...7)
        else { return nil }
        self.minutes = minutes
        self.hours = hours
        self.days = days
        self.months = months
        self.weekdays = Set(weekdays.map { $0 == 7 ? 0 : $0 })
        daysRestricted = fields[2] != "*"
        weekdaysRestricted = fields[4] != "*"
    }

    private static func parse(_ field: String, _ range: ClosedRange<Int>) -> Set<Int>? {
        var values = Set<Int>()
        for part in field.split(separator: ",", omittingEmptySubsequences: false) {
            let pieces = part.split(separator: "/", omittingEmptySubsequences: false)
            guard pieces.count <= 2 else { return nil }
            var step = 1
            if pieces.count == 2 {
                guard let value = Int(pieces[1]), value > 0 else { return nil }
                step = value
            }
            let base = pieces[0]
            var lower = range.lowerBound
            var upper = range.upperBound
            if base != "*" {
                let bounds = base.split(separator: "-", omittingEmptySubsequences: false)
                guard let first = bounds.first.flatMap({ Int($0) }), bounds.count <= 2 else { return nil }
                lower = first
                upper = bounds.count == 2 ? (Int(bounds[1]) ?? -1) : (pieces.count == 2 ? range.upperBound : first)
            }
            guard range.contains(lower), range.contains(upper), lower <= upper else { return nil }
            values.formUnion(stride(from: lower, through: upper, by: step))
        }
        return values.isEmpty ? nil : values
    }

    private func matchesDay(_ components: DateComponents) -> Bool {
        guard let day = components.day, let weekday = components.weekday else { return false }
        let dayOK = days.contains(day)
        let weekdayOK = weekdays.contains(weekday - 1)
        // Standard cron: when both fields are restricted, either one matching is enough.
        if daysRestricted && weekdaysRestricted { return dayOK || weekdayOK }
        return dayOK && weekdayOK
    }

    /// First matching minute strictly after `date`, within two years.
    func next(after date: Date, timeZone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var current = Date(timeIntervalSinceReferenceDate: (floor(date.timeIntervalSinceReferenceDate / 60) + 1) * 60)
        let limit = date.addingTimeInterval(2 * 366 * 86400)
        while current < limit {
            let parts = calendar.dateComponents([.month, .day, .weekday, .hour, .minute], from: current)
            if !months.contains(parts.month ?? 0) || !matchesDay(parts) {
                guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: current)) else { return nil }
                current = tomorrow
            } else if !hours.contains(parts.hour ?? 0) {
                current = current.addingTimeInterval(Double(60 - (parts.minute ?? 0)) * 60)
            } else if !minutes.contains(parts.minute ?? 0) {
                current = current.addingTimeInterval(60)
            } else {
                return current
            }
        }
        return nil
    }
}

/// The presets the editor offers, so nobody has to write cron by hand.
enum SchedulePreset: String, CaseIterable, Identifiable {
    case daily, weekdays, weekly, hourly, once, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .daily: String(localized: "Daily")
        case .weekdays: String(localized: "Monday to Friday")
        case .weekly: String(localized: "Weekly")
        case .hourly: String(localized: "Every N hours")
        case .once: String(localized: "One time")
        case .custom: String(localized: "Custom")
        }
    }

    var symbol: String {
        switch self {
        case .daily: "sun.max"
        case .weekdays: "briefcase"
        case .weekly: "calendar"
        case .hourly: "arrow.clockwise"
        case .once: "calendar.badge.clock"
        case .custom: "chevron.left.forwardslash.chevron.right"
        }
    }
}

/// Editable form of a `TaskSchedule`, with the cron expression kept in sync with the preset fields.
struct ScheduleRule: Equatable {
    static let defaultTimeZone = "Europe/Paris"
    /// Cron weekday numbers, Monday first.
    static let weekOrder = [1, 2, 3, 4, 5, 6, 0]

    var preset: SchedulePreset = .daily
    var hour = 8
    var minute = 0
    var weekdays: Set<Int> = [1]
    var everyHours = 2
    var onceAt = Date().addingTimeInterval(3600)
    var customExpr = ""
    var timezone = ScheduleRule.defaultTimeZone

    init() {}

    init(_ schedule: TaskSchedule) {
        if schedule.kind == "once" {
            preset = .once
            onceAt = schedule.at ?? Date().addingTimeInterval(3600)
            return
        }
        timezone = schedule.timezone ?? Self.defaultTimeZone
        apply(expression: schedule.expr ?? "")
    }

    /// Reads a cron expression back into presets when it has a known shape, else keeps it as custom.
    mutating func apply(expression: String) {
        let trimmed = expression.trimmingCharacters(in: .whitespaces)
        customExpr = trimmed
        let fields = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5, CronSpec(trimmed) != nil else {
            preset = .custom
            return
        }
        let (m, h, dom, month, dow) = (fields[0], fields[1], fields[2], fields[3], fields[4])
        if let minute = Int(m), h.hasPrefix("*/"), let step = Int(h.dropFirst(2)), dom == "*", month == "*", dow == "*", (1...12).contains(step) {
            preset = .hourly
            self.minute = minute
            everyHours = step
            return
        }
        guard let minute = Int(m), let hour = Int(h), dom == "*", month == "*", let spec = CronSpec(trimmed) else {
            preset = .custom
            return
        }
        self.minute = minute
        self.hour = hour
        if dow == "*" {
            preset = .daily
        } else if spec.weekdays == [1, 2, 3, 4, 5] {
            preset = .weekdays
        } else {
            preset = .weekly
            weekdays = spec.weekdays
        }
    }

    var cronExpression: String {
        switch preset {
        case .daily: "\(minute) \(hour) * * *"
        case .weekdays: "\(minute) \(hour) * * 1-5"
        case .weekly: "\(minute) \(hour) * * \(weekdays.sorted().map(String.init).joined(separator: ","))"
        case .hourly: "\(minute) */\(everyHours) * * *"
        case .once: ""
        case .custom: customExpr
        }
    }

    var schedule: TaskSchedule {
        if preset == .once { return TaskSchedule(kind: "once", expr: nil, timezone: nil, at: onceAt) }
        return TaskSchedule(kind: "cron", expr: cronExpression, timezone: timezone, at: nil)
    }

    var time: Date {
        get { Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date() }
        set {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            hour = parts.hour ?? hour
            minute = parts.minute ?? minute
        }
    }

    /// Validation message, nil when the schedule can be saved.
    var error: String? {
        switch preset {
        case .weekly where weekdays.isEmpty: return String(localized: "Check at least one day.")
        case .once where onceAt <= Date(): return String(localized: "Pick a future date.")
        default: break
        }
        if preset != .once {
            if CronSpec(cronExpression) == nil { return String(localized: "Invalid cron expression: 5 fields (minute hour day month weekday).") }
            if TimeZone(identifier: timezone) == nil { return String(localized: "Unknown time zone (e.g. Europe/Paris).") }
        }
        return nil
    }

    var nextRun: Date? { ScheduleText.nextRun(schedule, after: Date()) }
}

/// Wording for schedules and run times.
enum ScheduleText {
    static var locale: Locale { .current }
    private static var shortDays: [String] { [String(localized: "schedule.day.short.0", defaultValue: "Sun"), String(localized: "schedule.day.short.1", defaultValue: "Mon"), String(localized: "schedule.day.short.2", defaultValue: "Tue"), String(localized: "schedule.day.short.3", defaultValue: "Wed"), String(localized: "schedule.day.short.4", defaultValue: "Thu"), String(localized: "schedule.day.short.5", defaultValue: "Fri"), String(localized: "schedule.day.short.6", defaultValue: "Sat")] }
    private static var longDays: [String] { WeekdayNames.long }

    static func time(hour: Int, minute: Int) -> String { "\(hour):\(String(format: "%02d", minute))" }

    static func time(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return time(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
    }

    static func describe(_ schedule: TaskSchedule) -> String {
        if schedule.kind == "once" {
            guard let at = schedule.at else { return String(localized: "One time") }
            return String(localized: "On \(dayMonth(at)) at \(time(at))")
        }
        let rule = ScheduleRule(schedule)
        let at = time(hour: rule.hour, minute: rule.minute)
        switch rule.preset {
        case .daily: return String(localized: "Every day at \(at)")
        case .weekdays: return String(localized: "Mon-Fri at \(at)")
        case .weekly:
            if rule.weekdays == [0, 6] { return String(localized: "Weekends at \(at)") }
            if rule.weekdays.count == 1, let day = rule.weekdays.first { return String(localized: "Every \(longDays[day]) at \(at)") }
            let names = ScheduleRule.weekOrder.filter(rule.weekdays.contains).map { shortDays[$0] }
            return String(localized: "\(names.joined(separator: ", ")) at \(at)")
        case .hourly:
            let base = rule.everyHours == 1 ? String(localized: "Every hour") : String(localized: "Every \(rule.everyHours) h")
            return rule.minute == 0 ? base : String(localized: "\(base), at :\(String(format: "%02d", rule.minute))")
        case .once, .custom:
            let fields = (schedule.expr ?? "").split(whereSeparator: \.isWhitespace)
            if fields.count == 5, fields[0].hasPrefix("*/"), let step = Int(fields[0].dropFirst(2)), fields[1...].allSatisfy({ $0 == "*" }) {
                return step == 1 ? String(localized: "Every minute") : String(localized: "Every \(step) min")
            }
            return String(localized: "Cron \(schedule.expr ?? "")")
        }
    }

    static func dayMonth(_ date: Date) -> String {
        let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        let style = Date.FormatStyle(locale: locale).day().month(.abbreviated)
        return sameYear ? date.formatted(style) : date.formatted(style.year())
    }

    static func nextRun(_ schedule: TaskSchedule, after date: Date) -> Date? {
        if schedule.kind == "once" { return schedule.at.flatMap { $0 > date ? $0 : nil } }
        guard let expr = schedule.expr, let spec = CronSpec(expr) else { return nil }
        return spec.next(after: date, timeZone: TimeZone(identifier: schedule.timezone ?? ScheduleRule.defaultTimeZone) ?? .current)
    }

    /// "in 25 min", "in 3 h", "tomorrow at 7:00", "Monday at 8:00", "on Oct 20".
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let interval = date.timeIntervalSince(now)
        if interval < 60 { return String(localized: "imminent") }
        if interval < 3600 { return String(localized: "in \(Int((interval / 60).rounded(.up))) min") }
        if interval < 12 * 3600 { return String(localized: "in \(Int((interval / 3600).rounded())) h") }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(localized: "at \(time(date))") }
        if calendar.isDateInTomorrow(date) { return String(localized: "tomorrow at \(time(date))") }
        if interval < 6 * 86400 {
            let weekday = calendar.component(.weekday, from: date) - 1
            return String(localized: "\(longDays[weekday]) at \(time(date))")
        }
        return String(localized: "on \(dayMonth(date))")
    }

    /// "in 25 min", "in 5 h", "in 2 d".
    static func countdown(_ date: Date, now: Date = Date()) -> String {
        let interval = date.timeIntervalSince(now)
        if interval < 60 { return String(localized: "imminent") }
        if interval < 3600 { return String(localized: "in \(Int((interval / 60).rounded(.up))) min") }
        if interval < 36 * 3600 { return String(localized: "in \(Int((interval / 3600).rounded())) h") }
        return String(localized: "in \(Int((interval / 86400).rounded())) d")
    }

    /// "Today · 7:00", "Yesterday · 21:00", "Mon, Oct 13 · 8:00".
    static func runDate(_ date: Date) -> String {
        let calendar = Calendar.current
        let day: String
        if calendar.isDateInToday(date) {
            day = String(localized: "Today")
        } else if calendar.isDateInYesterday(date) {
            day = String(localized: "Yesterday")
        } else {
            day = date.formatted(Date.FormatStyle(locale: locale).weekday(.abbreviated).day().month(.abbreviated))
        }
        return "\(day) · \(time(date))"
    }
}

/// Weekday names for recurrence texts, indexed like cron (0 = Sunday).
enum WeekdayNames {
    static var long: [String] { [String(localized: "repeat.day.long.0", defaultValue: "Sunday"), String(localized: "repeat.day.long.1", defaultValue: "Monday"), String(localized: "repeat.day.long.2", defaultValue: "Tuesday"), String(localized: "repeat.day.long.3", defaultValue: "Wednesday"), String(localized: "repeat.day.long.4", defaultValue: "Thursday"), String(localized: "repeat.day.long.5", defaultValue: "Friday"), String(localized: "repeat.day.long.6", defaultValue: "Saturday")] }
}
