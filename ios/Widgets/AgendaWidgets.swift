import SwiftUI
import WidgetKit

struct AgendaProvider: TimelineProvider {
    var month = false

    func placeholder(in context: Context) -> AgendaEntry {
        AgendaEntry(date: .now, snapshot: .demo)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (AgendaEntry) -> Void) {
        if context.isPreview {
            completion(AgendaEntry(date: .now, snapshot: .demo))
            return
        }
        Task { completion(AgendaEntry(date: .now, snapshot: await AgendaLoader.load(gateway: .current(), month: month))) }
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<AgendaEntry>) -> Void) {
        Task { completion(AgendaLoader.timeline(await AgendaLoader.load(gateway: .current(), month: month))) }
    }
}

struct AgendaWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AppIdentity.scoped("agenda"), provider: AgendaProvider()) { entry in
            AgendaWidgetView(entry: entry)
        }
        .configurationDisplayName(String(localized: "widget.agenda", defaultValue: "Calendar"))
        .description("Your next appointment, or your day and tomorrow, with “Join” for video calls.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

private struct AgendaWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AgendaEntry

    var body: some View {
        Group {
            switch family {
            case .systemSmall: WidgetAgendaNextView(snapshot: entry.snapshot, date: entry.date)
            case .systemLarge: WidgetAgendaDayView(snapshot: entry.snapshot, date: entry.date)
            case .systemExtraLarge: WidgetAgendaTwoDaysView(snapshot: entry.snapshot, date: entry.date)
            default: WidgetAgendaListView(snapshot: entry.snapshot, date: entry.date)
            }
        }
        .containerBackground(WPalette.card, for: .widget)
    }
}

struct MonthWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AppIdentity.scoped("month"), provider: AgendaProvider(month: true)) { entry in
            MonthWidgetView(entry: entry)
        }
        .configurationDisplayName("Month")
        .description("The whole month and, beside it, today's events.")
        .supportedFamilies([.systemMedium, .systemLarge, .systemExtraLarge])
    }
}

private struct MonthWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AgendaEntry

    var body: some View {
        WidgetMonthView(family: family, snapshot: entry.snapshot, date: entry.date)
            .containerBackground(WPalette.card, for: .widget)
    }
}

struct AgendaAccessoryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AppIdentity.scoped("agenda.lock"), provider: AgendaProvider()) { entry in
            AgendaAccessoryView(entry: entry)
        }
        .configurationDisplayName("Next event")
        .description("The next event on the Lock Screen.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private struct AgendaAccessoryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AgendaEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryInline: WidgetAgendaInlineView(snapshot: entry.snapshot, date: entry.date)
            case .accessoryCircular: WidgetAgendaCircularView(snapshot: entry.snapshot, date: entry.date)
            default: WidgetAgendaRectangularView(snapshot: entry.snapshot, date: entry.date)
            }
        }
        .containerBackground(.clear, for: .widget)
    }
}

#Preview("Calendar", as: .systemSmall) {
    AgendaWidget()
} timeline: {
    AgendaEntry(date: .now, snapshot: .demo)
}

#Preview("Calendar medium", as: .systemMedium) {
    AgendaWidget()
} timeline: {
    AgendaEntry(date: .now, snapshot: .demo)
}

#Preview("Calendar large", as: .systemLarge) {
    AgendaWidget()
} timeline: {
    AgendaEntry(date: .now, snapshot: .demo)
}

#Preview("Month", as: .systemMedium) {
    MonthWidget()
} timeline: {
    AgendaEntry(date: .now, snapshot: .demo)
}

#Preview("Lock Screen", as: .accessoryRectangular) {
    AgendaAccessoryWidget()
} timeline: {
    AgendaEntry(date: .now, snapshot: .demo)
}
