import Foundation
import Observation

/// Running turns rebuilt from the socket events, the same way the gateway builds `turns.snapshot`.
struct TurnLedger {
    private(set) var turns: [String: TurnSnapshot] = [:]

    mutating func apply(_ event: ServerEvent) {
        switch event {
        case let .turnsSnapshot(list):
            turns = Dictionary(list.map { ($0.conversationId, $0) }, uniquingKeysWith: { _, last in last })
        case let .messageStart(conversationId, messageId, at, botId, phase):
            turns[conversationId] = TurnSnapshot(
                conversationId: conversationId, botId: botId ?? turns[conversationId]?.botId ?? "", messageId: messageId,
                startedAt: at, phase: phase ?? .thinking, text: "", steps: [])
        case let .messageEnd(conversationId, messageId, _, _, _, _, _, _):
            if turns[conversationId]?.messageId == messageId { turns[conversationId] = nil }
        default:
            guard let id = event.conversationId, var turn = turns[id] else { return }
            Self.reduce(&turn, event)
            turns[id] = turn
        }
    }

    func turn(_ conversationId: String) -> TurnSnapshot? { turns[conversationId] }

    private static func reduce(_ turn: inout TurnSnapshot, _ event: ServerEvent) {
        func running() -> Bool { turn.steps.contains { $0.status == .running } }
        switch event {
        case let .messageDelta(_, messageId, text) where messageId == turn.messageId:
            turn.text += text
            if turn.permission == nil, !running() { turn.phase = .answering }
        case let .thoughtDelta(_, messageId, text) where messageId == turn.messageId:
            turn.thoughts = (turn.thoughts ?? "") + text
            if turn.phase == .queued { turn.phase = .thinking }
        case let .toolStart(_, messageId, toolCallId, title, kind) where messageId == turn.messageId:
            if !turn.steps.contains(where: { $0.toolCallId == toolCallId }) {
                turn.steps.append(ToolStep(toolCallId: toolCallId, title: title, kind: kind, status: .running))
            }
            if turn.permission == nil { turn.phase = .working }
        case let .toolDetail(_, messageId, toolCallId, detail) where messageId == turn.messageId:
            if let index = turn.steps.firstIndex(where: { $0.toolCallId == toolCallId }) { turn.steps[index].detail = detail }
        case let .toolEnd(_, messageId, toolCallId, status, durationMs) where messageId == turn.messageId:
            if let index = turn.steps.firstIndex(where: { $0.toolCallId == toolCallId }) {
                turn.steps[index].status = status
                turn.steps[index].durationMs = durationMs
            }
            if turn.permission == nil, !running() { turn.phase = .thinking }
        case let .permissionRequest(_, requestId, title, options, offer):
            turn.permission = TurnSnapshot.Permission(requestId: requestId, title: title, options: options, tool: offer?.tool, rules: offer?.rules)
            turn.phase = .waitingPermission
        case let .turnPhase(_, messageId, phase) where messageId == turn.messageId:
            turn.phase = phase
            if phase != .waitingPermission { turn.permission = nil }
        default:
            break
        }
        turn.currentTool = turn.steps.last { $0.status == .running }?.title
    }
}

/// What a list row needs to show a running turn; changes far less often than the turn's text.
struct TurnBadge: Equatable, Sendable {
    let conversationId: String
    let botId: String
    let messageId: String
    let startedAt: Date
    let phase: TurnPhase
    let currentTool: String?
    /// What the running tool does in words, when the agent described it (`tool.detail`).
    let currentToolDetail: String?
    let steps: Int

    init(_ turn: TurnSnapshot) {
        conversationId = turn.conversationId
        botId = turn.botId
        messageId = turn.messageId
        startedAt = turn.startedAt
        phase = turn.phase
        currentTool = turn.currentTool
        currentToolDetail = turn.steps.last { $0.status == .running }?.detail
        steps = turn.steps.count
    }

    init(conversationId: String, botId: String, active: ActiveTurn) {
        self.conversationId = conversationId
        self.botId = botId
        messageId = active.messageId
        startedAt = active.startedAt
        phase = active.phase
        currentTool = active.currentTool
        currentToolDetail = nil
        steps = active.steps
    }
}

/// Which conversations have a turn running right now, app-wide (bots home, sidebar, conversation lists, open chats).
/// Fed by every socket event and by `turns.snapshot` on each (re)connection; before the first snapshot the
/// REST fields (`Bot.activeTurns`, `Conversation.activeTurn`) stand in.
@MainActor
@Observable
final class TurnTracker {
    private(set) var badges: [String: TurnBadge] = [:]
    /// A snapshot came on the current connection: `badges` is complete, REST hints are stale.
    private(set) var synced = false

    @ObservationIgnored private(set) var ledger = TurnLedger()
    @ObservationIgnored private var listeners: [Task<Void, Never>] = []
    @ObservationIgnored private weak var transport: (any LiveTransport)?

    func attach(_ transport: any LiveTransport) {
        guard self.transport !== transport else { return }
        listeners.forEach { $0.cancel() }
        self.transport = transport
        ledger = TurnLedger()
        badges = [:]
        synced = false
        let events = transport.events()
        let reconnects = transport.reconnects()
        listeners = [
            Task { [weak self] in
                for await event in events { self?.handle(event) }
            },
            Task { [weak self] in
                for await _ in reconnects { self?.synced = false }
            },
        ]
    }

    func turn(conversationId: String) -> TurnSnapshot? { ledger.turn(conversationId) }

    func badge(conversationId: String) -> TurnBadge? { badges[conversationId] }

    /// Running turns of a bot, most recent first. Falls back on the bot's REST counters until the first snapshot.
    func badges(for bot: Bot) -> [TurnBadge] {
        let live = badges.values.filter { $0.botId == bot.id }.sorted { $0.startedAt > $1.startedAt }
        return live
    }

    func isRunning(_ bot: Bot) -> Bool {
        if badges.values.contains(where: { $0.botId == bot.id }) { return true }
        return !synced && (bot.activeTurns ?? 0) > 0
    }

    /// The conversation to open from a bot card that shows « en cours ».
    func runningConversation(for bot: Bot) -> String? {
        badges(for: bot).first?.conversationId ?? (synced ? nil : bot.activeConversationId)
    }

    func badge(for conversation: Conversation) -> TurnBadge? {
        if let live = badges[conversation.id] { return live }
        guard !synced, let active = conversation.activeTurn else { return nil }
        return TurnBadge(conversationId: conversation.id, botId: conversation.botId, active: active)
    }

    private func handle(_ event: ServerEvent) {
        switch event {
        case .messageStart, .messageEnd, .turnsSnapshot, .toolStart, .toolDetail, .toolEnd, .permissionRequest, .turnPhase, .messageDelta, .thoughtDelta:
            ledger.apply(event)
        default:
            return
        }
        if case .turnsSnapshot = event { synced = true }
        let next = ledger.turns.mapValues(TurnBadge.init)
        if next != badges { badges = next }
    }
}
