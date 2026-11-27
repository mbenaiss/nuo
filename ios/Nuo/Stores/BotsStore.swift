import Foundation
import Observation

/// Bots, the agents/tools catalog and bot lifecycle (create, publish, rollback, delete).
@MainActor
@Observable
final class BotsStore {
    private(set) var bots: [Bot] = []
    private(set) var agents: [AgentInfo] = []
    private(set) var tools: [ToolServer] = []
    private(set) var isLoading = false
    private(set) var loadError: String?

    private let session: SessionStore
    private var api: any NuoAPI { session.api }
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var activityRefresh: Task<Void, Never>?

    init(session: SessionStore) {
        self.session = session
    }

    var recentBots: [Bot] {
        bots.filter { $0.lastMessageAt != nil }.sorted { ($0.lastMessageAt ?? .distantPast) > ($1.lastMessageAt ?? .distantPast) }
    }

    private var pins = BotPins()

    /// Pinned bots first, then the others by last activity.
    var listed: (pinned: [Bot], others: [Bot]) { pins.split(bots) }

    var pinnedFirst: [Bot] { pins.pinnedFirst(bots) }

    func isPinned(_ bot: Bot) -> Bool { pins.isPinned(bot) }

    func setPinned(_ bot: Bot, _ pinned: Bool) { pins.setPinned(bot, pinned, among: bots) }

    func bot(id: String) -> Bot? { bots.first { $0.id == id } }

    func agent(_ id: AgentID) -> AgentInfo? { agents.first { $0.id == id } ?? session.agentStatus(id) }

    func modelName(agent id: AgentID, model: String) -> String {
        agent(id)?.models.first { $0.id == model }?.name ?? model
    }

    func load() async {
        isLoading = bots.isEmpty
        defer { isLoading = false }
        do {
            async let bots = api.bots()
            async let agents = api.agents()
            async let tools = api.tools()
            self.bots = try await bots
            DictationVocabulary.botNames = self.bots.compactMap { $0.config?.name }
            self.agents = (try? await agents) ?? self.agents
            self.tools = (try? await tools) ?? self.tools
            loadError = nil
        } catch {
            loadError = error.localizedDescription
            // A 401/403 here can be Cloudflare, another host or a gateway restart: only a confirmed revocation unpairs.
            if case NuoError.unauthorized = error { session.confirmRevocation() }
        }
    }

    /// Answers also land in conversations no screen shows (scheduled tasks, other devices, bot alerts): the bots'
    /// last activity drives the conversation lists, so it follows every turn the gateway ends.
    func follow(_ transport: any LiveTransport) {
        listener?.cancel()
        let events = transport.events()
        listener = Task { [weak self] in
            for await event in events {
                switch event {
                case .messageEnd, .notification: self?.refreshActivity()
                default: break
                }
            }
        }
    }

    /// Several turns often end together: one request for the burst.
    func refreshActivity() {
        activityRefresh?.cancel()
        activityRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self, let fresh = try? await api.bots(), !Task.isCancelled else { return }
            if fresh != bots { bots = fresh }
        }
    }

    func upsert(_ bot: Bot) {
        if let index = bots.firstIndex(where: { $0.id == bot.id }) {
            bots[index] = bot
        } else {
            bots.append(bot)
        }
    }

    func create(name: String, from source: Bot?) async throws -> Bot {
        let bot = try await api.createBot(name: name, fromBotId: source?.id)
        upsert(bot)
        return bot
    }

    func delete(_ bot: Bot) async throws {
        try await api.deleteBot(id: bot.id)
        bots.removeAll { $0.id == bot.id }
    }

    static let previewLength = 200

    func touch(botId: String, preview: String) {
        guard let index = bots.firstIndex(where: { $0.id == botId }) else { return }
        bots[index].lastMessageAt = Date()
        // Callers pass the whole prompt or answer, which can be hundreds of thousands of characters.
        bots[index].lastMessagePreview = String(preview.prefix(Self.previewLength))
    }
}
