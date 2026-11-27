import SwiftUI
import WidgetKit

struct BotsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AppIdentity.scoped("bots"), provider: SnapshotProvider()) { entry in
            BotsWidgetView(entry: entry)
        }
        .configurationDisplayName("Bots")
        .description("Start a conversation or voice mode with a bot.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

private struct BotsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        WidgetBotsView(snapshot: entry.snapshot, large: family == .systemLarge)
            .containerBackground(WPalette.canvas, for: .widget)
    }
}

struct RecentsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AppIdentity.scoped("recents"), provider: SnapshotProvider()) { entry in
            RecentsWidgetView(entry: entry)
        }
        .configurationDisplayName("Recent")
        .description("Your latest conversations, one tap to pick up.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

private struct RecentsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        WidgetRecentsView(snapshot: entry.snapshot, large: family == .systemLarge)
            .containerBackground(WPalette.card, for: .widget)
    }
}

struct BotWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: AppIdentity.scoped("bot"), intent: SelectBotIntent.self, provider: BotSnapshotProvider()) { entry in
            WidgetBotSmallView(snapshot: entry.snapshot, bot: entry.bot)
                .containerBackground(WPalette.card, for: .widget)
        }
        .configurationDisplayName("Bot")
        .description("A bot, its latest reply and voice mode.")
        .supportedFamilies([.systemSmall])
    }
}

struct VoiceAccessoryWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: AppIdentity.scoped("voice"), intent: SelectBotIntent.self, provider: BotSnapshotProvider()) { entry in
            WidgetVoiceCircleView(bot: entry.snapshot.status == .signedOut ? nil : entry.bot)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Talk to a bot")
        .description("Opens voice mode with the chosen bot.")
        .supportedFamilies([.accessoryCircular])
    }
}

struct LastReplyAccessoryWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: AppIdentity.scoped("lastreply"), intent: SelectBotIntent.self, provider: BotSnapshotProvider()) { entry in
            WidgetLastReplyView(snapshot: entry.snapshot, bot: entry.bot)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Latest reply")
        .description("A bot's latest reply on the Lock Screen.")
        .supportedFamilies([.accessoryRectangular])
    }
}

#Preview("Bots", as: .systemMedium) {
    BotsWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .demo)
    SnapshotEntry(date: .now, snapshot: .signedOut)
}

#Preview("Bots large", as: .systemLarge) {
    BotsWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .demo)
}

#Preview("Recent", as: .systemMedium) {
    RecentsWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .demo)
}

#Preview("Bot", as: .systemSmall) {
    BotWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .demo, botId: "coach")
}

#Preview("Voice", as: .accessoryCircular) {
    VoiceAccessoryWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .demo)
}

#Preview("Latest reply", as: .accessoryRectangular) {
    LastReplyAccessoryWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .demo)
}
