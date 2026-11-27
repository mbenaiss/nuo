import Foundation

enum ReminderWidgetText {
    /// "9:00", "Yesterday", "Mon 14:00", or the place for a location reminder.
    static func due(_ item: ReminderWireItem, now: Date) -> String? {
        guard let date = item.effectiveDate else { return item.placeText }
        let calendar = Calendar.current
        let hasTime = calendar.dateComponents([.hour, .minute], from: date) != DateComponents(hour: 0, minute: 0)
        if calendar.isDateInToday(date) { return hasTime ? AgendaWidgetText.time(date) : String(localized: "Today") }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        if calendar.isDateInTomorrow(date) { return hasTime ? String(localized: "Tomorrow \(AgendaWidgetText.time(date))") : String(localized: "Tomorrow") }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        if (2...6).contains(days) {
            let weekday = date.formatted(.dateTime.weekday(.abbreviated).locale(AgendaWidgetText.locale)).capitalized
            return hasTime ? "\(weekday) \(AgendaWidgetText.time(date))" : weekday
        }
        return date.formatted(.dateTime.day().month(.abbreviated).locale(AgendaWidgetText.locale))
    }

    static func count(_ count: Int) -> String {
        count == 0 ? String(localized: "No reminders") : String(localized: "\(count) reminders")
    }
}
