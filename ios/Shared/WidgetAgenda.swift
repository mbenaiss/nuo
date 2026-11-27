import Foundation

/// What the agenda widgets show: the coming events and reminders of the next two days.
struct WidgetAgendaSnapshot: Codable, Hashable, Sendable {
    enum Status: String, Codable, Sendable { case ready, signedOut, offline }

    var status: Status
    var items: [AgendaWireItem]
    var fetchedAt: Date

    static let signedOut = WidgetAgendaSnapshot(status: .signedOut, items: [], fetchedAt: .now)

    /// Timed items not over yet (soonest first); all-day items of the day come after.
    func upcoming(at date: Date, limit: Int) -> [AgendaWireItem] {
        let timed = items.filter { !$0.allDay && $0.end > date && $0.status != "cancelled" && !($0.kind == "reminder" && $0.done == true) }
            .sorted { $0.start < $1.start }
        return Array(timed.prefix(limit))
    }

    func allDay(on date: Date) -> [AgendaWireItem] {
        items.filter { $0.allDay && $0.start <= date && $0.end > date }
    }

    /// Everything that touches `day`: all-day items first, then timed ones by start, without those already over.
    func items(on day: Date, now: Date) -> [AgendaWireItem] {
        let start = Calendar.current.startOfDay(for: day)
        let end = WidgetMonth.nextMidnight(after: start)
        let visible = items.filter {
            $0.start < end && max($0.end, $0.start.addingTimeInterval(1)) > start && $0.status != "cancelled"
                && !($0.kind == "reminder" && $0.done == true)
        }
        let timed = visible.filter { !$0.allDay && ($0.kind == "reminder" || $0.end > now) }.sorted { $0.start < $1.start }
        return visible.filter(\.allDay) + timed
    }

    /// Calendar colours of the events on `day`, one per calendar, for the month grid's dots.
    func colors(on day: Date) -> [String] {
        let start = Calendar.current.startOfDay(for: day)
        let end = WidgetMonth.nextMidnight(after: start)
        var seen: [String] = []
        for item in items where item.kind == "event" && item.status != "cancelled" && item.start < end && item.end > start {
            let color = item.color ?? "#8E8E93"
            if !seen.contains(color) { seen.append(color) }
        }
        return seen
    }

    /// Moments the widget must redraw: each start and end in the next hours.
    func changePoints(after date: Date) -> [Date] {
        let horizon = date.addingTimeInterval(12 * 3600)
        return Set(items.flatMap { [$0.start, $0.end] }.filter { $0 > date && $0 < horizon }).sorted()
    }
}

extension AgendaWireItem {
    var displayTitle: String {
        if busyOnly == true { return String(localized: "Busy") }
        return title?.isEmpty == false ? title! : String(localized: "Untitled")
    }

    var link: URL { URL(string: "nuo://calendar/\(id)")! }
    var conference: URL? { conferenceUrl.flatMap(URL.init(string:)) }

    /// "Leave around 13:30": start minus travel time minus the app's "Leave now" margin.
    var departure: Date? {
        guard let travel = travelTimeSec, travel > 0, !allDay else { return nil }
        let margin = UserDefaults(suiteName: AppIdentity.appGroup)?.object(forKey: "nuo.leave.marginMin") as? Int ?? 5
        return start.addingTimeInterval(-TimeInterval(travel + margin * 60))
    }
}

enum AgendaWidgetText {
    static var locale: Locale { .current }

    static func time(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return "\(parts.hour ?? 0):\(String(format: "%02d", parts.minute ?? 0))"
    }

    static func range(_ item: AgendaWireItem) -> String {
        if item.allDay { return String(localized: "All day") }
        if item.kind == "reminder" { return time(item.start) }
        return "\(time(item.start)) – \(time(item.end))"
    }

    /// "Now", "In 25 min", "In 2 h", "Tomorrow 9:00".
    static func relative(_ item: AgendaWireItem, now: Date) -> String {
        if item.start <= now { return String(localized: "Now") }
        let minutes = Int(item.start.timeIntervalSince(now) / 60)
        if minutes < 60 { return String(localized: "In \(max(minutes, 1)) min") }
        if Calendar.current.isDateInToday(item.start) {
            let hours = minutes / 60, rest = minutes % 60
            return rest == 0 || hours >= 3 ? String(localized: "In \(hours) h") : String(localized: "In \(hours) h \(String(format: "%02d", rest))")
        }
        if Calendar.current.isDateInTomorrow(item.start) { return String(localized: "Tomorrow \(time(item.start))") }
        return item.start.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(locale))
    }

    static func day(_ date: Date) -> String {
        let text = date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated).locale(locale))
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

