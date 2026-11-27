import Foundation
import WidgetKit

struct ComplicationBot: Codable, Hashable, Sendable {
    var id: String
    var name: String
    var emoji: String
    var color: String
}

struct ComplicationReply: Codable, Hashable, Sendable {
    var bot: ComplicationBot
    var text: String
    var at: Date
}

/// Snapshot the watch app writes for its complications. It lives in the app group so a widget extension
/// can read it; without the group entitlement the suite falls back to the app's own defaults.
enum ComplicationStore {
    static let appGroup = AppIdentity.appGroup
    private static let botsKey = "nuo.complication.bots"
    private static let replyKey = "nuo.complication.lastReply"

    private static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    static var bots: [ComplicationBot] {
        guard let data = defaults.data(forKey: botsKey) else { return [] }
        return (try? JSONDecoder().decode([ComplicationBot].self, from: data)) ?? []
    }

    static var lastReply: ComplicationReply? {
        guard let data = defaults.data(forKey: replyKey) else { return nil }
        return try? JSONDecoder().decode(ComplicationReply.self, from: data)
    }

    static func saveBots(_ bots: [Bot]) {
        let snapshot = bots.compactMap { bot -> ComplicationBot? in
            guard let config = bot.config else { return nil }
            return ComplicationBot(id: bot.id, name: config.name, emoji: config.emoji, color: config.color)
        }
        guard snapshot != self.bots, let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: botsKey)
        if lastReply == nil, let bot = bots.first(where: { $0.lastMessagePreview != nil }), let config = bot.config {
            saveLastReply(ComplicationReply(
                bot: ComplicationBot(id: bot.id, name: config.name, emoji: config.emoji, color: config.color),
                text: bot.lastMessagePreview ?? "", at: bot.lastMessageAt ?? Date()))
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func saveLastReply(bot: Bot, text: String) {
        guard let config = bot.config else { return }
        let preview = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        saveLastReply(ComplicationReply(
            bot: ComplicationBot(id: bot.id, name: config.name, emoji: config.emoji, color: config.color),
            text: preview, at: Date()))
    }

    private static func saveLastReply(_ reply: ComplicationReply) {
        guard let data = try? JSONEncoder().encode(reply) else { return }
        defaults.set(data, forKey: replyKey)
        WidgetCenter.shared.reloadTimelines(ofKind: LastReplyComplication.kind)
    }
}
