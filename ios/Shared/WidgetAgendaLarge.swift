#if os(iOS)
import SwiftUI
import WidgetKit

/// Large: today's items, then tomorrow's, under the date.
struct WidgetAgendaDayView: View {
    let snapshot: WidgetAgendaSnapshot
    let date: Date
    var maxRows = 7

    var body: some View {
        if snapshot.status == .signedOut {
            WidgetSignedOutView()
        } else {
            let tomorrow = WidgetMonth.nextMidnight(after: date)
            let today = snapshot.items(on: date, now: date)
            let next = snapshot.items(on: tomorrow, now: date)
            let todayShown = Array(today.prefix(maxRows))
            let nextShown = Array(next.prefix(max(maxRows - todayShown.count - 1, 2)))
            VStack(alignment: .leading, spacing: 10) {
                WidgetAgendaHeader(date: date, offline: snapshot.status == .offline)
                if todayShown.isEmpty {
                    WidgetAgendaSectionTitle(text: String(localized: "Today"))
                    Text("Nothing planned").font(.footnote).foregroundStyle(WPalette.text2)
                } else {
                    WidgetAgendaSection(title: String(localized: "Today"), items: todayShown, hidden: today.count - todayShown.count)
                }
                if !nextShown.isEmpty {
                    WidgetAgendaSection(title: String(localized: "Tomorrow"), items: nextShown, hidden: next.count - nextShown.count)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .widgetURL(URL(string: "nuo://calendar"))
        }
    }
}

/// Extra large (iPad): today and tomorrow side by side.
struct WidgetAgendaTwoDaysView: View {
    let snapshot: WidgetAgendaSnapshot
    let date: Date

    var body: some View {
        if snapshot.status == .signedOut {
            WidgetSignedOutView()
        } else {
            let tomorrow = WidgetMonth.nextMidnight(after: date)
            VStack(alignment: .leading, spacing: 12) {
                WidgetAgendaHeader(date: date, offline: snapshot.status == .offline)
                HStack(alignment: .top, spacing: 20) {
                    column(String(localized: "Today"), snapshot.items(on: date, now: date))
                    column(String(localized: "Tomorrow"), snapshot.items(on: tomorrow, now: date))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .widgetURL(URL(string: "nuo://calendar"))
        }
    }

    private func column(_ title: String, _ items: [AgendaWireItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if items.isEmpty {
                WidgetAgendaSectionTitle(text: title)
                Text("Nothing planned").font(.footnote).foregroundStyle(WPalette.text2)
            } else {
                WidgetAgendaSection(title: title, items: Array(items.prefix(8)), hidden: max(items.count - 8, 0))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct WidgetAgendaHeader: View {
    let date: Date
    let offline: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("\(Calendar.current.component(.day, from: date))")
                .font(.system(.title, design: .rounded).weight(.semibold).monospacedDigit())
                .foregroundStyle(WPalette.accent)
            VStack(alignment: .leading, spacing: 0) {
                Text(date.formatted(.dateTime.weekday(.wide).locale(AgendaWidgetText.locale)).capitalized)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(WPalette.ink)
                Text(date.formatted(.dateTime.month(.wide).year().locale(AgendaWidgetText.locale)))
                    .font(.caption)
                    .foregroundStyle(WPalette.text2)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            if offline {
                Image(systemName: "wifi.slash").font(.caption2).foregroundStyle(WPalette.text3)
            }
        }
    }
}

private struct WidgetAgendaSectionTitle: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.bold))
            .tracking(0.5)
            .foregroundStyle(WPalette.text3)
    }
}

private struct WidgetAgendaSection: View {
    let title: String
    let items: [AgendaWireItem]
    let hidden: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            WidgetAgendaSectionTitle(text: title)
            ForEach(items, id: \.id) { item in
                Link(destination: item.link) { WidgetAgendaRow(item: item) }
            }
            if hidden > 0 {
                Text("+ \(hidden) more").font(.caption2.weight(.semibold)).foregroundStyle(WPalette.text3)
            }
        }
    }
}

// MARK: - Month

/// The month grid with today's items beside it (medium, extra large) or under it (large).
struct WidgetMonthView: View {
    let family: WidgetFamily
    let snapshot: WidgetAgendaSnapshot
    let date: Date

