import Foundation

/// What the widgets display, flattened from `/api/bots` and `/api/conversations`.
struct WidgetSnapshot: Codable, Hashable, Sendable {
    enum Status: String, Codable, Sendable { case ready, signedOut, offline }

    var status: Status
    var bots: [WidgetBotItem]
    var recents: [WidgetConversationItem]
    var fetchedAt: Date

    static let signedOut = WidgetSnapshot(status: .signedOut, bots: [], recents: [], fetchedAt: .now)

    /// Bot with the most recent message, used by widgets that are not configured with a bot.
    var latestBot: WidgetBotItem? {
        bots.filter { $0.lastAt != nil }.max { ($0.lastAt ?? .distantPast) < ($1.lastAt ?? .distantPast) } ?? bots.first
    }

    func bot(id: String?) -> WidgetBotItem? {
        guard let id else { return latestBot }
        return bots.first { $0.id == id } ?? latestBot
    }

    init(status: Status, bots: [WidgetBotItem], recents: [WidgetConversationItem], fetchedAt: Date) {
        self.status = status
        self.bots = bots
        self.recents = recents
        self.fetchedAt = fetchedAt
    }

    init(bots: [Bot], conversations: [Conversation]) {
        let latest = Dictionary(grouping: conversations, by: \.botId).compactMapValues { $0.max { $0.updatedAt < $1.updatedAt } }
        let items = bots.compactMap { bot -> WidgetBotItem? in
            guard let config = bot.config else { return nil }
            return WidgetBotItem(
                id: bot.id, name: config.name, emoji: config.emoji, color: config.color,
                preview: bot.lastMessagePreview.map(WidgetText.plain), lastAt: bot.lastMessageAt,
                latestConversationId: latest[bot.id]?.id)
        }
        let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let recents = conversations
            .sorted { $0.updatedAt > $1.updatedAt }
            .compactMap { conversation -> WidgetConversationItem? in
                guard let bot = byId[conversation.botId] else { return nil }
                let isLatest = bot.latestConversationId == conversation.id
                return WidgetConversationItem(
                    id: conversation.id, botId: bot.id, botName: bot.name, emoji: bot.emoji, color: bot.color,
                    title: conversation.title, preview: isLatest ? bot.preview : nil, updatedAt: conversation.updatedAt)
            }
        self.init(status: .ready, bots: items, recents: Array(recents.prefix(4)), fetchedAt: .now)
    }
}

struct WidgetBotItem: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var emoji: String
    var color: String
    var preview: String?
    var lastAt: Date?
    var latestConversationId: String?

    /// Latest conversation when there is one, otherwise a new one.
    var openLink: URL {
        latestConversationId.map { NuoLink.conversation(id: $0, botId: id).url } ?? NuoLink.newConversation(botId: id).url
    }

    var newLink: URL { NuoLink.newConversation(botId: id).url }
    var voiceLink: URL { NuoLink.voice(botId: id).url }
}

struct WidgetConversationItem: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var botId: String
    var botName: String
    var emoji: String
    var color: String
    var title: String
    var preview: String?
    var updatedAt: Date

    var link: URL { NuoLink.conversation(id: id, botId: botId).url }

    var subtitle: String {
        if let preview, !preview.isEmpty { return preview }
        return title.isEmpty ? String(localized: "New conversation") : title
    }
}

