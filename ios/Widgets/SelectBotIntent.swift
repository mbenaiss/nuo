import AppIntents
import WidgetKit

struct BotEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Bot"
    static let defaultQuery = BotEntityQuery()

    let id: String
    let name: String
    let emoji: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(emoji) \(name)") }
}

struct BotEntityQuery: EntityQuery {
    func entities(for identifiers: [BotEntity.ID]) async throws -> [BotEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [BotEntity] {
        let snapshot = await SnapshotLoader.load()
        return snapshot.bots.map { BotEntity(id: $0.id, name: $0.name, emoji: $0.emoji) }
    }
}

struct SelectBotIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose a bot"
    static let description = IntentDescription("The bot the widget shows. By default, the last one to reply.")

    @Parameter(title: "Bot")
    var bot: BotEntity?

    init() {}

    init(bot: BotEntity?) {
        self.bot = bot
    }
}
