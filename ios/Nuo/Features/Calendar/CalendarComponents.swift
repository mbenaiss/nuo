import SwiftUI

/// One line of the agenda list: an event (calendar color bar, times, place, « Rejoindre »), a reminder with its
/// checkbox, or a booking with its 📅 badge.
struct AgendaRow: View {
    let item: AgendaItem
    var now = Date()
    var onToggleReminder: (() -> Void)?

    @Environment(\.openURL) private var openURL
    /// Grows with Dynamic Type so « 12:30 » never wraps.
    @ScaledMetric(relativeTo: .subheadline) private var timeWidth = CalendarMetrics.timeLabelWidth

    var body: some View {
        switch item.kind {
        case .reminder: reminderRow
        default: eventRow
        }
    }

    private var isPast: Bool { item.end < now && !item.allDay }
    private var isNow: Bool { item.start <= now && item.end > now && !item.allDay }

    private var eventRow: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            timeColumn
            RoundedRectangle(cornerRadius: CalendarMetrics.colorBarWidth / 2, style: .continuous)
                .fill(item.isBusyOnly ? item.tint.opacity(0.5) : item.tint)
                .frame(width: CalendarMetrics.colorBarWidth)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    if item.isBooking { Text(verbatim: "📅").font(.subheadline).accessibilityLabel("Booked appointment") }
                    Text(item.displayTitle)
                        .font(.body.weight(.medium))
                        .foregroundStyle(item.isBusyOnly ? Color.text2 : Color.ink)
                        .strikethrough(item.isCancelled, color: Color.text3)
                        .lineLimit(2)
                    if item.status == "tentative" || item.status == "pending" {
                        Badge(text: item.kind == .booking ? String(localized: "In progress") : String(localized: "Tentative"))
                    }
                }
                meta
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let conference = item.conference, !isPast {
                JoinButton(url: conference, prominent: isNow || item.start.timeIntervalSince(now) < 15 * 60)
            }
        }
        .padding(.vertical, Spacing.xxs)
        .opacity(isPast ? 0.55 : 1)
        .background(alignment: .leading) {
            if item.isBusyOnly {
                HatchPattern(color: Color.text3.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.xs, style: .continuous))
                    .padding(.leading, timeWidth + Spacing.sm)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var timeColumn: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if item.allDay {
                Text("All-day").font(.caption.weight(.semibold)).foregroundStyle(Color.text2)
            } else {
                Text(AgendaText.time(item.start)).font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(isNow ? Color.accent : Color.ink)
                Text(AgendaText.time(item.end)).font(.caption.monospacedDigit()).foregroundStyle(Color.text3)
            }
        }
        .lineLimit(1)
        .frame(width: timeWidth, alignment: .trailing)
    }

    @ViewBuilder
    private var meta: some View {
        let parts = metaParts
        if !parts.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(parts, id: \.text) { part in
                    Label(part.text, systemImage: part.symbol)
                        .font(.caption)
                        .foregroundStyle(Color.text2)
                        .labelStyle(TightLabelStyle())
                        .lineLimit(1)
                }
            }
        }
    }

    private var metaParts: [(text: String, symbol: String)] {
        var parts: [(String, String)] = []
        if item.spansDays, item.allDay, let last = item.days.last {
            parts.append((String(localized: "Until \(AgendaText.shortDay(last))"), "arrow.right"))
        }
        if let location = item.location, !location.isEmpty, item.conference?.absoluteString != location {
            parts.append((location, "mappin"))
        } else if let conference = item.conferenceUrl {
            parts.append((AgendaText.conferenceName(conference), "video"))
        }
        if let travel = item.travelTimeSec, travel > 0, !isPast { parts.append((AgendaText.travel(travel), "car")) }
        if item.kind == .booking { parts.append((String(localized: "Booked online"), "link")) }
        return parts
    }

    private var reminderRow: some View {
        HStack(alignment: .center, spacing: Spacing.sm) {
            Text(AgendaText.time(item.start))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(item.done == true ? Color.text3 : Color.ink)
                .lineLimit(1)
                .frame(width: timeWidth, alignment: .trailing)
            ReminderCheckbox(done: item.done == true, priority: item.priority ?? 0) { onToggleReminder?() }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .font(.body)
                    .foregroundStyle(item.done == true ? Color.text3 : Color.ink)
                    .strikethrough(item.done == true, color: Color.text3)
                    .lineLimit(2)
                if let list = item.list {
                    Label(ReminderStyle.listLabel(list), systemImage: ReminderStyle.symbol(forList: list))
                        .font(.caption).foregroundStyle(Color.text3).labelStyle(TightLabelStyle())
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Spacing.xxs)
        .contentShape(Rectangle())
    }
}

