import Foundation

/// Clock-face arithmetic for the agenda. A day is not always 24 hours (daylight saving), so grid positions,
/// day shifts and all-day ends go through `Calendar` rather than multiples of 86 400 s.
enum WallClock {
    /// Minutes on the clock face between the start of `day` and `date`, clamped to the day (0…1440).
    static func minutes(of date: Date, on day: Date, calendar: Calendar) -> Double {
        let start = calendar.startOfDay(for: day)
        guard date > start else { return 0 }
        guard let next = calendar.date(byAdding: .day, value: 1, to: start), date < next else { return 1440 }
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) + Double(parts.second ?? 0) / 60
    }

    /// The instant shown at `minutes` past midnight on `day`; 1440 is the next midnight.
    static func date(on day: Date, minutes: Double, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: day)
        let whole = Int(minutes.rounded())
        let days = whole / 1440, rest = whole % 1440
        let base = days == 0 ? start : (calendar.date(byAdding: .day, value: days, to: start) ?? start)
        return calendar.date(bySettingHour: rest / 60, minute: rest % 60, second: 0, of: base)
            ?? base.addingTimeInterval(Double(rest) * 60)
    }

    /// `date` moved by whole days (same clock time) and then by `minutes`.
    static func shift(_ date: Date, days: Int, minutes: Double, calendar: Calendar) -> Date {
        let moved = days == 0 ? date : (calendar.date(byAdding: .day, value: days, to: date) ?? date)
        return moved.addingTimeInterval(minutes * 60)
    }

    /// The weekday of `date`, 0 = Sunday … 6 = Saturday (`EventRecurrence.weekly`).
    static func weekday(_ date: Date, calendar: Calendar) -> Int {
        calendar.component(.weekday, from: date) - 1
    }

    /// A weekly repetition on the start's own weekday follows the start to its new day; one picked on other days stays.
    static func weekdays(_ days: [Int], movingFrom oldStart: Date, to newStart: Date, calendar: Calendar) -> [Int] {
        let old = weekday(oldStart, calendar: calendar)
        guard days == [old] else { return days }
        return [weekday(newStart, calendar: calendar)]
    }

    /// An all-day end is stored exclusive (next midnight) and shown inclusive (the last day).
    static func inclusiveDay(fromExclusiveEnd end: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: end)) ?? end
    }

    static func exclusiveEnd(fromInclusiveDay day: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: day)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? start
    }

    /// Moving an event's start keeps its length: the same number of days for an all-day event, else the same duration.
    static func end(keeping oldStart: Date, _ oldEnd: Date, newStart: Date, allDay: Bool, minimum: TimeInterval, calendar: Calendar) -> Date {
        if allDay {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: oldStart), to: calendar.startOfDay(for: oldEnd)).day ?? 1
            return calendar.date(byAdding: .day, value: max(1, days), to: calendar.startOfDay(for: newStart)) ?? newStart
        }
        return newStart.addingTimeInterval(max(oldEnd.timeIntervalSince(oldStart), minimum))
    }
}
