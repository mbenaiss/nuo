import AppIntents
import SwiftUI
import WidgetKit

extension ReminderWidgetScope: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Reminders shown"
    static let caseDisplayRepresentations: [ReminderWidgetScope: DisplayRepresentation] = [
        .today: "Today only",
        .todayAndUpcoming: "Today and upcoming",
    ]
}

struct RemindersWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Reminders"
    static let description = IntentDescription("The reminders the widget shows. Overdue ones count as today.")

    @Parameter(title: "Show", default: .today)
    var scope: ReminderWidgetScope

    init() {}

    init(scope: ReminderWidgetScope) {
        self.scope = scope
    }
}

struct RemindersIntentProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> RemindersEntry {
        RemindersEntry(date: .now, snapshot: .demo, scope: .today)
    }

    func snapshot(for configuration: RemindersWidgetIntent, in context: Context) async -> RemindersEntry {
        if context.isPreview {
            return RemindersEntry(date: .now, snapshot: .demo, scope: configuration.scope)
        }
        return RemindersEntry(date: .now, snapshot: await RemindersLoader.load(gateway: .current()), scope: configuration.scope)
    }

    func timeline(for configuration: RemindersWidgetIntent, in context: Context) async -> Timeline<RemindersEntry> {
        RemindersLoader.timeline(await RemindersLoader.load(gateway: .current()), scope: configuration.scope)
    }
}

struct RemindersProvider: TimelineProvider {
    func placeholder(in context: Context) -> RemindersEntry {
        RemindersEntry(date: .now, snapshot: .demo)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (RemindersEntry) -> Void) {
        if context.isPreview {
            completion(RemindersEntry(date: .now, snapshot: .demo))
            return
        }
        Task { completion(RemindersEntry(date: .now, snapshot: await RemindersLoader.load(gateway: .current()))) }
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<RemindersEntry>) -> Void) {
        Task { completion(RemindersLoader.timeline(await RemindersLoader.load(gateway: .current()))) }
    }
}

struct RemindersWidget: Widget {
    nonisolated static let kind = AppIdentity.scoped("reminders")

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: RemindersWidgetIntent.self, provider: RemindersIntentProvider()) { entry in
            RemindersWidgetFamilyView(entry: entry)
        }
        .configurationDisplayName("Reminders")
        .description("Your reminders for today, or the upcoming ones too, to check off right from the Home Screen.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

private struct RemindersWidgetFamilyView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RemindersEntry

    var body: some View {
        RemindersWidgetView(family: family, entry: entry)
            .containerBackground(WPalette.card, for: .widget)
    }
}

// MARK: - Lock screen

struct RemindersAccessoryWidget: Widget {
    nonisolated static let kind = AppIdentity.scoped("reminders.lock")

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: RemindersProvider()) { entry in
            RemindersAccessoryView(entry: entry)
                .containerBackground(.clear, for: .widget)
                .widgetURL(URL(string: "nuo://reminders"))
        }
        .configurationDisplayName("Today's reminders")
        .description("Today's reminder count and the next one.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private struct RemindersAccessoryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RemindersEntry

    var body: some View {
        let today = entry.snapshot.today(at: entry.date)
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: -1) {
                    Image(systemName: today.isEmpty ? "checkmark" : "checklist").font(.system(size: 12, weight: .bold)).widgetAccentable()
                    if !today.isEmpty {
                        Text("\(today.count)").font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                    }
                }
            }
        case .accessoryInline:
            if let first = today.first {
                Label("\(today.count) · \(first.title)", systemImage: "checklist")
            } else {
                Label("No reminders", systemImage: "checkmark.circle")
            }
        default:
            VStack(alignment: .leading, spacing: 1) {
                Label(ReminderWidgetText.count(today.count), systemImage: "checklist")
                    .font(.caption.weight(.semibold))
                    .widgetAccentable()
                if today.isEmpty {
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

#Preview("Reminders", as: .systemSmall) {
    RemindersWidget()
} timeline: {
    RemindersEntry(date: .now, snapshot: .demo, scope: .today)
}

#Preview("Reminders medium", as: .systemMedium) {
    RemindersWidget()
} timeline: {
    RemindersEntry(date: .now, snapshot: .demo)
}

#Preview("Reminders large", as: .systemLarge) {
    RemindersWidget()
} timeline: {
    RemindersEntry(date: .now, snapshot: .demo, scope: .todayAndUpcoming)
}

#Preview("Reminders large, today", as: .systemLarge) {
    RemindersWidget()
} timeline: {
    RemindersEntry(date: .now, snapshot: .demo, scope: .today)
}