struct ReminderCheckbox: View {
    let done: Bool
    var priority = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(done ? Color.good : ReminderStyle.priorityColor(priority).opacity(priority > 0 ? 1 : 0.6), lineWidth: 1.8)
                Circle().fill(Color.good).scaleEffect(done ? 1 : 0.2).opacity(done ? 1 : 0)
                Image(systemName: "checkmark").font(.caption2.weight(.heavy)).foregroundStyle(.white).opacity(done ? 1 : 0)
            }
            .frame(width: Spacing.lg + Spacing.xxs, height: Spacing.lg + Spacing.xxs)
            .animation(.spring(response: 0.32, dampingFraction: 0.6), value: done)
            .contentShape(Circle().inset(by: -Spacing.xs))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(done ? String(localized: "Reopen") : String(localized: "Mark as done"))
    }
}

/// « Rejoindre » for Meet, Zoom, Teams… links; filled when the meeting starts soon.
struct JoinButton: View {
    let url: URL
    var prominent = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            Haptics.tap()
            openURL(url)
        } label: {
            Label("Join", systemImage: "video.fill")
                .font(.footnote.weight(.semibold))
                .labelStyle(TightLabelStyle())
                .foregroundStyle(prominent ? Color.white : Color(hex: 0x1A73E8))
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs - 2)
                .background(prominent ? Color(hex: 0x1A73E8) : Color(hex: 0x1A73E8).opacity(0.12), in: Capsule())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Join the video call")
    }
}

/// Chips under the quick-entry field: what the parser understood.
struct ParsedEventPreview: View {
    let parsed: ParsedEvent
    var calendar: CalendarInfo?

    var body: some View {
        WrapLayout(spacing: Spacing.xs - 2) {
            chip(whenText, symbol: parsed.allDay ? "sun.max" : "calendar", tint: Color.accentInk, fill: Color.accentSoft)
            if !parsed.allDay, parsed.hasWhen {
                chip(AgendaText.duration(parsed.duration), symbol: "timer", tint: Color.ink, fill: Color.chip)
            }
            if let recurrence = parsed.recurrence {
                chip(recurrence.label, symbol: "repeat", tint: Color(hex: 0x2563EB), fill: Color(hex: 0x3B82F6).opacity(0.14))
            }
            if let calendar {
                HStack(spacing: Spacing.xxs + 1) {
                    CalendarDot(color: Color(hexString: calendar.color ?? "") ?? Color.text2, size: 8)
                    Text(calendar.title).font(.footnote.weight(.semibold))
                }
                .foregroundStyle(Color.ink)
                .padding(.horizontal, Spacing.sm - 2)
                .padding(.vertical, Spacing.xs - 2)
                .background(Color.chip, in: Capsule())
            } else if let hint = parsed.calendarHint {
                chip("/\(hint) ?", symbol: "questionmark.circle", tint: Color.bad, fill: Color.bad.opacity(0.1))
            }
            if let location = parsed.location {
                chip(location, symbol: "mappin", tint: Color(hex: 0xC2410C), fill: Color(hex: 0xF97316).opacity(0.13))
            }
            if let alarm = parsed.alarmMinutes {
                chip(AgendaText.alarm(alarm), symbol: "bell", tint: Color.ink, fill: Color.chip)
            }
            if !parsed.attendees.isEmpty {
                chip(parsed.attendees.count == 1 ? EventParser.displayName(parsed.attendees[0]) : String(localized: "\(parsed.attendees.count) guests"),
                     symbol: "person.2", tint: Color(hex: 0x15803D), fill: Color.good.opacity(0.13))
            }
            if parsed.meet {
                chip("Google Meet", symbol: "video", tint: Color(hex: 0x1A73E8), fill: Color(hex: 0x1A73E8).opacity(0.12))
            }
            if parsed.needsGoogle {
                chip(String(localized: "Invitations sent by Google"), symbol: "envelope", tint: Color.text2, fill: Color.chip)
            }
        }
    }

