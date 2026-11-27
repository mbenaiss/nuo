import Foundation

/// The fields of a reminder the extensions show (`GET /api/reminders`).
struct ReminderWireItem: Codable, Hashable, Sendable, Identifiable {
    struct Place: Codable, Hashable, Sendable { var name: String }
    struct Ref: Codable, Hashable, Sendable { var title: String; var emoji: String? }

    var id: String
    var title: String
    var dueAt: Date?
    var snoozedUntil: Date?
    var list: String
    var priority: Int
    var doneAt: Date?
    var place: Place?
    var placeTrigger: String?
    var project: Ref?
    var area: Ref?

    /// Where it is filed, like Things' caption: the project, else the area.
    var filedUnder: String? { (project ?? area).map(\.title) }

    var effectiveDate: Date? {
        if let snoozedUntil, snoozedUntil > (dueAt ?? .distantPast) { return snoozedUntil }
        return dueAt
    }

    var link: URL { URL(string: "nuo://reminders/\(id)")! }

    var placeText: String? {
        place.map { placeTrigger == "leave" ? String(localized: "When leaving \($0.name)") : String(localized: "When arriving at \($0.name)") }
    }
}

/// What the home reminders widget lists: today's alone, or today's then the coming ones to fill the space.
enum ReminderWidgetScope: String, CaseIterable, Codable, Hashable, Sendable {
    case today, todayAndUpcoming
}

/// What the reminders widgets show: open reminders, today's (overdue included) first.
struct WidgetRemindersSnapshot: Codable, Hashable, Sendable {
    enum Status: String, Codable, Sendable { case ready, signedOut, offline }

    var status: Status
    var items: [ReminderWireItem]
    var fetchedAt: Date

    static let signedOut = WidgetRemindersSnapshot(status: .signedOut, items: [], fetchedAt: .now)

    private func endOfDay(_ date: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date.addingTimeInterval(86400)
    }

    /// Due before midnight (overdue ones first, as they are the oldest), like the app's « Aujourd'hui » list.
    func today(at date: Date, calendar: Calendar = .current) -> [ReminderWireItem] {
        let end = endOfDay(date, calendar: calendar)
        return open.filter { ($0.effectiveDate ?? .distantFuture) < end }
    }

    func overdue(at date: Date) -> [ReminderWireItem] {
        open.filter { ($0.effectiveDate ?? .distantFuture) < date }
    }

    func upcoming(at date: Date, scope: ReminderWidgetScope = .todayAndUpcoming, calendar: Calendar = .current) -> [ReminderWireItem] {
        guard scope == .todayAndUpcoming else { return [] }
        let end = endOfDay(date, calendar: calendar)
        return open.filter { ($0.effectiveDate.map { $0 >= end }) ?? false }
    }

    func visible(at date: Date, limit: Int, scope: ReminderWidgetScope = .todayAndUpcoming, calendar: Calendar = .current) -> [ReminderWireItem] {
        Array((today(at: date, calendar: calendar) + upcoming(at: date, scope: scope, calendar: calendar)).prefix(limit))
    }

    private var open: [ReminderWireItem] {
        items.filter { $0.doneAt == nil }.sorted { ($0.effectiveDate ?? .distantFuture, -$0.priority) < ($1.effectiveDate ?? .distantFuture, -$1.priority) }
    }
}

extension WidgetRemindersSnapshot {
    static var demo: WidgetRemindersSnapshot {
        let now = Date.now
        let calendar = Calendar.current
        func at(_ day: Int, _ hour: Int) -> Date {
            calendar.date(bySettingHour: hour, minute: 0, second: 0, of: calendar.date(byAdding: .day, value: day, to: now)!)!
        }
        let items = [
            ReminderWireItem(id: "r1", title: String(localized: "Send the Helio Labs invoice"), dueAt: at(-1, 18), list: "inbox", priority: 2, project: .init(title: String(localized: "Quarter close"))),
            ReminderWireItem(id: "r2", title: String(localized: "Pay the quarterly taxes"), dueAt: now.addingTimeInterval(2 * 3600), list: String(localized: "Admin"), priority: 1),
            ReminderWireItem(id: "r3", title: String(localized: "Buy milk"), dueAt: at(0, 20), list: String(localized: "Groceries"), priority: 0, place: .init(name: "Cornerstore Market"), placeTrigger: "arrive"),
            ReminderWireItem(id: "r4", title: String(localized: "Call the garage"), dueAt: at(0, 23), list: String(localized: "Personal"), priority: 0),
            ReminderWireItem(id: "r5", title: String(localized: "Plan the long run"), dueAt: at(1, 7), list: String(localized: "Sport"), priority: 0),
            ReminderWireItem(id: "r6", title: String(localized: "Renew the insurance"), dueAt: at(3, 10), list: String(localized: "Admin"), priority: 1),
            ReminderWireItem(id: "r7", title: String(localized: "Book a dentist appointment"), dueAt: at(5, 9), list: String(localized: "Personal"), priority: 0),
        ]
        return WidgetRemindersSnapshot(status: .ready, items: items, fetchedAt: now)
    }
}
