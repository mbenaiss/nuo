import Foundation
import Observation

/// Pairing state, gateway access and the data shared by every screen of the watch app.
@MainActor
@Observable
final class WatchSession {
    let isDemo: Bool
    private(set) var credentials: WatchCredentials?
    private(set) var bots: [Bot] = []
    private(set) var recents: [Conversation] = []
    private(set) var loadError: String?
    private(set) var isLoading = false

    var speaksAnswers: Bool {
        didSet { UserDefaults.standard.set(speaksAnswers, forKey: Self.speakKey) }
    }

    @ObservationIgnored private(set) var api: any WatchAPI
    @ObservationIgnored private(set) var runner: any WatchTurnRunner
    @ObservationIgnored private var phoneLink: PhoneLink?

    private static let speakKey = "nuo.watch.speaksAnswers"

    init(demo: Bool) {
        isDemo = demo
        speaksAnswers = UserDefaults.standard.object(forKey: Self.speakKey) as? Bool ?? true
        if demo {
            let backend = WatchDemoBackend()
            api = backend
            runner = WatchDemoRunner(backend: backend)
            credentials = WatchCredentials(gatewayURL: URL(string: "https://nuo.example.com")!, token: "demo")
            return
        }
        WatchKeychain.migrate()
        let stored = WatchKeychain.credentials
        credentials = stored
        api = WatchDemoBackend.empty
        runner = WatchDemoRunner(backend: .empty)
        let link = PhoneLink { [weak self] credentials in self?.receive(credentials) }
        phoneLink = link
        if let stored { configure(stored) }
        link.activate()
    }

    var isPaired: Bool { credentials != nil }

    var gatewayHost: String { credentials?.gatewayURL.host() ?? "—" }

    func bot(id: String) -> Bot? { bots.first { $0.id == id } }

    func askPhoneForCredentials() {
        phoneLink?.requestCredentials()
    }

    func load() async {
        guard isPaired else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let fetchedBots = api.bots()
            async let fetchedConversations = api.conversations(botId: nil)
            bots = try await fetchedBots
            recents = Array(try await fetchedConversations.prefix(8))
            loadError = nil
            ComplicationStore.saveBots(bots)
        } catch {
            loadError = error.localizedDescription
        }
    }

    func conversations(botId: String) async -> [Conversation] {
        (try? await api.conversations(botId: botId)) ?? recents.filter { $0.botId == botId }
    }

    private func receive(_ new: WatchCredentials?) {
        guard let new, new != credentials else { return }
        WatchKeychain.save(new)
        credentials = new
        configure(new)
        Task { await load() }
    }

    private func configure(_ credentials: WatchCredentials) {
        let client = WatchClient(baseURL: credentials.gatewayURL, token: credentials.token)
        api = client
        let link = phoneLink
        runner = LiveTurnRunner(api: client, baseURL: credentials.gatewayURL, token: credentials.token, relay: { conversationId, text in
            guard let link else { throw WatchError.offline }
            try await link.relayPrompt(conversationId: conversationId, text: text)
        }, answer: { requestId, optionId in
            guard let link else { throw WatchError.offline }
            try await link.answerPermission(requestId: requestId, optionId: optionId)
        })
    }
}