extension WidgetAgendaSnapshot {
    /// Realistic data for widget placeholders, the gallery and debug renders.
    static var demo: WidgetAgendaSnapshot {
        let calendar = Calendar.current
        let now = Date.now
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: calendar.date(byAdding: .day, value: day, to: now)!)!
        }
        let soon = calendar.date(byAdding: .minute, value: 25, to: now)!
        let items = [
            AgendaWireItem(kind: "event", id: "w1", title: String(localized: "Team lunch"), location: String(localized: "Corner Bistro"), start: soon,
                           end: soon.addingTimeInterval(75 * 60), allDay: false, color: "#34A853", travelTimeSec: 600),
            AgendaWireItem(kind: "event", id: "w2", title: nil, start: soon.addingTimeInterval(105 * 60), end: soon.addingTimeInterval(195 * 60),
                           allDay: false, color: "#A855F7", busyOnly: true),
            AgendaWireItem(kind: "event", id: "w3", title: String(localized: "Call with the accountant"), conferenceUrl: "https://meet.google.com/fhw-pzkn-yte",
                           start: soon.addingTimeInterval(270 * 60), end: soon.addingTimeInterval(300 * 60), allDay: false, color: "#3B82F6"),
            AgendaWireItem(kind: "reminder", id: "w4", title: String(localized: "Pay the quarterly taxes"), start: soon.addingTimeInterval(330 * 60),
                           end: soon.addingTimeInterval(330 * 60), allDay: false, done: false),
            AgendaWireItem(kind: "event", id: "w5", title: String(localized: "Nuo design workshop"), location: String(localized: "Studio Nord"), start: at(1, 10), end: at(1, 12),
                           allDay: false, color: "#3B82F6"),
        ]
        return WidgetAgendaSnapshot(status: .ready, items: items, fetchedAt: now)
    }
}

#if os(iOS)
import SwiftUI
import WidgetKit

extension AgendaWireItem {
    var tint: Color {
        if kind == "reminder" { return WPalette.accent }
        guard var text = color else { return WPalette.text2 }
        if text.hasPrefix("#") { text.removeFirst() }
        guard let value = UInt32(text, radix: 16) else { return WPalette.text2 }
        return WPalette.rgb(value)
    }
}

/// Small: the next item, how soon, where, and "Join".
struct WidgetAgendaNextView: View {
    let snapshot: WidgetAgendaSnapshot
    let date: Date

