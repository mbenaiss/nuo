import ActivityKit
import Foundation
import UIKit
import WidgetKit

/// Drives one Live Activity per conversation from the socket events, and reloads widgets when a reply ends.
/// Once the app is suspended, the gateway takes over through ActivityKit push: it updates the activity while
/// tools run and ends it with an alert when the answer is ready.
@MainActor
final class LiveActivityCenter {
    static let shared = LiveActivityCenter()

    private typealias State = NuoActivityAttributes.ContentState

    private struct Turn {
        let activityId: String
        var state: State
        var answer = ""
        /// `answer` grew since `state.preview` was derived from it.
        var previewStale = false
        var lastPush = Date.distantPast
        /// The step `state.currentTool` names, so a late `tool.detail` of an earlier step leaves it alone.
        var currentToolCallId: String?
    }

    private var turns: [String: Turn] = [:]
    private var pushTokens: [String: String] = [:]
    private var pendingPush: [String: Task<Void, Never>] = [:]
    private var listeners: [Task<Void, Never>] = []
    private weak var transport: (any LiveTransport)?
    private var api: (any NuoAPI)?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var widgetReload: Task<Void, Never>?

    private static let minPushInterval: TimeInterval = 1
    private static let staleAfter: TimeInterval = 90
    private static let dismissAfter: TimeInterval = 5 * 60

    private init() {
        WidgetIntentBridge.cancelTurn = { [weak self] id in await self?.cancel(conversationId: id) ?? false }
    }

    /// Activities left over by a previous process can no longer be updated: end them.
    func endStaleActivities() {
        let tracked = Set(turns.values.map(\.activityId))
        Self.endActivities { !tracked.contains($0.id) }
    }

    func attach(transport: any LiveTransport, api: any NuoAPI) {
        listeners.forEach { $0.cancel() }
        self.transport = transport
        self.api = api
        let events = transport.events()
        let reconnects = transport.reconnects()
        listeners = [
            Task { [weak self] in
                for await event in events { self?.handle(event) }
            },
            Task { [weak self] in
                for await _ in reconnects { await self?.reconcile() }
            },
        ]
    }

    // MARK: - Turn lifecycle

    func begin(bot: Bot, conversationId: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = State(phase: .thinking, steps: 0, startedAt: .now)
        if var turn = turns[conversationId],
           Activity<NuoActivityAttributes>.activities.contains(where: { $0.id == turn.activityId && $0.activityState == .active }) {
            turn.state = state
            turn.answer = ""
            turns[conversationId] = turn
            push(conversationId, force: true)
            // The gateway forgets a token when it ends the turn; the same activity runs a new one.
            if let token = pushTokens[turn.activityId], let api {
                Task { try? await api.registerLiveActivity(conversationId: conversationId, pushToken: token, environment: APNSEnvironment.current) }
            }
            return
        }
        Self.endActivities { $0.attributes.conversationId == conversationId }
        let config = bot.config
        let attributes = NuoActivityAttributes(
            botId: bot.id, botName: config?.name ?? "Bot", botEmoji: config?.emoji ?? "✨",
            botColor: config?.color ?? "#EFECE6", conversationId: conversationId)
        do {
            let activity = try Activity.request(
                attributes: attributes, content: ActivityContent(state: state, staleDate: staleDate), pushType: .token)
            turns[conversationId] = Turn(activityId: activity.id, state: state)
            registerPushToken(activityId: activity.id, conversationId: conversationId)
        } catch {
            return
        }
        if UIApplication.shared.applicationState == .background { beginBackgroundWindow() }
    }

    private func registerPushToken(activityId: String, conversationId: String) {
        guard let api else { return }
        Task.detached {
            guard let activity = Activity<NuoActivityAttributes>.activities.first(where: { $0.id == activityId }) else { return }
            for await data in activity.pushTokenUpdates {
                let token = data.map { String(format: "%02x", $0) }.joined()
                await MainActor.run { LiveActivityCenter.shared.pushTokens[activityId] = token }
                try? await api.registerLiveActivity(conversationId: conversationId, pushToken: token, environment: APNSEnvironment.current)
            }
        }
    }