enum WidgetText {
    /// Drops card lines (`::kind {json}`) and markdown markers so a reply reads as one line of text.
    static func plain(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("::") }
            .joined(separator: " ")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "#", with: "")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Opening of a finished answer as plain prose: no cards, code, tables or list markers.
    static func excerpt(_ text: String, limit: Int = 180) -> String? {
        var lines: [String] = []
        var inCode = false
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inCode.toggle(); continue }
            if inCode || line.hasPrefix("::") || line.hasPrefix("|") || line.isEmpty { continue }
            while let first = line.first, "#>".contains(first) { line = line.dropFirst().trimmingCharacters(in: .whitespaces) }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") { line = String(line.dropFirst(2)) }
            if let match = line.prefixMatch(of: /\d{1,2}[.)]\s/) { line = String(line[match.range.upperBound...]) }
            lines.append(line)
        }
        let flat = plain(lines.joined(separator: " ")).replacingOccurrences(of: "__", with: "")
        guard !flat.isEmpty else { return nil }
        guard flat.count > limit else { return flat }
        let cut = flat.prefix(limit)
        let head = cut.lastIndex(where: \.isWhitespace).map { cut[..<$0] } ?? cut
        return head.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) + "…"
    }

    /// Last sentence of a streaming answer, with the previous one when the current fragment is still short.
    static func lastSentence(_ text: String, limit: Int = 110) -> String? {
        let flat = plain(text)
        guard !flat.isEmpty else { return nil }
        var sentences: [String] = []
        var current = ""
        for character in flat {
            current.append(character)
            if ".!?…".contains(character) {
                sentences.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { sentences.append(tail) }
        guard var result = sentences.last else { return nil }
        if result.count < 24, sentences.count > 1 { result = sentences[sentences.count - 2] + " " + result }
        if result.count > limit { result = "…" + result.suffix(limit - 1).drop { !$0.isWhitespace }.trimmingCharacters(in: .whitespaces) }
        return result
    }
}

extension WidgetSnapshot {
    /// Realistic data for widget placeholders, the gallery and debug renders.
    static var demo: WidgetSnapshot {
        let now = Date.now
        let bots = [
            WidgetBotItem(id: "voyages", name: String(localized: "Travel"), emoji: "✈️", color: "#E0EEFF",
                          preview: String(localized: "TO8285 Monday: on time, gate F32, boarding 6:55 am."),
                          lastAt: now.addingTimeInterval(-12 * 60), latestConversationId: "c-voyages-1"),
            WidgetBotItem(id: "coach", name: "Coach", emoji: "🏃", color: "#E3F4E1",
                          preview: String(localized: "Today's workout: 6 × 800 m at 4:35/km, 2 min rest."),
                          lastAt: now.addingTimeInterval(-95 * 60), latestConversationId: "c-coach-1"),
            WidgetBotItem(id: "cobot", name: "Cobot", emoji: "🦊", color: "#FFE8D9",
                          preview: String(localized: "I merged PR #23, the deployment is in progress on dev."),
                          lastAt: now.addingTimeInterval(-4 * 3600), latestConversationId: "c-cobot-1"),
            WidgetBotItem(id: "maison", name: String(localized: "Home"), emoji: "🏡", color: "#FFF1C9",
                          preview: String(localized: "Balcony plug is off, it will be 16° tomorrow."),
                          lastAt: now.addingTimeInterval(-26 * 3600), latestConversationId: "c-maison-1"),
            WidgetBotItem(id: "cuisine", name: String(localized: "Kitchen"), emoji: "🍋", color: "#F1E8FF",
                          preview: String(localized: "Lemon and parmesan pasta, 20 min."),
                          lastAt: now.addingTimeInterval(-3 * 86400), latestConversationId: nil),
            WidgetBotItem(id: "lecture", name: String(localized: "Reading"), emoji: "📚", color: "#FFE3EA",
                          preview: nil, lastAt: nil, latestConversationId: nil),
        ]
        func recent(_ id: String, _ bot: WidgetBotItem, _ title: String, _ preview: String?, _ ago: TimeInterval) -> WidgetConversationItem {
            WidgetConversationItem(id: id, botId: bot.id, botName: bot.name, emoji: bot.emoji, color: bot.color,
                                   title: title, preview: preview, updatedAt: now.addingTimeInterval(-ago))
        }
        let recents = [
            recent("c-voyages-1", bots[0], String(localized: "Monday flight"), bots[0].preview, 12 * 60),
            recent("c-coach-1", bots[1], String(localized: "Interval workout"), bots[1].preview, 95 * 60),
            recent("c-cobot-1", bots[2], String(localized: "Gateway deployment"), bots[2].preview, 4 * 3600),
            recent("c-maison-1", bots[3], String(localized: "Weather and balcony"), bots[3].preview, 26 * 3600),
        ]
        return WidgetSnapshot(status: .ready, bots: bots, recents: recents, fetchedAt: now)
    }
}
