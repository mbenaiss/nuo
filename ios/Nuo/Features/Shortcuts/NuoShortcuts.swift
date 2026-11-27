import AppIntents
import Foundation

/// A bot, as Shortcuts and Siri list it.
struct NuoBotEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Bot"
    static let defaultQuery = NuoBotQuery()

    let id: String
    let name: String
    let emoji: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(emoji) \(name)") }
}

struct NuoBotQuery: EntityStringQuery {
    @MainActor
    private func all() async throws -> [NuoBotEntity] {
        guard let api = ReminderNotifications.api() else { throw ShortcutError.notPaired }
        return try await api.bots().compactMap { bot in
            guard let config = bot.published?.config else { return nil }
            return NuoBotEntity(id: bot.id, name: config.name, emoji: config.emoji)
        }
    }

    func entities(for identifiers: [NuoBotEntity.ID]) async throws -> [NuoBotEntity] {
        try await all().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [NuoBotEntity] {
        try await all().filter { $0.name.localizedStandardContains(string) }
    }

    func suggestedEntities() async throws -> [NuoBotEntity] { try await all() }
}

enum ShortcutError: Error, CustomLocalizedStringResourceConvertible {
    case notPaired, unreachable

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notPaired: "Nuo isn't connected to your gateway yet: open the app to pair it."
        case .unreachable: "The Nuo gateway isn't responding."
        }
    }
}

/// Asks a bot in a new conversation and waits a little for its answer; a long one arrives as a notification.
struct AskBotIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask a Bot"
    static let description = IntentDescription("Asks a Nuo bot a question and returns its answer.")

    @Parameter(title: "Bot")
    var bot: NuoBotEntity

    @Parameter(title: "Question", inputOptions: String.IntentInputOptions(multiline: true))
    var question: String

    static var parameterSummary: some ParameterSummary { Summary("Ask \(\.$bot): \(\.$question)") }

    /// Shortcuts gives an intent about 30 s before it gives up on it.
    static let wait: Duration = .seconds(25)

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let api = ReminderNotifications.api() as? NuoClient else { throw ShortcutError.notPaired }
        let conversation = try await api.createConversation(botId: bot.id, useDraft: false)
        try await api.prompt(conversationId: conversation.id, text: question)
        let deadline = ContinuousClock.now + Self.wait
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1500))
            guard let messages = try? await api.messages(conversationId: conversation.id),
                  let last = messages.last, last.role == .assistant, last.stopReason != nil else { continue }
            let answer = last.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return .result(value: answer, dialog: IntentDialog(stringLiteral: String(answer.prefix(1200))))
        }
        let pending = String(localized: "\(bot.name) is preparing its answer: you'll get it as a notification.")
        return .result(value: pending, dialog: IntentDialog(stringLiteral: pending))
    }
}

struct OpenBotIntent: AppIntent {
    static let title: LocalizedStringResource = "New Conversation"
    static let description = IntentDescription("Opens Nuo on a new conversation with a bot.")
    static let openAppWhenRun = true

    @Parameter(title: "Bot")
    var bot: NuoBotEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.open(url: NuoLink.newConversation(botId: bot.id).url)
        return .result()
    }
}

struct TalkToBotIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to a Bot"
    static let description = IntentDescription("Opens Nuo voice mode with a bot.")
    static let openAppWhenRun = true

    @Parameter(title: "Bot")
    var bot: NuoBotEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.open(url: NuoLink.voice(botId: bot.id).url)
        return .result()
    }
}

struct NuoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskBotIntent(),
            phrases: ["Ask \(\.$bot) in \(.applicationName)", "Ask \(\.$bot) a question with \(.applicationName)", "Ask a bot in \(.applicationName)"],
            shortTitle: "Ask a Bot",
            systemImageName: "bubble.left.and.text.bubble.right")
        AppShortcut(
            intent: TalkToBotIntent(),
            phrases: ["Talk to \(\.$bot) with \(.applicationName)", "\(.applicationName) voice mode"],
            shortTitle: "Talk to a Bot",
            systemImageName: "waveform")
        AppShortcut(
            intent: OpenBotIntent(),
            phrases: ["New conversation with \(\.$bot) in \(.applicationName)", "Open \(\.$bot) in \(.applicationName)"],
            shortTitle: "New Conversation",
            systemImageName: "plus.bubble")
    }
}

extension NuoClient {
    /// The share sheet's route, without the socket: an intent may run while the app is not on screen.
    func prompt(conversationId: String, text: String) async throws {
        struct Body: Encodable { let text: String }
        struct Accepted: Decodable { let messageId: String }
        let _: Accepted = try await request("POST", "/api/conversations/\(conversationId)/prompt", body: Body(text: text))
    }
}