    var body: some View {
        if snapshot.status == .signedOut {
            WidgetSignedOutView()
        } else {
            Group {
                switch family {
                case .systemLarge:
                    VStack(alignment: .leading, spacing: 12) {
                        WidgetMonthGrid(snapshot: snapshot, date: date, dense: false)
                            .frame(height: 190)
                        Rectangle().fill(WPalette.line).frame(height: 1)
                        dayList(limit: 3)
                    }
                case .systemExtraLarge:
                    HStack(alignment: .top, spacing: 20) {
                        WidgetMonthGrid(snapshot: snapshot, date: date, dense: false)
                            .frame(maxWidth: .infinity)
                        dayList(limit: 8).frame(maxWidth: .infinity)
                    }
                default:
                    HStack(alignment: .top, spacing: 14) {
                        WidgetMonthGrid(snapshot: snapshot, date: date, dense: true)
                            .frame(width: 140)
                        dayList(limit: 3)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .widgetURL(URL(string: "nuo://calendar"))
        }
    }

    private func dayList(limit: Int) -> some View {
        let items = snapshot.items(on: date, now: date)
        return VStack(alignment: .leading, spacing: 7) {
            Text(AgendaWidgetText.day(date))
                .font(.caption.weight(.bold))
                .foregroundStyle(WPalette.accent)
                .lineLimit(1)
            if items.isEmpty {
                Text("Nothing planned today").font(.footnote).foregroundStyle(WPalette.text2)
            }
            ForEach(items.prefix(limit), id: \.id) { item in
                Link(destination: item.link) { WidgetAgendaRow(item: item) }
            }
            if items.count > limit {
                Text("+ \(items.count - limit) more")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(WPalette.text3)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct WidgetMonthGrid: View {
    let snapshot: WidgetAgendaSnapshot
    let date: Date
    let dense: Bool

    private static var weekdays: [String] {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        return Array(symbols.dropFirst()) + symbols.prefix(1)
    }

    var body: some View {
        let calendar = WidgetMonth.calendar
        let days = WidgetMonth.days(containing: date)
        let weeks = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
        let month = calendar.component(.month, from: date)
        GeometryReader { proxy in
            let titleHeight: CGFloat = dense ? 16 : 22
            let headerHeight: CGFloat = dense ? 12 : 16
            let cell = max((proxy.size.height - titleHeight - headerHeight) / CGFloat(max(weeks.count, 1)), 10)
            VStack(spacing: 0) {
                Text(date.formatted(.dateTime.month(.wide).locale(AgendaWidgetText.locale)).capitalized)
                    .font((dense ? Font.caption : .subheadline).weight(.bold))
                    .foregroundStyle(WPalette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: titleHeight, alignment: .top)
                HStack(spacing: 0) {
                    ForEach(Array(Self.weekdays.enumerated()), id: \.offset) { _, letter in
                        Text(letter).font(.system(size: dense ? 8 : 10, weight: .semibold)).foregroundStyle(WPalette.text3)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: headerHeight)
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    HStack(spacing: 0) {
                        ForEach(week, id: \.self) { day in
                            dayCell(day, inMonth: calendar.component(.month, from: day) == month, height: cell)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: cell)
                }
            }
        }
    }

    private func dayCell(_ day: Date, inMonth: Bool, height: CGFloat) -> some View {
        let isToday = Calendar.current.isDate(day, inSameDayAs: date)
        let colors = inMonth ? snapshot.colors(on: day) : []
        let circle = min(height - (dense ? 3 : 5), dense ? 15 : 22)
        return VStack(spacing: 1) {
            Text("\(Calendar.current.component(.day, from: day))")
                .font(.system(size: dense ? 9 : 12, weight: isToday ? .bold : .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(isToday ? .white : inMonth ? WPalette.ink : WPalette.text3.opacity(0.6))
                .frame(width: circle, height: circle)
                .background { if isToday { Circle().fill(WPalette.accent) } }
            HStack(spacing: 1.5) {
                ForEach(colors.prefix(3), id: \.self) { hex in
                    Circle().fill(WidgetHex.color(hex)).frame(width: dense ? 2.5 : 4, height: dense ? 2.5 : 4)
                }
            }
            .frame(height: dense ? 2.5 : 4)
        }
    }
}

enum WidgetHex {
    static func color(_ hex: String) -> Color {
        var text = hex
        if text.hasPrefix("#") { text.removeFirst() }
        return UInt32(text, radix: 16).map(WPalette.rgb) ?? WPalette.text2
    }
}

// MARK: - Lock screen, circular

/// Start time of the next item, or a calendar with today's date when nothing is left.
struct WidgetAgendaCircularView: View {
    let snapshot: WidgetAgendaSnapshot
    let date: Date

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let item = snapshot.upcoming(at: date, limit: 1).first, Calendar.current.isDateInToday(item.start) || item.start <= date {
                VStack(spacing: 0) {
                    Image(systemName: item.conference == nil ? "calendar" : "video.fill").font(.system(size: 11, weight: .semibold))
                        .widgetAccentable()
                    Text(item.start <= date ? "Now" : AgendaWidgetText.time(item.start))
                        .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                        .minimumScaleFactor(0.7)
                }
            } else {
                VStack(spacing: -2) {
                    Text(date.formatted(.dateTime.weekday(.abbreviated).locale(AgendaWidgetText.locale)).uppercased())
                        .font(.system(size: 10, weight: .bold)).widgetAccentable()
                    Text("\(Calendar.current.component(.day, from: date))")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                }
            }
        }
        .widgetURL(snapshot.upcoming(at: date, limit: 1).first?.link ?? URL(string: "nuo://calendar"))
    }
}
#endif