    private var whenText: String {
        let calendar = AgendaCalendar.current
        if parsed.allDay {
            let last = calendar.date(byAdding: .day, value: -1, to: parsed.end) ?? parsed.start
            let day = ReminderDateText.full(parsed.start).replacingOccurrences(of: #" \d{1,2}:\d{2}$"#, with: "", options: .regularExpression)
            if calendar.isDate(last, inSameDayAs: parsed.start) { return String(localized: "\(day) · all day") }
            return "\(AgendaText.shortDay(parsed.start)) → \(AgendaText.shortDay(last))"
        }
        let day = ReminderDateText.full(parsed.start).replacingOccurrences(of: #" \d{1,2}:\d{2}$"#, with: "", options: .regularExpression)
        return "\(day) · \(AgendaText.time(parsed.start)) – \(AgendaText.time(parsed.end))"
    }

    private func chip(_ text: String, symbol: String, tint: Color, fill: Color) -> some View {
        HStack(spacing: Spacing.xxs + 1) {
            Image(systemName: symbol).font(.caption2.weight(.bold))
            Text(text).font(.footnote.weight(.semibold)).lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, Spacing.sm - 2)
        .padding(.vertical, Spacing.xs - 2)
        .background(fill, in: Capsule())
    }
}

/// Picks one of the calendars this device can write to.
struct CalendarPicker: View {
    @Binding var selection: String?
    var label = String(localized: "calendar.name", defaultValue: "Calendar")
    @State private var store = CalendarStore.shared

    var body: some View {
        Picker(label, selection: $selection) {
            ForEach(store.writableCalendars) { calendar in
                Label {
                    Text(calendar.title)
                } icon: {
                    Image(systemName: "circle.fill").foregroundStyle(Color(hexString: calendar.color ?? "") ?? Color.text2)
                }
                .tag(String?.some(calendar.id))
            }
        }
    }
}

/// Shown where the agenda needs EventKit access: explains what is read and why.
struct CalendarAccessCard: View {
    @State private var bridge = CalendarBridge.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: "calendar.badge.plus")
                .font(.title2)
                .foregroundStyle(Color.accent)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(bridge.access == .denied ? String(localized: "Calendar access denied") : String(localized: "Connect your calendars"))
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
                Text("Nuo reads the calendars on this device (iCloud, Google, Exchange…) to show them, edit them and work out your availability.")
                    .font(.footnote).foregroundStyle(Color.text2)
                    .fixedSize(horizontal: false, vertical: true)
                Button(bridge.access == .denied ? String(localized: "Open settings") : String(localized: "Allow access")) {
                    if bridge.access == .denied {
                        #if os(iOS)
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        #else
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") { openURL(url) }
                        #endif
                    } else {
                        Task { await bridge.requestAccess() }
                    }
                }
                .font(.footnote.weight(.semibold))
                .padding(.top, Spacing.xxs)
            }
            Spacer(minLength: 0)
        }
        .padding(CardMetrics.compactPadding)
        .background(Color.accentSoft.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }
}