    /// The prompt never reached the gateway.
    func abort(conversationId: String, message: String) {
        finish(conversationId, phase: .failed, steps: nil, preview: message)
    }

    func cancel(conversationId: String) async -> Bool {
        if let transport, transport.connectionState == .connected {
            do {
                try await transport.send(.cancel(conversationId: conversationId))
                return true
            } catch {}
        }
        try? await WidgetGateway.current(scope: .watch)?.cancel(conversationId: conversationId)
        finish(conversationId, phase: .cancelled, steps: nil, preview: nil)
        return true
    }

    // MARK: - Events

    private func handle(_ event: ServerEvent) {
        if case let .messageEnd(conversationId, _, _, steps, stopReason, _, _, _) = event {
            scheduleWidgetReload()
            let phase: State.Phase = switch stopReason {
            case .endTurn: .done
            case .cancelled: .cancelled
            case .error: .failed
            }
            finish(conversationId, phase: phase, steps: steps, preview: nil)
            return
        }
        guard let id = event.conversationId, var turn = turns[id] else { return }
        switch event {
        case .messageStart, .thoughtDelta:
            if turn.state.phase != .working { turn.state.phase = .thinking }
        case let .toolStart(_, _, toolCallId, title, _):
            turn.state.phase = .working
            turn.state.currentTool = title
            turn.currentToolCallId = toolCallId
            turn.state.steps += 1
        case let .toolDetail(_, _, toolCallId, detail):
            guard toolCallId == turn.currentToolCallId, let text = TurnLabels.description(detail, limit: 48) else { return }
            turn.state.currentTool = text
        case .toolEnd:
            break
        case let .messageDelta(_, _, text):
            turn.answer += text
            turn.state.phase = .answering
            turn.previewStale = true
        case let .error(_, message):
            turns[id] = turn
            finish(id, phase: .failed, steps: nil, preview: message)
            return
        case .permissionRequest:
            turn.state.preview = String(localized: "Waiting for your approval.")
        case .messageUser, .messageEnd, .notification, .pong, .context, .notice, .turnPhase, .turnsSnapshot, .deviceRequest, .subagent, .alert:
            return
        }
        let phaseChanged = turns[id]?.state.phase != turn.state.phase || turns[id]?.state.steps != turn.state.steps
        turns[id] = turn
        push(id, force: phaseChanged)
    }

    private func finish(_ conversationId: String, phase: State.Phase, steps: Int?, preview: String?, answer: String? = nil) {
        guard var turn = turns.removeValue(forKey: conversationId) else { return }
        pendingPush.removeValue(forKey: conversationId)?.cancel()
        Self.settlePreview(&turn)
        turn.state.phase = phase
        turn.state.endedAt = .now
        if let steps { turn.state.steps = max(turn.state.steps, steps) }
        if let preview { turn.state.preview = preview }
        turn.state.currentTool = nil
        var alert: AlertConfiguration?
        if phase == .done, let excerpt = WidgetText.excerpt(answer ?? turn.answer) {
            turn.state.answer = excerpt
            turn.state.preview = nil
            if let attributes = Activity<NuoActivityAttributes>.activities.first(where: { $0.id == turn.activityId })?.attributes {
                let title = "\(attributes.botEmoji) \(attributes.botName)"
                let body = WidgetText.excerpt(answer ?? turn.answer, limit: 100) ?? excerpt
                alert = AlertConfiguration(title: LocalizedStringResource(stringLiteral: title), body: LocalizedStringResource(stringLiteral: body), sound: .default)
            }
        }
        let content = ActivityContent(state: turn.state, staleDate: nil)
        let dismissal = ActivityUIDismissalPolicy.after(.now.addingTimeInterval(Self.dismissAfter))
        // An ended activity cannot alert: the final state goes out as an alerting update, then the activity ends quietly.
        let finalAlert = alert
        Self.withActivity(turn.activityId) { activity in
            if let finalAlert { await activity.update(content, alertConfiguration: finalAlert) }
            await activity.end(content, dismissalPolicy: dismissal)
        }
        if turns.isEmpty { endBackgroundWindow() }
    }

