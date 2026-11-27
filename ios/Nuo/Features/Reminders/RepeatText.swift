import Foundation

/// Wording of a reminder's `repeat`.
enum RepeatText {
    private static var longDays: [String] { WeekdayNames.long }
    private static var shortDays: [String] { [String(localized: "reminder.day.short.0", defaultValue: "Sun"), String(localized: "reminder.day.short.1", defaultValue: "Mon"), String(localized: "reminder.day.short.2", defaultValue: "Tue"), String(localized: "reminder.day.short.3", defaultValue: "Wed"), String(localized: "reminder.day.short.4", defaultValue: "Thu"), String(localized: "reminder.day.short.5", defaultValue: "Fri"), String(localized: "reminder.day.short.6", defaultValue: "Sat")] }

    /// The French wording keeps its historical space-separated abbreviations; other languages read better with commas.
    private static var daySeparator: String { Bundle.main.preferredLocalizations.first == "fr" ? " " : ", " }

    static func describe(_ rule: String) -> String {
        switch rule {
        case "daily": return String(localized: "Every day")
        case "weekly": return String(localized: "Every week")
        case "monthly": return String(localized: "Every month")
        case "yearly": return String(localized: "Every year")
        default: break
        }
        let fields = rule.split(separator: " ").map(String.init)
        guard fields.count == 5, let minute = Int(fields[0]), let hour = Int(fields[1]) else { return String(localized: "Recurring") }
        let at = ScheduleText.time(hour: hour, minute: minute)
        switch (fields[2], fields[3], fields[4]) {
        case ("*", "*", "*"): return String(localized: "Every day at \(at)")
        case ("*", "*", "1-5"), ("*", "*", "1,2,3,4,5"): return String(localized: "Weekdays at \(at)")
        case let ("*", "*", days):
            let list = days.split(separator: ",").compactMap { Int($0) }.map { $0 % 7 }
            if list.count == 1 { return String(localized: "Every \(longDays[list[0]]) at \(at)") }
            return String(localized: "On \(list.map { shortDays[$0] }.joined(separator: daySeparator)) at \(at)")
        case let (day, "*", "*"):
            return String(localized: "On day \(day == "1" ? String(localized: "repeat.firstDay", defaultValue: "1") : day) of each month at \(at)")
        case let (day, month, "*"):
            if let m = Int(month), (1...12).contains(m) {
                return String(localized: "Every year on \(Calendar.current.monthSymbols[m - 1]) \(day == "1" ? String(localized: "repeat.firstDay", defaultValue: "1") : day)")
            }
            return String(localized: "Yearly")
        default:
            return String(localized: "Recurring")
        }
    }

    static func short(_ rule: String) -> String {
        switch rule {
        case "daily": return String(localized: "Daily")
        case "weekly": return String(localized: "Weekly")
        case "monthly": return String(localized: "Monthly")
        case "yearly": return String(localized: "Yearly")
        default: return describe(rule).replacingOccurrences(of: #" (?:à|at) \d{1,2}:\d{2}"#, with: "", options: .regularExpression)
        }
    }
}
