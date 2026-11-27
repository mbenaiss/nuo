import SwiftUI
import WidgetKit

// Deep links handled by the watch app's `onOpenURL`.
enum WatchDeepLink {
    static func bot(botId: String) -> URL { URL(string: "nuo://watch/bot?bot=\(botId)")! }
    static let home = URL(string: "nuo://watch/home")!
}

/// The mascot as one flat color: complications are tinted on most faces, where the full-color art would turn into a blob.
struct ComplicationMascot: View {
    var size: CGFloat = 30

    var body: some View {
        Image("MascotSilhouette")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(Color(red: 1, green: 0.945, blue: 0.843))
            .widgetAccentable()
            .accessibilityLabel("Nuo")
    }
}

// MARK: - Rectangular: last reply

struct ReplyEntry: TimelineEntry {
    let date: Date
    let reply: ComplicationReply?
}

struct LastReplyProvider: TimelineProvider {
    func placeholder(in context: Context) -> ReplyEntry {
        ReplyEntry(date: .now, reply: ComplicationReply(
            bot: ComplicationBot(id: "voyages", name: "Voyages", emoji: "✈️", color: "#E0EEFF"),
            text: String(localized: "TO8285 Monday: on time, gate F32."), at: .now))
    }

    func getSnapshot(in context: Context, completion: @escaping (ReplyEntry) -> Void) {
        completion(ReplyEntry(date: .now, reply: ComplicationStore.lastReply ?? placeholder(in: context).reply))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ReplyEntry>) -> Void) {
        completion(Timeline(entries: [ReplyEntry(date: .now, reply: ComplicationStore.lastReply)], policy: .never))
    }
}

struct LastReplyComplication: Widget {
    nonisolated static let kind = "nuo.watch.lastReply"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: LastReplyProvider()) { entry in
            LastReplyView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(entry.reply.map { WatchDeepLink.bot(botId: $0.bot.id) } ?? WatchDeepLink.home)
        }
        .configurationDisplayName("Latest reply")
        .description("A bot's latest reply.")
        .supportedFamilies([.accessoryRectangular])
    }
}

struct LastReplyView: View {
    let entry: ReplyEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(entry.reply?.bot.emoji ?? "💬")
                Text(entry.reply?.bot.name ?? "Nuo")
                    .font(.headline)
                    .widgetAccentable()
                Spacer(minLength: 0)
                if let at = entry.reply?.at {
                    Text(at, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 44, alignment: .trailing)
                }
            }
            Text(entry.reply?.text ?? String(localized: "No reply yet"))
                .font(.caption)
                .lineLimit(2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
