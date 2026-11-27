import SwiftUI

/// Week starts on Monday whatever the region.
enum AgendaCalendar {
    static var current: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        calendar.locale = .current
        return calendar
    }

    static func startOfWeek(_ date: Date) -> Date {
        let calendar = current
        return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    static func startOfMonth(_ date: Date) -> Date {
        current.dateInterval(of: .month, for: date)?.start ?? current.startOfDay(for: date)
    }

    static func days(from start: Date, count: Int) -> [Date] {
        let calendar = current
        let first = calendar.startOfDay(for: start)
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
    }

    static func add(_ days: Int, to date: Date) -> Date {
        current.date(byAdding: .day, value: days, to: date) ?? date
    }

    /// Six rows of seven days covering the month of `date`, Monday first.
    static func monthGrid(_ date: Date) -> [Date] {
        days(from: startOfWeek(startOfMonth(date)), count: 42)
    }

    /// The span `monthGrid` shows, leading and trailing days included.
    static func monthGridInterval(_ date: Date) -> DateInterval {
        let first = startOfWeek(startOfMonth(date))
        return DateInterval(start: first, end: add(42, to: first))
    }

    /// Minutes since midnight, for placing an event in a time grid.
    static func minutes(_ date: Date) -> Double {
        let parts = current.dateComponents([.hour, .minute], from: date)
        return Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
    }
}

enum AgendaText {
    static func time(_ date: Date) -> String { ScheduleText.time(date) }

    static func range(_ item: AgendaItem) -> String {
        if item.allDay { return String(localized: "All day") }
        if item.kind == .reminder { return time(item.start) }
        return "\(time(item.start)) – \(time(item.end))"
    }

    /// "1 h", "45 min", "1 h 30".
    static func duration(_ interval: TimeInterval) -> String {
        let minutes = Int((interval / 60).rounded())
        if minutes < 60 { return String(localized: "\(minutes) min") }
        let hours = minutes / 60, rest = minutes % 60
        if hours >= 24, rest == 0, hours % 24 == 0 { return String(localized: "\(hours / 24) days") }
        return rest == 0 ? String(localized: "\(hours) h") : String(localized: "\(hours) h \(String(format: "%02d", rest))")
    }

    /// "Today", "Tomorrow", "Thursday, October 23".
    static func dayTitle(_ day: Date) -> String {
        let calendar = AgendaCalendar.current
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInTomorrow(day) { return String(localized: "Tomorrow") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
        return capitalized(day.formatted(Date.FormatStyle(locale: .current).weekday(.wide).day().month(.wide)))
    }

    /// Secondary line next to a relative title: "Thursday, October 23".
    static func daySubtitle(_ day: Date) -> String? {
        let calendar = AgendaCalendar.current
        guard calendar.isDateInToday(day) || calendar.isDateInTomorrow(day) || calendar.isDateInYesterday(day) else { return nil }
        return day.formatted(Date.FormatStyle(locale: .current).weekday(.wide).day().month(.wide))
    }

    static func monthTitle(_ date: Date) -> String {
        capitalized(date.formatted(Date.FormatStyle(locale: .current).month(.wide).year()))
    }

    static func shortDay(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: .current).weekday(.abbreviated).day().month(.abbreviated))
    }

    /// "Mon" → "M", for the day strip and the mini month.
    static func weekdayLetter(_ date: Date) -> String {
        String(date.formatted(Date.FormatStyle(locale: .current).weekday(.narrow))).uppercased()
    }

    static func weekdayShort(_ date: Date) -> String {
        capitalized(date.formatted(Date.FormatStyle(locale: .current).weekday(.abbreviated)))
    }

    static func capitalized(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }

    /// "Google Meet", "Zoom"… from a conference link.
    static func conferenceName(_ url: String) -> String {
        let host = URL(string: url)?.host()?.lowercased() ?? url.lowercased()
        if host.contains("meet.google") { return "Google Meet" }
        if host.contains("zoom") { return "Zoom" }
        if host.contains("teams") { return "Teams" }
        if host.contains("webex") { return "Webex" }
        if host.contains("whereby") { return "Whereby" }
        if host.contains("jit.si") { return "Jitsi" }
        return String(localized: "Video call")
    }

    static func travel(_ seconds: Int) -> String { String(localized: "\(duration(TimeInterval(seconds))) travel") }

    static func alarm(_ minutes: Int) -> String {
        switch minutes {
        case 0: String(localized: "At time of event")
        case 1440: String(localized: "The day before")
        default: String(localized: "\(duration(TimeInterval(minutes * 60))) before")
        }
    }

    static func attendeeStatus(_ status: String) -> (label: String, symbol: String, color: Color) {
        switch status {
        case "accepted": (String(localized: "Accepted"), "checkmark.circle.fill", Color.good)
        case "declined": (String(localized: "Declined"), "xmark.circle.fill", Color.bad)
        case "tentative": (String(localized: "Maybe"), "questionmark.circle.fill", Color(hex: 0xF59E0B))
        default: (String(localized: "Awaiting reply"), "clock", Color.text3)
        }
    }
}

extension AgendaItem {
    var tint: Color {
        if kind == .reminder { return (priority ?? 0) > 0 ? ReminderStyle.priorityColor(priority ?? 0) : Color.accent }
        if kind == .booking { return Color.accent }
        return color.flatMap(Color.init(hexString:)) ?? Color.text2
    }

    /// Days the item covers, start of day each; an all-day end is exclusive.
    var days: [Date] {
        let calendar = AgendaCalendar.current
        let first = calendar.startOfDay(for: start)
        var last = calendar.startOfDay(for: end)
        if allDay || (end > start && end == last) { last = calendar.date(byAdding: .day, value: -1, to: last) ?? last }
        if last < first { return [first] }
        var result: [Date] = []
        var day = first
        while day <= last, result.count < 62 {
            result.append(day)
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400)
        }
        return result
    }

    var spansDays: Bool { days.count > 1 }

    var conference: URL? { conferenceUrl.flatMap(URL.init(string:)) }
}

/// Diagonal stripes for busy-only events (“Busy”).
struct HatchPattern: View {
    var color: Color
    var spacing: CGFloat = CalendarMetrics.hatchSpacing

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += spacing
            }
            context.stroke(path, with: .color(color), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

/// Fill of an event block: soft calendar tint, hatched when only “Busy” is known, faded when free or cancelled.
struct EventFill: View {
    let item: AgendaItem

    var body: some View {
        ZStack {
            if item.isBusyOnly {
                Color.chip
                HatchPattern(color: item.tint.opacity(0.35))
            } else {
                item.tint.opacity(item.isFree || item.status == "tentative" ? 0.1 : 0.18)
            }
        }
    }
}

/// A calendar color dot (settings, pickers, chips).
struct CalendarDot: View {
    let color: Color
    var size: CGFloat = 10

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

extension EventDraft {
    /// A new event on `day`: the next half hour today, 9:00 on another day.
    static func blank(on day: Date, calendarId: String?) -> EventDraft {
        let calendar = AgendaCalendar.current
        let start = calendar.isDateInToday(day)
            ? EventParser.nextHalfHour(after: Date(), calendar: calendar)
            : calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
        let end = start.addingTimeInterval(TimeInterval(CalendarMetrics.defaultDurationMinutes * 60))
        return EventDraft(title: "", start: start, end: end, calendarId: calendarId)
    }
}
