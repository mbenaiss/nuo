import SwiftUI
import WidgetKit

extension WidgetGateway {
    /// The watch's own pairing (watch-scoped token), shared by the app through the keychain group.
    static func watch() -> WidgetGateway? {
        guard let credentials = WatchKeychain.credentials else { return nil }
        // Through the iPhone's connection the watch is slow to answer: use the long timeout.
        return WidgetGateway(routes: [GatewayRoute(baseURL: credentials.gatewayURL, headers: [:], isInternet: true)], token: credentials.token)
    }
}

private let watchAccent = Color(red: 1, green: 0.416, blue: 0.169)

private func calendarColor(_ hex: String?) -> Color {
    guard var text = hex else { return .gray }
    if text.hasPrefix("#") { text.removeFirst() }
    guard let value = UInt32(text, radix: 16) else { return .gray }
    return Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
}

// MARK: - Next event

struct WatchAgendaProvider: TimelineProvider {
    func placeholder(in context: Context) -> AgendaEntry { AgendaEntry(date: .now, snapshot: .demo) }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (AgendaEntry) -> Void) {
        if context.isPreview { return completion(placeholder(in: context)) }
        Task { completion(AgendaEntry(date: .now, snapshot: await AgendaLoader.load(gateway: .watch()))) }
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<AgendaEntry>) -> Void) {
        Task { completion(AgendaLoader.timeline(await AgendaLoader.load(gateway: .watch()))) }
    }
}

struct AgendaComplication: Widget {
    nonisolated static let kind = AppIdentity.local(.watchAgendaKind)

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: WatchAgendaProvider()) { entry in
            AgendaComplicationView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(WatchDeepLink.home)
        }
        .configurationDisplayName("Next event")
        .description("Your next appointment and how long until it starts.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

struct AgendaComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AgendaEntry

    private var next: AgendaWireItem? { entry.snapshot.upcoming(at: entry.date, limit: 1).first }

    var body: some View {
        switch family {
        case .accessoryInline:
            if let next {
                Text("\(AgendaWidgetText.time(next.start)) \(next.displayTitle)")
            } else {
                Label("Nothing planned", systemImage: "calendar")
            }
        case .accessoryCorner:
            Image(systemName: "calendar")
                .font(.title3.weight(.semibold))
                .widgetAccentable()
                .widgetLabel {
                    Text(next.map { "\(AgendaWidgetText.time($0.start)) \($0.displayTitle)" } ?? String(localized: "Nothing planned"))
                }
        case .accessoryCircular:
            AgendaCircularView(entry: entry)
        default:
            rectangular
        }
    }

    private var rectangular: some View {
        HStack(alignment: .top, spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(next?.kind == "reminder" ? watchAccent : calendarColor(next?.color))
                .frame(width: 3)
                .widgetAccentable()
            VStack(alignment: .leading, spacing: 1) {
                if entry.snapshot.status == .signedOut {
                    Text("Nuo").font(.headline)
                    Text("Open Nuo on the watch").font(.caption2).foregroundStyle(.secondary)
                } else if let next {
                    Text(AgendaWidgetText.relative(next, now: entry.date))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(watchAccent)
                        .widgetAccentable()
                    Text(next.displayTitle).font(.headline).lineLimit(1)
                    Text([AgendaWidgetText.range(next), next.location].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(String(localized: "widget.agenda", defaultValue: "Calendar")).font(.caption2.weight(.semibold)).foregroundStyle(watchAccent).widgetAccentable()
                    Text("Nothing planned").font(.headline)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Circular: today's next item, or the date. With nothing left at all, the mascot instead of an empty date.
struct AgendaCircularView: View {
    let entry: AgendaEntry

    var body: some View {
        let next = entry.snapshot.upcoming(at: entry.date, limit: 1).first
        ZStack {
            AccessoryWidgetBackground()
            if entry.snapshot.status == .ready, next == nil {
                ComplicationMascot(size: 30)
            } else if let next, Calendar.current.isDateInToday(next.start) || next.start <= entry.date {
                VStack(spacing: 0) {
                    Image(systemName: next.conference == nil ? "calendar" : "video.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(watchAccent)
                        .widgetAccentable()
                    Text(next.start <= entry.date ? "Now" : AgendaWidgetText.time(next.start))
                        .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                        .minimumScaleFactor(0.7)
                }
            } else {
                VStack(spacing: -2) {
                    Text(entry.date.formatted(.dateTime.weekday(.abbreviated).locale(AgendaWidgetText.locale)).uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(watchAccent)
                        .widgetAccentable()
                    Text("\(Calendar.current.component(.day, from: entry.date))")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                }
            }
        }
    }
}

// MARK: - Reminders

struct WatchRemindersProvider: TimelineProvider {
    func placeholder(in context: Context) -> RemindersEntry { RemindersEntry(date: .now, snapshot: .demo) }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (RemindersEntry) -> Void) {
        if context.isPreview { return completion(placeholder(in: context)) }
        Task { completion(RemindersEntry(date: .now, snapshot: await RemindersLoader.load(gateway: .watch()))) }
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<RemindersEntry>) -> Void) {
        Task { completion(RemindersLoader.timeline(await RemindersLoader.load(gateway: .watch()))) }
    }
}

struct RemindersComplication: Widget {
    nonisolated static let kind = AppIdentity.local(.watchRemindersKind)

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: WatchRemindersProvider()) { entry in
            RemindersComplicationView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(WatchDeepLink.home)
        }
        .configurationDisplayName("Reminders")
        .description("Today's reminder count and the next ones.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

struct RemindersComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RemindersEntry

    var body: some View {
        let today = entry.snapshot.today(at: entry.date)
        let overdue = entry.snapshot.overdue(at: entry.date).count
        switch family {
        case .accessoryInline:
            if let first = today.first {
                Text("\(today.count) · \(first.title)")
            } else {
                Label("No reminders", systemImage: "checkmark.circle")
            }
        case .accessoryCorner:
            Text("\(today.count)")
                .font(.title2.weight(.semibold).monospacedDigit())
                .widgetLabel { Text(today.first?.title ?? String(localized: "Reminders")) }
        case .accessoryCircular:
            RemindersCircularView(entry: entry)
        default:
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: "checklist")
                    Text(ReminderWidgetText.count(today.count))
                    if overdue > 0 { Text("· \(overdue) overdue").foregroundStyle(.red) }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(watchAccent)
                .widgetAccentable()
                if entry.snapshot.status == .signedOut {
                    Text("Open Nuo on the watch").font(.caption2)
                } else if today.isEmpty {
                    Text("All done").font(.headline)
                }
                ForEach(today.prefix(2)) { item in
                    Text(item.title).font(.footnote).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Circular: today's count, or the mascot once everything is done.
struct RemindersCircularView: View {
    let entry: RemindersEntry

    var body: some View {
        let today = entry.snapshot.today(at: entry.date)
        let overdue = entry.snapshot.overdue(at: entry.date).count
        ZStack {
            AccessoryWidgetBackground()
            if entry.snapshot.status == .ready, today.isEmpty {
                VStack(spacing: 0) {
                    ComplicationMascot(size: 24)
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(watchAccent)
                        .widgetAccentable()
                }
            } else {
                VStack(spacing: -1) {
                    Image(systemName: "checklist")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(overdue > 0 ? .red : watchAccent)
                        .widgetAccentable()
                    Text("\(today.count)").font(.system(size: 19, weight: .semibold, design: .rounded).monospacedDigit())
                }
            }
        }
    }
}