    var body: some View {
        if snapshot.status == .signedOut {
            WidgetSignedOutView(compact: true)
        } else if let item = snapshot.upcoming(at: date, limit: 1).first {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(AgendaWidgetText.relative(item, now: date).uppercased())
                        .font(.caption2.weight(.bold))
                        .tracking(0.5)
                        .foregroundStyle(item.start <= date ? WPalette.accent : WPalette.text3)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 6)
                HStack(alignment: .top, spacing: 7) {
                    RoundedRectangle(cornerRadius: 2).fill(item.tint).frame(width: 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.displayTitle)
                            .font(.headline)
                            .foregroundStyle(WPalette.ink)
                            .lineLimit(3)
                            .minimumScaleFactor(0.85)
                        Text(AgendaWidgetText.range(item))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(WPalette.text2)
                        if let departure = item.departure, item.start > date {
                            Label("Leave around \(AgendaWidgetText.time(departure))", systemImage: "car.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(departure <= date ? WPalette.accent : WPalette.text2)
                                .lineLimit(1)
                        }
                        if let location = item.location {
                            Text(location).font(.caption).foregroundStyle(WPalette.text3).lineLimit(1)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                if let conference = item.conference {
                    Link(destination: conference) {
                        Label("Join", systemImage: "video.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(WPalette.rgb(0x1A73E8), in: Capsule())
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .widgetURL(item.link)
        } else {
            WidgetAgendaEmpty(compact: true)
        }
    }
}

/// Medium: today's date and the next three items.
struct WidgetAgendaListView: View {
    let snapshot: WidgetAgendaSnapshot
    let date: Date

    var body: some View {
        if snapshot.status == .signedOut {
            WidgetSignedOutView()
        } else {
            let items = snapshot.upcoming(at: date, limit: 3)
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(date.formatted(.dateTime.weekday(.abbreviated).locale(AgendaWidgetText.locale)).uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(WPalette.accent)
                    Text("\(Calendar.current.component(.day, from: date))")
                        .font(.system(.largeTitle, design: .rounded).weight(.semibold).monospacedDigit())
                        .foregroundStyle(WPalette.ink)
                    Spacer(minLength: 0)
                    if let first = snapshot.allDay(on: date).first {
                        Text(first.displayTitle)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(WPalette.text2)
                            .lineLimit(2)
                    }
                }
                .frame(width: 64, alignment: .leading)
                VStack(alignment: .leading, spacing: 8) {
                    if items.isEmpty {
                        WidgetAgendaEmpty(compact: false)
                    }
                    ForEach(items, id: \.id) { item in
                        Link(destination: item.link) { WidgetAgendaRow(item: item) }
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .widgetURL(URL(string: "nuo://calendar"))
        }
    }
}

/// One agenda line: colour bar, title, time and place, and a « Rejoindre » button for a video call.
struct WidgetAgendaRow: View {
    let item: AgendaWireItem

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            RoundedRectangle(cornerRadius: 2)
                .fill(item.busyOnly == true ? item.tint.opacity(0.5) : item.tint)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if item.kind == "reminder" { Image(systemName: "circle").font(.caption2.weight(.bold)).foregroundStyle(item.tint) }
                    Text(item.displayTitle)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(item.busyOnly == true ? WPalette.text2 : WPalette.ink)
                        .lineLimit(1)
                }
                HStack(spacing: 4) {
                    Text(AgendaWidgetText.range(item)).monospacedDigit()
                    if let location = item.location { Text("· \(location)").lineLimit(1) }
                }
                .font(.caption2)
                .foregroundStyle(WPalette.text2)
            }
            Spacer(minLength: 4)
            if let conference = item.conference {
                Link(destination: conference) {
                    Image(systemName: "video.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(WPalette.rgb(0x1A73E8), in: Circle())
                }
                .accessibilityLabel("Join")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct WidgetAgendaEmpty: View {
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            WidgetMascot(state: .idle, size: compact ? 40 : 48)
            Text("Nothing planned").font(compact ? .footnote.weight(.semibold) : .subheadline.weight(.semibold)).foregroundStyle(WPalette.ink)
            Text("Your calendar is clear for the next few hours.").font(.caption2).foregroundStyle(WPalette.text2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(URL(string: "nuo://calendar"))
    }
}

/// Lock screen, rectangular: next item, time and place.
struct WidgetAgendaRectangularView: View {
    let snapshot: WidgetAgendaSnapshot
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if snapshot.status == .signedOut {
                Text("Nuo").font(.headline)
                Text("Open Nuo to sign in").font(.caption).lineLimit(2)
            } else if let item = snapshot.upcoming(at: date, limit: 1).first {
                HStack(spacing: 4) {
                    Image(systemName: item.conference == nil ? "calendar" : "video.fill").font(.caption2.weight(.bold))
                    Text(AgendaWidgetText.relative(item, now: date)).font(.caption.weight(.semibold))
                }
                .widgetAccentable()
                Text(item.displayTitle).font(.headline).lineLimit(1)
                Text([AgendaWidgetText.range(item), item.location].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).lineLimit(1)
            } else {
                Label(String(localized: "widget.agenda", defaultValue: "Calendar"), systemImage: "calendar").font(.caption.weight(.semibold)).widgetAccentable()
                Text("Nothing planned").font(.headline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(snapshot.upcoming(at: date, limit: 1).first?.link ?? URL(string: "nuo://calendar"))
    }
}

/// Lock screen, inline: "13:00 · Team lunch".
struct WidgetAgendaInlineView: View {
    let snapshot: WidgetAgendaSnapshot
    let date: Date

    var body: some View {
        if let item = snapshot.upcoming(at: date, limit: 1).first {
            Label("\(AgendaWidgetText.time(item.start)) · \(item.displayTitle)", systemImage: "calendar")
        } else {
            Label("Nothing planned", systemImage: "calendar")
        }
    }
}
#endif
