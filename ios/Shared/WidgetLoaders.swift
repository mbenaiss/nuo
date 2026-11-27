import Foundation
import WidgetKit

struct AgendaEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetAgendaSnapshot
}

struct RemindersEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetRemindersSnapshot
    var scope: ReminderWidgetScope = .todayAndUpcoming
}

/// Last good snapshot of each widget, so an unreachable gateway shows stale data (marked offline) instead of nothing.
enum WidgetCache {
    private static func url(_ name: String) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("widget-\(name).json")
    }

    static func save<T: Encodable>(_ value: T, as name: String) {
        guard let url = url(name), let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load<T: Decodable>(_ type: T.Type, name: String) -> T? {
        guard let url = url(name), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

enum AgendaLoader {
    static let refreshInterval: TimeInterval = 30 * 60

    /// Today and tomorrow by default; `month` loads the whole grid of the current month for the month widget.
    static func load(gateway: WidgetGateway?, month: Bool = false) async -> WidgetAgendaSnapshot {
        guard let gateway else { return .signedOut }
        let (start, end) = month ? WidgetMonth.range(containing: .now) : today()
        let name = month ? "agenda-month" : "agenda"
        do {
            let snapshot = WidgetAgendaSnapshot(status: .ready, items: try await gateway.agenda(from: start, to: end), fetchedAt: .now)
            WidgetCache.save(snapshot, as: name)
            return snapshot
        } catch WidgetGateway.Failure.unauthorized {
            return .signedOut
        } catch {
            var cached = WidgetCache.load(WidgetAgendaSnapshot.self, name: name) ?? WidgetAgendaSnapshot(status: .offline, items: [], fetchedAt: .now)
            cached.status = .offline
            return cached
        }
    }

    private static func today() -> (Date, Date) {
        let start = Calendar.current.startOfDay(for: .now)
        return (start, Calendar.current.date(byAdding: .day, value: 2, to: start) ?? start.addingTimeInterval(2 * 86400))
    }

    /// One entry now and one at every start or end of the coming hours, so « next » moves on by itself.
    static func timeline(_ snapshot: WidgetAgendaSnapshot) -> Timeline<AgendaEntry> {
        let now = Date.now
        let points = (snapshot.changePoints(after: now) + [WidgetMonth.nextMidnight(after: now)]).sorted()
        let entries = [AgendaEntry(date: now, snapshot: snapshot)] + points.prefix(20).map { AgendaEntry(date: $0, snapshot: snapshot) }
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(refreshInterval)))
    }
}

enum RemindersLoader {
    static func load(gateway: WidgetGateway?) async -> WidgetRemindersSnapshot {
        guard let gateway else { return .signedOut }
        do {
            let snapshot = WidgetRemindersSnapshot(status: .ready, items: try await gateway.reminders(), fetchedAt: .now)
            WidgetCache.save(snapshot, as: "reminders")
            return snapshot
        } catch WidgetGateway.Failure.unauthorized {
            return .signedOut
        } catch {
            var cached = WidgetCache.load(WidgetRemindersSnapshot.self, name: "reminders")
                ?? WidgetRemindersSnapshot(status: .offline, items: [], fetchedAt: .now)
            cached.status = .offline
            return cached
        }
    }

    /// Hides a reminder right away after a tap on its circle, before the gateway answers.
    static func markDone(_ id: String) {
        guard var cached = WidgetCache.load(WidgetRemindersSnapshot.self, name: "reminders") else { return }
        cached.items.removeAll { $0.id == id }
        WidgetCache.save(cached, as: "reminders")
    }

    /// Redraws when a reminder becomes overdue and at midnight, when « today » changes.
    static func timeline(_ snapshot: WidgetRemindersSnapshot, scope: ReminderWidgetScope = .todayAndUpcoming) -> Timeline<RemindersEntry> {
        let now = Date.now
        let horizon = now.addingTimeInterval(12 * 3600)
        let points = (snapshot.items.compactMap(\.effectiveDate).filter { $0 > now && $0 < horizon } + [WidgetMonth.nextMidnight(after: now)])
        let entries = [RemindersEntry(date: now, snapshot: snapshot, scope: scope)]
            + Set(points).sorted().prefix(20).map { RemindersEntry(date: $0, snapshot: snapshot, scope: scope) }
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(AgendaLoader.refreshInterval)))
    }
}

/// The 6-week grid of a month, weeks starting on Monday.
enum WidgetMonth {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = AgendaWidgetText.locale
        calendar.firstWeekday = 2
        calendar.timeZone = .current
        return calendar
    }

    static func nextMidnight(after date: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: date)) ?? date.addingTimeInterval(86400)
    }

    /// Days shown for the month of `date`: whole weeks, from the Monday before the 1st to the Sunday after the last day.
    static func days(containing date: Date) -> [Date] {
        let calendar = calendar
        guard let month = calendar.dateInterval(of: .month, for: date),
              let first = calendar.dateInterval(of: .weekOfYear, for: month.start)?.start,
              let last = calendar.dateInterval(of: .weekOfYear, for: month.end.addingTimeInterval(-1))?.end
        else { return [] }
        var days: [Date] = []
        var day = first
        while day < last {
            days.append(day)
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? last
        }
        return days
    }

    static func range(containing date: Date) -> (Date, Date) {
        let days = days(containing: date)
        let start = days.first ?? Calendar.current.startOfDay(for: date)
        let end = days.last.flatMap { Calendar.current.date(byAdding: .day, value: 1, to: $0) } ?? start.addingTimeInterval(42 * 86400)
        return (start, end)
    }
}
