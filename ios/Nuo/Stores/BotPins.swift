import Foundation

/// Bots pinned at the top of the bot lists, kept on this device. Until the user pins or unpins a bot, the bot that sees
/// every bot is the pinned one, so it leads the lists on every device without a setting to sync.
struct BotPins {
    static let key = "nuo.pinnedBots"

    private let defaults: UserDefaults
    private(set) var ids: [String]?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ids = defaults.stringArray(forKey: Self.key)
    }

    func isPinned(_ bot: Bot) -> Bool {
        ids.map { $0.contains(bot.id) } ?? (bot.config?.overview == true)
    }

    mutating func setPinned(_ bot: Bot, _ pinned: Bool, among bots: [Bot]) {
        var current = ids ?? bots.filter(isPinned).map(\.id)
        current.removeAll { $0 == bot.id }
        if pinned { current.append(bot.id) }
        ids = current
        defaults.set(current, forKey: Self.key)
    }

    /// Pinned bots in the order they were pinned, then the others by last activity, the never used ones last.
    func split(_ bots: [Bot]) -> (pinned: [Bot], others: [Bot]) {
        let indexed = Array(bots.enumerated())
        let pinned = indexed.filter { isPinned($0.element) }.sorted { a, b in
            let ia = ids?.firstIndex(of: a.element.id) ?? a.offset
            let ib = ids?.firstIndex(of: b.element.id) ?? b.offset
            return ia < ib
        }
        let others = indexed.filter { !isPinned($0.element) }.sorted { a, b in
            switch (a.element.lastMessageAt, b.element.lastMessageAt) {
            case let (x?, y?) where x != y: x > y
            case (.some, nil): true
            case (nil, .some): false
            default: a.offset < b.offset
            }
        }
        return (pinned.map(\.element), others.map(\.element))
    }

    /// Pinned bots first, the others in their usual order: a sidebar must not reshuffle at every message.
    func pinnedFirst(_ bots: [Bot]) -> [Bot] {
        split(bots).pinned + bots.filter { !isPinned($0) }
    }
}
