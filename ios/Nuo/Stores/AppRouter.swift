import Foundation
import Observation

struct ChatTarget: Hashable {
    var botId: String
    var conversationId: String?
    var useDraft = false
    /// Sent once the chat opens (message typed in the home dock).
    var initialPrompt: String?
    /// Distinguishes two "new conversation" pushes of the same bot.
    var token = UUID()
}

enum Route: Hashable {
    case chat(ChatTarget)
    case conversations(botId: String)
    /// A scheduled task's detail, opened from its notification.
    case schedule(taskId: String)
    case settings
}

struct VoiceTarget: Identifiable {
    let id = UUID()
    let bot: Bot
    let conversationId: String
}

struct EditorTarget: Identifiable, Hashable {
    let botId: String
    var id: String { botId }
}

@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()

    var path: [Route] = []
    var editor: EditorTarget?
    var voice: VoiceTarget?
    var showsNewBot = false
    /// Deep link from a notification tap, consumed once the bots are loaded.
    var pendingLink: (conversationId: String?, botId: String?)?
    /// `nuo://` link from a widget or the Live Activity, resolved once the bots are loaded.
    var pendingDeepLink: NuoLink?

    func openChat(botId: String, conversationId: String? = nil, useDraft: Bool = false) {
        path.append(.chat(ChatTarget(botId: botId, conversationId: conversationId, useDraft: useDraft)))
    }

    func openNotification(conversationId: String?, botId: String?) {
        pendingLink = (conversationId, botId)
    }

    /// The run a notification is about: its task's screen opens it, then clears it.
    var focusedRunId: String?

    func openTask(id: String, runId: String? = nil) {
        editor = nil
        voice = nil
        focusedRunId = runId
        path = [.schedule(taskId: id)]
    }

    func resolvePendingLink(bots: [Bot]) {
        guard let link = pendingLink, !bots.isEmpty else { return }
        pendingLink = nil
        editor = nil
        voice = nil
        if let botId = link.botId, bots.contains(where: { $0.id == botId }) {
            path = [link.conversationId.map { .chat(ChatTarget(botId: botId, conversationId: $0)) } ?? .conversations(botId: botId)]
        }
    }

    func open(url: URL) {
        guard let link = NuoLink(url: url) else { return }
        pendingDeepLink = link
    }

    func resolveDeepLink(bots: [Bot], api: any NuoAPI) async {
        guard let link = pendingDeepLink, !bots.isEmpty else { return }
        // A bot created since the list was loaded: the link waits for the next load instead of being dropped.
        if case let .conversation(_, botId?) = link, !bots.contains(where: { $0.id == botId }) { return }
        pendingDeepLink = nil
        editor = nil
        showsNewBot = false
        switch link {
        case let .newConversation(botId):
            guard bots.contains(where: { $0.id == botId }) else { return }
            voice = nil
            path = [.chat(ChatTarget(botId: botId))]
        case let .conversation(id, botId):
            var owner = botId
            if owner == nil {
                owner = (try? await api.conversations(botId: nil))?.first { $0.id == id }?.botId
            }
            guard let owner, bots.contains(where: { $0.id == owner }) else { return }
            voice = nil
            if case let .chat(target)? = path.last, target.conversationId == id { return }
            path = [.chat(ChatTarget(botId: owner, conversationId: id))]
        case let .voice(botId):
            #if os(macOS)
            // The Mac has no voice mode: talking to a bot opens a new conversation with it, typed or dictated.
            guard bots.contains(where: { $0.id == botId }) else { return }
            voice = nil
            path = [.chat(ChatTarget(botId: botId))]
            #else
            guard let bot = bots.first(where: { $0.id == botId }),
                  let conversation = try? await api.createConversation(botId: botId, useDraft: false)
            else { return }
            path = []
            voice = VoiceTarget(bot: bot, conversationId: conversation.id)
            #endif
        }
    }
}
