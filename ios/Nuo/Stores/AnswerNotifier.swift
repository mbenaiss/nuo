import Foundation
import Observation
import UserNotifications

struct AnswerBanner: Identifiable, Equatable {
    let id: String
    let conversationId: String
    let botId: String
    let botName: String
    let emoji: String
    let color: String
    let text: String
}

/// Tells the user an answer arrived when they are not looking at it: a local notification while the app is in the
/// background (the socket only lives for the short background window iOS grants; once the app is suspended the
/// gateway sees the device offline and sends an APNs push instead), an in-app banner while it is active elsewhere.
@MainActor
@Observable
final class AnswerNotifier {
    static let shared = AnswerNotifier()

    nonisolated static let category = "nuo.answer"
    /// A gateway alert with no conversation behind it (script, failed command): nothing to reply to.
    nonisolated static let alertCategory = "nuo.alert"
    nonisolated static let replyAction = "nuo.reply"
    nonisolated static let openAction = "nuo.open"

    private(set) var banner: AnswerBanner?
    /// The chat on screen; its answers need no banner.
    @ObservationIgnored weak var visibleChat: ConversationStore?

    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private weak var transport: (any LiveTransport)?
    @ObservationIgnored private var api: (any NuoAPI)?
    @ObservationIgnored private weak var bots: BotsStore?
    @ObservationIgnored private var answers: [String: String] = [:]
    @ObservationIgnored private var owners: [String: String] = [:]
    @ObservationIgnored private var bannerDismiss: Task<Void, Never>?

    private init() {}

    static func registerCategories(extra: [UNNotificationCategory] = []) {
        let reply = UNTextInputNotificationAction(
            identifier: replyAction, title: String(localized: "notification.reply", defaultValue: "Reply"), options: [],
            textInputButtonTitle: String(localized: "Send"), textInputPlaceholder: String(localized: "Your reply…"))
        let open = UNNotificationAction(identifier: openAction, title: String(localized: "Open"), options: [.foreground])
        let category = UNNotificationCategory(identifier: Self.category, actions: [open, reply], intentIdentifiers: [])
        let alert = UNNotificationCategory(identifier: alertCategory, actions: [open], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories(
            Set([category, alert, ReminderNotifications.notificationCategory] + EventNotifications.notificationCategories + extra))
    }

    func attach(transport: any LiveTransport, api: any NuoAPI, bots: BotsStore) {
        listener?.cancel()
        self.transport = transport
        self.api = api
        self.bots = bots
        let events = transport.events()
        listener = Task { [weak self] in
            for await event in events { await self?.handle(event) }
        }
    }

    /// Asked on the first prompt, when the reason for notifications is obvious, rather than at launch.
    func requestAuthorizationIfNeeded() {
        // Scripted screenshot runs must not be covered by the system prompt.
        guard !ProcessInfo.processInfo.arguments.contains("-demoScreen") else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            await MainActor.run { PushManager.shared.refreshRegistration() }
        }
    }

    func remember(conversationId: String, botId: String) {
        owners[conversationId] = botId
    }

    // MARK: - Events

    private func handle(_ event: ServerEvent) async {
        switch event {
        case let .messageStart(conversationId, _, _, _, _):
            answers[conversationId] = ""
        case let .messageDelta(conversationId, _, text):
            answers[conversationId, default: ""] += text
        case let .notice(conversationId, _, _, _, _):
            answers[conversationId] = nil
        case let .messageEnd(conversationId, messageId, _, _, stopReason, _, _, scheduled):
            guard let text = answers.removeValue(forKey: conversationId), stopReason == .endTurn, !scheduled,
                  let excerpt = WidgetText.excerpt(text, limit: 100)
            else { return }
            await announce(conversationId: conversationId, messageId: messageId, excerpt: excerpt)
        default:
            break
        }
    }

    private func announce(conversationId: String, messageId: String, excerpt: String) async {
        let active = PlatformApp.isActive
        if active, visibleChat?.conversation?.id == conversationId { return }
        guard let bot = await bot(for: conversationId) else { return }
        let config = bot.config
        let name = config?.name ?? "Bot"
        let emoji = config?.emoji ?? "✨"
        if active {
            show(AnswerBanner(
                id: messageId, conversationId: conversationId, botId: bot.id, botName: name, emoji: emoji,
                color: config?.color ?? "#EFECE6", text: excerpt))
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "\(emoji) \(name)"
        content.body = excerpt
        content.threadIdentifier = bot.id
        content.categoryIdentifier = Self.category
        content.userInfo = ["conversationId": conversationId, "botId": bot.id]
        // The Live Activity's alert already played a sound for this answer.
        content.sound = LiveActivityCenter.shared.hasActivity(conversationId: conversationId) ? nil : .default
        let request = UNNotificationRequest(identifier: messageId, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func bot(for conversationId: String) async -> Bot? {
        if owners[conversationId] == nil, let api {
            for conversation in (try? await api.conversations(botId: nil)) ?? [] {
                owners[conversation.id] = conversation.botId
            }
        }
        guard let botId = owners[conversationId] else { return nil }
        return bots?.bot(id: botId)
    }

    // MARK: - Banner

    func show(_ banner: AnswerBanner) {
        bannerDismiss?.cancel()
        self.banner = banner
        Haptics.success()
        bannerDismiss = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }

    func dismissBanner() {
        bannerDismiss?.cancel()
        banner = nil
    }

    func openBanner() {
        guard let banner else { return }
        dismissBanner()
        Haptics.tap()
        AppRouter.shared.openNotification(conversationId: banner.conversationId, botId: banner.botId)
    }

    // MARK: - Inline reply

    /// Sends a reply typed in a notification. The app may be in the background with the socket closed:
    /// fall back to a one-shot connection.
    func reply(conversationId: String, botId: String?, text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let botId { owners[conversationId] = botId }
        if let botId, let bot = bots?.bot(id: botId) {
            LiveActivityCenter.shared.begin(bot: bot, conversationId: conversationId)
        }
        if let transport, transport.connectionState == .connected,
           (try? await transport.send(.prompt(conversationId: conversationId, text: text))) != nil {
            return
        }
        do {
            guard let gateway = WidgetGateway.current(scope: .watch) else { throw NuoError.offline }
            try await gateway.prompt(conversationId: conversationId, text: text)
        } catch {
            LiveActivityCenter.shared.abort(conversationId: conversationId, message: String(localized: "Reply not sent."))
        }
    }
}