    /// The Live Activity already alerted for this conversation's answer, so a local notification can stay silent.
    func hasActivity(conversationId: String) -> Bool {
        turns[conversationId] != nil
            || Activity<NuoActivityAttributes>.activities.contains { $0.attributes.conversationId == conversationId && $0.activityState != .dismissed }
    }

    // ActivityKit throttles frequent local updates; deltas are coalesced to about one per second.
    private func push(_ conversationId: String, force: Bool = false) {
        guard var turn = turns[conversationId] else { return }
        let wait = Self.minPushInterval - Date.now.timeIntervalSince(turn.lastPush)
        if force || wait <= 0 {
            pendingPush.removeValue(forKey: conversationId)?.cancel()
            turn.lastPush = .now
            Self.settlePreview(&turn)
            turns[conversationId] = turn
            let content = ActivityContent(state: turn.state, staleDate: staleDate)
            Self.withActivity(turn.activityId) { await $0.update(content) }
            return
        }
        guard pendingPush[conversationId] == nil else { return }
        pendingPush[conversationId] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.pendingPush[conversationId] = nil
            self?.push(conversationId, force: true)
        }
    }

    private var staleDate: Date { .now.addingTimeInterval(Self.staleAfter) }

    /// Derived only when the state goes out: on every delta it rescanned the whole answer on the main thread
    /// (several ms per token for a long answer).
    private static func settlePreview(_ turn: inout Turn) {
        guard turn.previewStale else { return }
        turn.previewStale = false
        turn.state.preview = WidgetText.lastSentence(turn.answer) ?? turn.state.preview
    }

    /// After a socket drop, events may have been missed: settle turns the gateway already finished.
    func reconcile() async {
        guard let api else { return }
        for id in turns.keys {
            guard let messages = try? await api.messages(conversationId: id),
                  let last = messages.last, last.role == .assistant, let stopReason = last.stopReason
            else { continue }
            let phase: State.Phase = switch stopReason {
            case .endTurn: .done
            case .cancelled: .cancelled
            case .error: .failed
            }
            let preview = phase == .done ? nil : WidgetText.lastSentence(last.text)
            finish(id, phase: phase, steps: last.steps?.count, preview: preview, answer: last.text)
        }
        scheduleWidgetReload()
    }

    private func scheduleWidgetReload() {
        widgetReload?.cancel()
        widgetReload = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    // MARK: - Background

    /// Keeps the socket alive for the short window iOS grants, so the activity can follow the end of the turn.
    func sceneDidChange(active: Bool) {
        if active {
            endBackgroundWindow()
            Task { await reconcile() }
        } else if !turns.isEmpty {
            beginBackgroundWindow()
        }
    }

    private func beginBackgroundWindow() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: AppIdentity.local(.turnTask)) { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundWindow() }
        }
    }

    private func endBackgroundWindow() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // Activity is not Sendable: look it up again off the main actor rather than sending it across.
    nonisolated private static func withActivity(_ id: String, _ body: @escaping @Sendable (Activity<NuoActivityAttributes>) async -> Void) {
        Task.detached {
            for activity in Activity<NuoActivityAttributes>.activities where activity.id == id { await body(activity) }
        }
    }

    nonisolated private static func endActivities(where match: @escaping @Sendable (Activity<NuoActivityAttributes>) -> Bool) {
        Task.detached {
            for activity in Activity<NuoActivityAttributes>.activities where match(activity) {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
