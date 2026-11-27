import Foundation
import Observation
import UniformTypeIdentifiers

struct PendingAttachment: Identifiable, Equatable {
    let id = UUID()
    /// JPEG for an image, the raw bytes for a file.
    let data: Data
    let mime: String
    /// Set for a file, which the gateway saves in the bot's folder; nil for an image.
    let fileName: String?

    init(jpeg: Data) {
        data = jpeg
        mime = "image/jpeg"
        fileName = nil
    }

    init(file data: Data, name: String, mime: String) {
        self.data = data
        self.mime = mime
        fileName = name
    }
}

extension PendingAttachment {
    /// The gateway's limit for a file (images are re-encoded under 1.5 MB).
    static let maxFileBytes = 50_000_000
    /// An image is re-encoded under 1.5 MB, but its source still has to be read in memory first.
    static let maxImageSourceBytes = 100_000_000
    /// The gateway drops a socket message over 72 MB and base64 makes attachments 4/3 larger; the rest is margin
    /// for the prompt's text and JSON.
    static let maxEncodedBytes = 68_000_000

    /// An image is re-encoded like a pasted one; anything else (Markdown, PDF…) goes as a file.
    static func load(_ url: URL) async -> PendingAttachment? {
        let type = UTType(filenameExtension: url.pathExtension)
        let isImage = type?.conforms(to: .image) == true
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        guard values?.isDirectory != true else { return nil }
        if let size = values?.fileSize, size > (isImage ? maxImageSourceBytes : maxFileBytes) { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        if isImage, let jpeg = await ImageCompressor.jpeg(from: data) {
            return PendingAttachment(jpeg: jpeg)
        }
        guard data.count <= maxFileBytes else { return nil }
        return PendingAttachment(file: data, name: url.lastPathComponent, mime: type?.preferredMIMEType ?? "application/octet-stream")
    }

    /// Back from the encoded form a prompt carries, to put an unsent or queued message back in the composer.
    init?(restoring attachment: Attachment) {
        guard let base64 = attachment.dataBase64, let data = Data(base64Encoded: base64) else { return nil }
        if attachment.kind == "file" {
            self.init(file: data, name: attachment.name ?? String(localized: "file"), mime: attachment.mime)
        } else {
            self.init(jpeg: data)
        }
    }
}

/// What the composer holds: kept aside when the user leaves a chat, put back when they return.
struct ComposerState {
    var draft = ""
    var attachments: [PendingAttachment] = []
    var queued: [QueuedPrompt] = []

    var isEmpty: Bool { draft.isEmpty && attachments.isEmpty && queued.isEmpty }

    mutating func apply(_ change: DetachedComposerChange) {
        switch change {
        case let .draft(text):
            draft = text
        case let .prompt(prompt):
            draft = TranscriptMerge.draft(returning: prompt.text, before: draft)
            attachments += prompt.attachments.compactMap(PendingAttachment.init(restoring:))
        }
    }
}

/// What reaches the composer of a chat after `stop()`, when the screen that left it already kept its composer aside.
enum DetachedComposerChange {
    /// The draft as it now stands: a dictation's last correction lands after the chat was left.
    case draft(String)
    /// A prompt that did not go out (send failed, or « Envoyer maintenant » failed), back into the composer.
    case prompt(QueuedPrompt)
}

struct PermissionPrompt: Identifiable, Equatable {
    let id: String
    let title: String
    let options: [PermissionOption]
}

/// The user message just submitted, until its turn ends: « Envoi… » then « Envoyé ».
struct OutgoingPrompt: Equatable {
    let messageId: String
    var sent = false
}

/// State of one open chat: messages, the streaming turn, composer draft and per-conversation model choice.
@MainActor
@Observable
final class ConversationStore {
    private(set) var bot: Bot
    private(set) var conversation: Conversation?
    private(set) var messages: [Message] = []
    private(set) var isLoading = false
    private(set) var isRunning = false
    private(set) var turnStartedAt: Date?
    private(set) var liveMessageId: String?
    private(set) var isCompacting = false
    private(set) var outgoing: OutgoingPrompt?
    var pendingPermission: PermissionPrompt?
    private(set) var errorMessage: String?
    /// Whether « Réessayer » fits the error: only a prompt that failed to go out or whose answer broke off.
    private(set) var canRetry = false
    var draft = "" {
        didSet {
            if paletteQuery != nil, oldValue != draft { paletteHighlight = 0 }
            if detached, let onDetachedChange, oldValue != draft { onDetachedChange(.draft(draft)) }
        }
    }
    var paletteHighlight = 0
    /// Commands the app runs itself (`open`, `app`); the chat screen presents them.
    var localCommand: LocalCommand?
    var attachments: [PendingAttachment] = []
    /// The Mac folder the bot works in (composer's folder menu), sent with every prompt.
    var folder: PromptFolder?
    /// Messages typed while the bot answers, sent one by one as each turn ends.
    private(set) var queued: [QueuedPrompt] = []
    private(set) var selectedAgent: AgentID?
    private(set) var selectedModel: String?
    private(set) var selectedEffort: String?
    let useDraft: Bool

    @ObservationIgnored private let session: SessionStore
    @ObservationIgnored private let bots: BotsStore
    @ObservationIgnored private var listeners: [Task<Void, Never>] = []
    @ObservationIgnored private var pendingText: [String: String] = [:]
    @ObservationIgnored private var pendingThoughts: [String: String] = [:]
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var lastPrompt: (text: String, attachments: [Attachment])?
    /// Live message rebuilt from a snapshot rather than from every event: refetched once it ends.
    @ObservationIgnored private var adoptedMessageId: String?
    /// When the running prompt left, until its turn ends: a turn whose start never came is detected from it.
    @ObservationIgnored private var promptSentAt: Date?
    @ObservationIgnored private var resumesQueue = false
    @ObservationIgnored private var subscribedTransport: ObjectIdentifier?
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    @ObservationIgnored private var endedTurns = EndedTurns()
    /// Between `stop()` and `start()`: the screen left, and may have kept the composer aside already.
    @ObservationIgnored private(set) var detached = false
    /// Set by a screen that keeps the composer aside when it leaves (Mac stash): after `stop()`, what would come
    /// back into this composer goes there instead, or it would be lost with the store.
    @ObservationIgnored var onDetachedChange: ((DetachedComposerChange) -> Void)?
    /// The gateway stores the attachments (up to 68 MB) before it persists the user message.
    private static let turnStartGrace: TimeInterval = 30

    init(bot: Bot, conversationId: String?, useDraft: Bool, session: SessionStore, bots: BotsStore) {
        self.bot = bot
        self.useDraft = useDraft
        self.session = session
        self.bots = bots
        if let conversationId {
            conversation = Conversation(id: conversationId, botId: bot.id, title: "", useDraft: useDraft, createdAt: Date(), updatedAt: Date())
        }
    }

    var config: BotConfig? { useDraft ? (bot.draft ?? bot.config) : bot.config }
    /// The agent the next turn runs on: picked here, stored on the conversation, or the bot's own.
    var agentID: AgentID? { selectedAgent ?? persistedAgent }
    var agent: AgentInfo? { agentID.flatMap { bots.agent($0) } }
    var model: String? {
        if let selectedModel { return selectedModel }
        // The conversation's model belongs to its stored agent, not to one just picked.
        if agentID == persistedAgent, let model = conversation?.model { return model }
        if agentID == config?.agent { return config?.model }
        return (agent?.models.first { $0.isDefault == true } ?? agent?.models.first)?.id
    }
    var effort: String? {
        if let selectedEffort { return selectedEffort }
        if agentID == persistedAgent, let effort = conversation?.effort { return effort }
        return agentID == config?.agent ? config?.effort : nil
    }
    var modelInfo: ModelInfo? { agent?.models.first { $0.id == model } }
    var modelLabel: String { modelInfo?.name ?? model ?? String(localized: "Model") }
    /// The model, prefixed with the agent when the conversation left the bot's own.
    var brainLabel: String {
        guard let agentID, agentID != config?.agent else { return modelLabel }
        return "\(agent?.name ?? agentID.rawValue) · \(modelLabel)"
    }
    /// Agents the chat can switch to; the current one stays listed even when it went offline.
    var switchableAgents: [AgentInfo] { bots.agents.filter { $0.available || $0.id == agentID } }

    /// Which agent and model wrote an answer, shown under it when they differ from the previous answer's
    /// (or, for the first one, from the bot's own).
    var answerLabels: [String: String] {
        var labels: [String: String] = [:]
        var previous = config.map { ($0.agent, $0.model) }
        for message in messages where message.role == .assistant {
            guard let agent = message.agent else { continue }
            let model = message.model ?? ""
            if previous?.0 != agent || previous?.1 != model {
                let name = bots.agent(agent)?.name ?? agent.rawValue
                labels[message.id] = model.isEmpty ? name : "\(name) · \(bots.modelName(agent: agent, model: model))"
            }
            previous = (agent, model)
        }
        return labels
    }

    /// The user's next message after each answer, from which its question cards read what was picked.
    var replies: [String: String] {
        var replies: [String: String] = [:]
        var next: String?
        for message in messages.withoutTaskPrompts.reversed() {
            if message.role == .user {
                next = message.text
            } else if let next {
                replies[message.id] = next
            }
        }
        return replies
    }

    private var persistedAgent: AgentID? { conversation?.agent ?? config?.agent }
    var context: ContextUsage? { conversation?.context }
    var commands: [BotCommand] {
        let own = config?.commands ?? []
        guard !own.contains(where: { $0.name == BotCommand.compactName }) else { return own }
        let filling = (context?.fraction ?? 0) >= 0.6
        return filling ? [.compact] + own : own + [.compact]
    }

    /// Text after the leading `/` while the user is still typing the command name.
    var paletteQuery: String? {
        guard draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) else { return nil }
        return String(draft.dropFirst()).lowercased()
    }

    var paletteMatches: [BotCommand] {
        guard let query = paletteQuery else { return [] }
        if query.isEmpty { return commands }
        let prefix = commands.filter { $0.name.hasPrefix(query) }
        let other = commands.filter {
            !$0.name.hasPrefix(query) && ($0.name.contains(query) || (query.count >= 3 && $0.description.lowercased().contains(query)))
        }
        return prefix + other
    }

    /// The known command the draft starts with, once its name is complete.
    var typedCommand: BotCommand? {
        guard paletteQuery == nil, draft.hasPrefix("/"), let line = SlashLine.parse(draft) else { return nil }
        return commands.first { $0.name == line.name }
    }

    func pick(_ command: BotCommand) {
        Haptics.selection()
        if command.takesArgs {
            draft = "/\(command.name) "
        } else {
            draft = ""
            run(command, args: "")
        }
    }

    func movePaletteHighlight(_ delta: Int) {
        let count = paletteMatches.count
        guard count > 0 else { return }
        paletteHighlight = (paletteHighlight + delta + count) % count
        Haptics.selection()
    }

    func pickHighlighted() -> Bool {
        let matches = paletteMatches
        guard !matches.isEmpty else { return false }
        pick(matches[min(paletteHighlight, matches.count - 1)])
        return true
    }

    func togglePalette() {
        Haptics.selection()
        draft = draft.hasPrefix("/") ? "" : "/" + draft
    }

    private func run(_ command: BotCommand, args: String) {
        switch command.kind {
        case .tool, .prompt:
            send(prompt: args.isEmpty ? "/\(command.name)" : "/\(command.name) \(args)")
        case .open:
            guard let raw = command.action.url, let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else {
                show(String(localized: "Invalid link for /\(command.name)."))
                Haptics.error()
                return
            }
            localCommand = .open(url)
        case .app:
            switch command.appAction {
            case .newConversation: localCommand = .newConversation
            case .voice: localCommand = .voice
            case .barcode: localCommand = .barcode
            case nil:
                show(String(localized: "Unknown action for /\(command.name)."))
                Haptics.error()
            }
        }
    }

    /// Stops at the first visible character: trimming copied the whole draft on every render of a long paste.
    var canSend: Bool { draft.contains { !$0.isWhitespace } || !attachments.isEmpty }

    /// The running turn as the gateway reports it (phase, current tool, steps).
    var turnBadge: TurnBadge? {
        guard isRunning, let id = conversation?.id, let badge = session.turns.badge(conversationId: id),
              liveMessageId == nil || badge.messageId == liveMessageId else { return nil }
        return badge
    }

    /// Phase shown by the status line; nil when no turn runs. A prompt not started yet counts as queued.
    var turnPhase: TurnPhase? {
        guard isRunning, !isCompacting else { return nil }
        if let phase = turnBadge?.phase { return phase }
        if pendingPermission != nil { return .waitingPermission }
        guard let live = liveMessageId, let message = messages.last(where: { $0.id == live }) else { return .queued }
        if message.steps?.contains(where: { $0.status == .running }) == true { return .working }
        return message.text.isEmpty ? .thinking : .answering
    }

    var currentTool: String? {
        if let tool = turnBadge?.currentTool { return tool }
        guard let live = liveMessageId else { return nil }
        return messages.last { $0.id == live }?.steps?.last { $0.status == .running }?.title
    }

    var currentToolDetail: String? {
        if let badge = turnBadge { return badge.currentToolDetail }
        guard let live = liveMessageId else { return nil }
        return messages.last { $0.id == live }?.steps?.last { $0.status == .running }?.detail
    }

    var stepCount: Int {
        if let steps = turnBadge?.steps { return steps }
        guard let live = liveMessageId else { return 0 }
        return messages.last { $0.id == live }?.steps?.count ?? 0
    }

    func start() {
        detached = false
        AnswerNotifier.shared.visibleChat = self
        guard listeners.isEmpty else { return }
        let transport = session.transport
        subscribedTransport = ObjectIdentifier(transport as AnyObject)
        let events = transport.events()
        let reconnects = transport.reconnects()
        listeners.append(Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        })
        listeners.append(Task { [weak self] in
            for await _ in reconnects {
                await self?.reload()
            }
        })
        // The tracker saw every event of a turn that started before this chat opened.
        if let id = conversation?.id, let turn = session.turns.turn(conversationId: id) { adopt(turn) }
        if conversation == nil, resumesQueue {
            resumesQueue = false
            sendNextQueued()
        }
        Task { await reload(showSpinner: true) }
    }

    /// The queue waits for the next `start()`: a screen that kept the composer aside sends it from there.
    func stop() {
        detached = true
        if AnswerNotifier.shared.visibleChat === self { AnswerNotifier.shared.visibleChat = nil }
        listeners.forEach { $0.cancel() }
        listeners.removeAll()
    }

    /// Pairing again replaces the socket; an open chat must follow it or it never hears from its turns again.
    func resubscribeIfTransportChanged() {
        guard !listeners.isEmpty, subscribedTransport != ObjectIdentifier(session.transport as AnyObject) else { return }
        stop()
        start()
    }

    func update(bot updated: Bot) {
        guard updated.id == bot.id, updated != bot else { return }
        bot = updated
    }

    var composerState: ComposerState { ComposerState(draft: draft, attachments: attachments, queued: queued) }

    /// A restored queue goes out once this chat knows that no turn runs.
    func restore(_ state: ComposerState) {
        draft = state.draft
        attachments = state.attachments
        queued = state.queued
        resumesQueue = !state.queued.isEmpty
    }

    func reload(showSpinner: Bool = false) async {
        guard let id = conversation?.id else { return }
        if showSpinner && messages.isEmpty { isLoading = true }
        defer { isLoading = false }
        let liveBefore = liveMessageId
        let requestedAt = Date()
        let unstartedSince = liveMessageId == nil ? promptSentAt : nil
        let endsBefore = endedTurns.count
        async let detail = fetchConversation(id: id)
        do {
            let fetched = try await session.api.messages(conversationId: id)
            let (fresh, reportsTurn) = await detail
            // Read before a turn ended here: it lacks the final answer and still runs that turn.
            if endedTurns.endedSince(endsBefore) {
                await reload()
                return
            }
            if let fresh { apply(fresh) }
            let turn = [session.turns.turn(conversationId: id), fresh?.turn].compactMap { $0 }.first { !endedTurns.isOver($0) }
            let turnKnown = reportsTurn || session.turns.synced
            var neverStarted = false
            if turn == nil, turnKnown, let sent = unstartedSince, sent == promptSentAt, liveMessageId == nil,
               requestedAt.timeIntervalSince(sent) >= Self.turnStartGrace {
                neverStarted = true
            }
            merge(fetched, turn: turn, turnKnown: turnKnown, liveBefore: liveBefore, neverStarted: neverStarted)
            if resumesQueue {
                resumesQueue = false
                if !isRunning { sendNextQueued() }
            }
        } catch {
            if messages.isEmpty { show(error.localizedDescription) }
        }
    }

    /// The single-conversation endpoint carries the running turn in full; older gateways only have the listing,
    /// which carries `context`. The flag says whether the answer tells for sure that no turn runs.
    private func fetchConversation(id: String) async -> (Conversation?, Bool) {
        if let single = try? await session.api.conversation(id: id) { return (single, true) }
        let listed = try? await session.api.conversations(botId: bot.id).first { $0.id == id }
        return (listed, false)
    }

    private func apply(_ fetched: Conversation) {
        var merged = fetched
        merged.turn = nil
        if let context = conversation?.context, let newer = fetched.context, context.updatedAt > newer.updatedAt {
            merged.context = context
        }
        conversation = merged
    }

    private func merge(_ fetched: [Message], turn: TurnSnapshot?, turnKnown: Bool, liveBefore: String?, neverStarted: Bool = false) {
        var next = fetched
        // Sent but not persisted yet: keep the optimistic bubble.
        if let outgoing, let local = messages.first(where: { $0.id == outgoing.messageId }),
           fetched.last(where: { $0.role == .user })?.text != local.text {
            next.append(local)
        }
        if let turn, !fetched.contains(where: { $0.id == turn.messageId }) {
            let current = messages.first { $0.id == turn.messageId }
            if let current, current.text.count >= turn.text.count, current.text.hasPrefix(turn.text) {
                setMessages(next + [current])
                isRunning = true
                liveMessageId = turn.messageId
                turnStartedAt = turn.startedAt
            } else {
                setMessages(next)
                adopt(turn)
            }
            return
        }
        if isRunning, let live = liveMessageId {
            let persisted = fetched.contains { $0.id == live }
            // Only a turn that was already live when the request left can be declared over by its answer.
            if persisted || (turnKnown && liveBefore == live) {
                finishTurn()
            } else if let current = messages.first(where: { $0.id == live }) {
                next.append(current)
            }
        } else if isRunning, neverStarted, let prompt = lastPrompt?.text {
            // The prompt left but its `messageStart` never came (link cut right after sending) and the gateway
            // runs nothing for this conversation. Its user message is persisted before the turn is queued or
            // started: without it the gateway never got the prompt; with it and no answer, the turn still waits.
            let persisted = fetched.lastIndex { $0.role == .user && $0.text == prompt }
            if let persisted, fetched[(persisted + 1)...].contains(where: { $0.role == .assistant }) {
                finishTurn()
            } else if persisted == nil {
                finishTurn(sendsQueued: false)
                show(String(localized: "The answer never arrived: the connection dropped right after sending."), retryable: true)
                Haptics.error()
            }
        } else if isRunning, !turnKnown, let last = fetched.last, last.role == .assistant, last.stopReason != nil,
                  let started = turnStartedAt, last.createdAt >= started {
            finishTurn()
        }
        setMessages(next)
    }

    /// A reload usually brings back what is already shown: the views must not redraw every bubble for it.
    private func setMessages(_ next: [Message]) {
        let reused = TranscriptMerge.reusing(messages, in: next)
        if reused != messages { messages = reused }
    }

    /// Shows a running turn exactly as the gateway has it: text, thoughts, steps and a pending permission.
    private func adopt(_ turn: TurnSnapshot) {
        pendingText[turn.messageId] = nil
        pendingThoughts[turn.messageId] = nil
        isRunning = true
        liveMessageId = turn.messageId
        adoptedMessageId = turn.messageId
        turnStartedAt = turn.startedAt
        var message = Message(
            id: turn.messageId, conversationId: turn.conversationId, role: .assistant, text: turn.text,
            thoughts: turn.thoughts, steps: turn.steps, createdAt: turn.startedAt)
        message.subagents = turn.subagents
        if let index = messages.lastIndex(where: { $0.id == turn.messageId }) {
            if messages[index] != message { messages[index] = message }
        } else {
            messages.append(message)
        }
        if let permission = turn.permission {
            pendingPermission = PermissionPrompt(id: permission.requestId, title: permission.title, options: permission.options)
        } else {
            pendingPermission = nil
        }
    }

    func compact() {
        guard !isRunning else { return }
        submit(text: "/" + BotCommand.compactName, attachments: [])
    }

    // MARK: - Composer actions

    /// Takes effect with the next message; the gateway hands the new agent the turns it has not seen.
    func selectAgent(_ id: AgentID) {
        guard id != agentID else { return }
        selectedAgent = id
        let info = bots.agent(id)
        let model = id == config?.agent ? config?.model : (info?.models.first { $0.isDefault == true } ?? info?.models.first)?.id
        selectedModel = model
        let efforts = info?.models.first { $0.id == model }?.efforts ?? []
        if id == config?.agent, let effort = config?.effort, efforts.contains(effort) {
            selectedEffort = effort
        } else {
            selectedEffort = efforts.contains("medium") ? "medium" : efforts.first
        }
        Haptics.selection()
    }

    func selectModel(_ id: String) {
        selectedModel = id
        if let efforts = agent?.models.first(where: { $0.id == id })?.efforts, let effort, !efforts.contains(effort) {
            selectedEffort = efforts.first
        }
        Haptics.selection()
    }

    var permissionPolicy: PermissionPolicy { config?.permissionPolicy ?? .ask }

    func selectPermissions(_ policy: PermissionPolicy) {
        guard policy != permissionPolicy else { return }
        Haptics.selection()
        Task {
            do {
                let updated = try await session.api.setPermissions(botId: bot.id, policy: policy)
                bot = updated
                bots.upsert(updated)
            } catch {
                show(String(localized: "Permissions not changed: \(error.localizedDescription)"))
            }
        }
    }

    func selectEffort(_ value: String) {
        selectedEffort = value
        Haptics.selection()
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        if attachments.isEmpty, let line = SlashLine.parse(text), let command = commands.first(where: { $0.name == line.name }),
           command.kind == .open || command.kind == .app {
            draft = ""
            run(command, args: line.args)
            return
        }
        let outgoing = attachments.map {
            Attachment(kind: $0.fileName == nil ? "image" : "file", mime: $0.mime, name: $0.fileName,
                       size: $0.fileName == nil ? nil : $0.data.count, dataBase64: $0.data.base64EncodedString(), url: nil)
        }
        let encoded = outgoing.reduce(0) { $0 + ($1.dataBase64?.utf8.count ?? 0) }
        guard encoded <= PendingAttachment.maxEncodedBytes else {
            show(String(localized: "Attachments too large: \(encoded / 1_000_000) MB once encoded, the limit is \(PendingAttachment.maxEncodedBytes / 1_000_000) MB per message. Remove a file."))
            Haptics.error()
            return
        }
        draft = ""
        attachments = []
        if isRunning {
            Haptics.selection()
            queued.append(QueuedPrompt(text: text, attachments: outgoing))
            return
        }
        submit(text: text, attachments: outgoing)
    }

    /// Subagents of this conversation, latest turn first.
    var subagents: [SubagentInfo] { messages.reversed().flatMap { ($0.subagents ?? []).reversed() } }

    var activeSubagentCount: Int { subagents.filter(\.isActive).count }

    /// « Envoyer maintenant »: Claude and Codex take the message into the running answer; the other agents stop it
    /// and answer the message right after. Shown above the live answer, where the gateway stores it.
    func sendNow(_ id: QueuedPrompt.ID) {
        guard let index = queued.firstIndex(where: { $0.id == id }) else { return }
        let prompt = queued.remove(at: index)
        guard isRunning, let conversationId = conversation?.id else {
            submit(text: prompt.text, attachments: prompt.attachments)
            return
        }
        Haptics.send()
        let local = Message(
            id: "local-\(UUID().uuidString)", conversationId: conversationId, role: .user, text: prompt.text,
            attachments: prompt.attachments.isEmpty ? nil : prompt.attachments, createdAt: Date())
        if let live = liveMessageId, let liveIndex = messages.lastIndex(where: { $0.id == live }) {
            messages.insert(local, at: liveIndex)
        } else {
            messages.append(local)
        }
        Task {
            do {
                try await session.transport.send(.prompt(
                    conversationId: conversationId, text: prompt.text, attachments: prompt.attachments,
                    agent: selectedAgent, model: selectedModel, effort: selectedEffort, steer: true, folder: folder))
                bots.touch(botId: bot.id, preview: prompt.text)
            } catch {
                messages.removeAll { $0.id == local.id }
                if detached, let onDetachedChange {
                    onDetachedChange(.prompt(prompt))
                } else {
                    queued.insert(prompt, at: 0)
                }
                show(error.localizedDescription)
            }
        }
    }

    func removeQueued(_ id: QueuedPrompt.ID) {
        queued.removeAll { $0.id == id }
    }

    /// Takes a queued message back into the composer to change it.
    func editQueued(_ id: QueuedPrompt.ID) {
        guard draft.isEmpty, let prompt = queued.first(where: { $0.id == id }) else { return }
        queued.removeAll { $0.id == id }
        draft = prompt.text
        attachments += prompt.attachments.compactMap(PendingAttachment.init(restoring:))
    }

    /// Deferred: the turn's own bookkeeping (merge, reload) must settle before the next message appears.
    private func sendNextQueued() {
        guard !queued.isEmpty else { return }
        guard !detached else {
            resumesQueue = true
            return
        }
        Task { @MainActor [weak self] in
            guard let self, !self.isRunning, !self.queued.isEmpty else { return }
            guard !self.detached else {
                self.resumesQueue = true
                return
            }
            let next = self.queued.removeFirst()
            self.submit(text: next.text, attachments: next.attachments)
        }
    }

    func send(prompt: String) {
        guard !isRunning else { return }
        submit(text: prompt, attachments: [])
    }

    func retry() {
        guard let lastPrompt, !isRunning else { return }
        dismissError()
        if let last = messages.last, last.role == .assistant, last.stopReason == .error {
            messages.removeLast()
        }
        dispatch(text: lastPrompt.text, attachments: lastPrompt.attachments)
    }

    /// The Stop button: a tap in the first seconds of a turn is taken for a slip on Send (StopGuard).
    func stopTapped(now: Date = Date()) {
        guard !StopGuard.ignores(tapAt: now, turnStartedAt: turnStartedAt) else { return }
        cancel()
    }

    /// A prompt still on its way is stopped here: the gateway ignores a cancel for a turn it has not started.
    /// Once sent, the turn stays running until its `messageEnd` or a reload that finds it gone.
    func cancel() {
        Haptics.tap()
        if isRunning, liveMessageId == nil, promptSentAt == nil, let sending = sendTask {
            sending.cancel()
            sendTask = nil
            if let lastPrompt { giveBack(text: lastPrompt.text, attachments: lastPrompt.attachments, overDraft: true) }
            finishTurn(sendsQueued: false)
            return
        }
        guard let id = conversation?.id else { return }
        Task {
            do {
                try await session.transport.send(.cancel(conversationId: id))
            } catch {
                show(String(localized: "Stop not sent: \(error.localizedDescription)"))
            }
        }
    }

    func answerPermission(_ option: PermissionOption) {
        guard let prompt = pendingPermission else { return }
        pendingPermission = nil
        Haptics.tap()
        Task {
            do {
                try await session.transport.send(.permission(requestId: prompt.id, optionId: option.id))
            } catch {
                if isRunning, pendingPermission == nil { pendingPermission = prompt }
                show(String(localized: "Reply not sent: \(error.localizedDescription)"))
            }
        }
    }

    func dismissError() {
        errorMessage = nil
        canRetry = false
    }

    /// For the composer: a file it could not attach.
    func reportAttachmentProblem(_ message: String) {
        show(message)
        Haptics.error()
    }

    private func show(_ message: String, retryable: Bool = false) {
        errorMessage = message
        canRetry = retryable
    }

    /// The voice mode needs a conversation id before the first prompt.
    func ensureConversation() async throws -> String {
        if let id = conversation?.id { return id }
        let created = try await session.api.createConversation(botId: bot.id, useDraft: useDraft)
        conversation = created
        return created.id
    }

    private func submit(text: String, attachments: [Attachment]) {
        Haptics.send()
        dismissError()
        let local = Message(
            id: "local-\(UUID().uuidString)", conversationId: conversation?.id ?? "", role: .user, text: text,
            attachments: attachments.isEmpty ? nil : attachments, createdAt: Date())
        messages.append(local)
        outgoing = OutgoingPrompt(messageId: local.id)
        lastPrompt = (text, attachments)
        dispatch(text: text, attachments: attachments)
    }

    private func dispatch(text: String, attachments: [Attachment]) {
        isRunning = true
        turnStartedAt = Date()
        liveMessageId = nil
        let compacting = SlashLine.parse(text)?.name == BotCommand.compactName
        isCompacting = compacting
        sendTask = Task {
            var conversationId: String?
            do {
                let id = try await ensureConversation()
                try Task.checkCancellation()
                conversationId = id
                AnswerNotifier.shared.remember(conversationId: id, botId: bot.id)
                AnswerNotifier.shared.requestAuthorizationIfNeeded()
                if !compacting { LiveActivityCenter.shared.begin(bot: bot, conversationId: id) }
                try await session.transport.send(.prompt(
                    conversationId: id, text: text, attachments: attachments,
                    agent: selectedAgent, model: selectedModel, effort: selectedEffort, voice: false, folder: folder))
                // Stopped while the bytes were already on their way: the turn will show up and can be stopped then.
                guard !Task.isCancelled else { return }
                sendTask = nil
                outgoing?.sent = true
                promptSentAt = Date()
                bots.touch(botId: bot.id, preview: text)
            } catch {
                if Task.isCancelled {
                    if let conversationId { LiveActivityCenter.shared.abort(conversationId: conversationId, message: String(localized: "Sending canceled.")) }
                    return
                }
                sendTask = nil
                if let conversationId { LiveActivityCenter.shared.abort(conversationId: conversationId, message: error.localizedDescription) }
                failSend(error.localizedDescription, text: text, attachments: attachments)
            }
        }
    }

    // MARK: - Server events

    private func handle(_ event: ServerEvent) {
        if case let .turnsSnapshot(turns) = event {
            applySnapshot(turns)
            return
        }
        guard let id = conversation?.id, event.conversationId == id else { return }
        switch event {
        case .turnsSnapshot:
            break
        case let .turnPhase(_, messageId, phase):
            if messageId == liveMessageId, phase != .waitingPermission { pendingPermission = nil }
        case let .messageStart(_, messageId, at, _, _):
            isRunning = true
            liveMessageId = messageId
            if turnStartedAt == nil { turnStartedAt = at }
            if !messages.contains(where: { $0.id == messageId }) {
                messages.append(Message(id: messageId, conversationId: id, role: .assistant, text: "", steps: [], createdAt: at))
            }
        case let .messageDelta(_, messageId, text):
            pendingText[messageId, default: ""] += text
            scheduleFlush()
        case let .thoughtDelta(_, messageId, text):
            pendingThoughts[messageId, default: ""] += text
            scheduleFlush()
        case let .toolStart(_, messageId, toolCallId, title, kind):
            flush()
            update(messageId) { message in
                var steps = message.steps ?? []
                if !steps.contains(where: { $0.toolCallId == toolCallId }) {
                    steps.append(ToolStep(toolCallId: toolCallId, title: title, kind: kind, status: .running))
                }
                message.steps = steps
            }
        case let .toolDetail(_, messageId, toolCallId, detail):
            update(messageId) { message in
                guard let index = message.steps?.firstIndex(where: { $0.toolCallId == toolCallId }) else { return }
                message.steps?[index].detail = detail
            }
        case let .toolEnd(_, messageId, toolCallId, status, durationMs):
            update(messageId) { message in
                guard let index = message.steps?.firstIndex(where: { $0.toolCallId == toolCallId }) else { return }
                message.steps?[index].status = status
                message.steps?[index].durationMs = durationMs
            }
        case let .subagent(_, messageId, subagent):
            update(messageId) { message in
                var list = message.subagents ?? []
                if let index = list.firstIndex(where: { $0.id == subagent.id }) { list[index] = subagent } else { list.append(subagent) }
                message.subagents = list
            }
        case let .messageEnd(_, messageId, durationMs, _, stopReason, agent, model, _):
            flush()
            update(messageId) { message in
                message.durationMs = durationMs
                message.stopReason = stopReason
                if let agent {
                    message.agent = agent
                    message.model = model
                }
                if let steps = message.steps {
                    message.steps = steps.map { var step = $0; if step.status == .running { step.status = .completed }; return step }
                }
            }
            if let message = messages.first(where: { $0.id == messageId }), !message.text.isEmpty, message.notice == nil {
                let text = message.text
                bots.touch(botId: bot.id, preview: ResponseBlockParser.plainText(text))
            }
            let adopted = adoptedMessageId == messageId
            // The gateway publishes a bot's files when the answer ends and stores the card with their link.
            let publishesFiles = messages.first(where: { $0.id == messageId })?.text.contains("::artifact") == true
            finishTurn(messageId: messageId)
            // Deltas before the snapshot were not seen one by one: take the persisted text.
            if adopted || publishesFiles { Task { await reload() } }
            switch stopReason {
            case .endTurn: Haptics.success()
            case .cancelled: break
            case .error:
                if errorMessage == nil || !canRetry { show(String(localized: "The answer was interrupted."), retryable: true) }
                Haptics.error()
            }
        case let .permissionRequest(_, requestId, title, options):
            Haptics.tap()
            pendingPermission = PermissionPrompt(id: requestId, title: title, options: options)
        case let .error(_, message):
            fail(message)
        case let .context(_, context):
            conversation?.context = context
        case let .notice(_, kind, text, beforeTokens, afterTokens):
            flush()
            let line = Message.noticeLine(kind: kind, text: text, beforeTokens: beforeTokens, afterTokens: afterTokens)
            if kind == "switched" {
                // Persisted just before the user message that switched: keep that order before the next reload.
                let notice = Message(id: "notice-\(UUID().uuidString)", conversationId: id, role: .assistant, text: line, createdAt: Date())
                if let outgoing, let index = messages.lastIndex(where: { $0.id == outgoing.messageId }) {
                    messages.insert(notice, at: index)
                } else {
                    messages.append(notice)
                }
                return
            }
            // The gateway may persist the notice under the live message id: fill that bubble instead of adding one.
            if let live = liveMessageId, let index = messages.lastIndex(where: { $0.id == live }), messages[index].text.isEmpty {
                messages[index].text = line
            } else {
                messages.append(Message(id: "notice-\(UUID().uuidString)", conversationId: id, role: .assistant, text: line, createdAt: Date()))
            }
            if kind == "compacted" {
                Haptics.success()
                if isCompacting { finishTurn() }
            }
        case .notification:
            Task { await reload() }
        case .pong, .deviceRequest, .alert:
            break
        }
    }

    /// Sent on every (re)connection: rebuild the live turn, or notice it ended while the link was down.
    private func applySnapshot(_ turns: [TurnSnapshot]) {
        guard let id = conversation?.id else { return }
        if let turn = turns.first(where: { $0.conversationId == id }) {
            flush()
            adopt(turn)
        } else if isRunning, liveMessageId != nil {
            flush()
            finishTurn()
            Task { await reload() }
        } else if isRunning, promptSentAt != nil {
            // Sent but never started as far as this chat saw: the reload tells whether it ran.
            Task { await reload() }
        }
    }

    private func fail(_ message: String) {
        flush()
        show(message, retryable: true)
        finishTurn(sendsQueued: false)
        Haptics.error()
    }

    /// The prompt never left: back in an empty composer it is not lost, and its bubble would wait for nothing.
    private func failSend(_ message: String, text: String, attachments sent: [Attachment]) {
        let restored = giveBack(text: text, attachments: sent)
        fail(message)
        canRetry = !restored
    }

    /// Back into the composer, its bubble removed. A draft typed meanwhile is never overwritten: without
    /// `overDraft` the prompt then stays out (« Réessayer » sends it), with it the prompt goes on the line above.
    @discardableResult
    private func giveBack(text: String, attachments sent: [Attachment], overDraft: Bool = false) -> Bool {
        if detached, let onDetachedChange {
            onDetachedChange(.prompt(QueuedPrompt(text: text, attachments: sent)))
        } else {
            guard overDraft || !draft.contains(where: { !$0.isWhitespace }) else { return false }
            draft = TranscriptMerge.draft(returning: text, before: draft)
            attachments += sent.compactMap(PendingAttachment.init(restoring:))
        }
        if let local = outgoing?.messageId { messages.removeAll { $0.id == local } }
        return true
    }

    /// After a failure the queue waits: sending it into the same error would drop every message.
    private func finishTurn(sendsQueued: Bool = true, messageId ended: String? = nil) {
        endedTurns.record(ended ?? liveMessageId)
        if sendsQueued { sendNextQueued() }
        isRunning = false
        isCompacting = false
        outgoing = nil
        adoptedMessageId = nil
        liveMessageId = nil
        turnStartedAt = nil
        pendingPermission = nil
        promptSentAt = nil
    }

    private func update(_ messageId: String, _ change: (inout Message) -> Void) {
        guard let index = messages.lastIndex(where: { $0.id == messageId }) else { return }
        change(&messages[index])
    }

    // Deltas arrive faster than SwiftUI can re-render markdown; coalesce them into ~16 updates per second.
    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            self?.flush()
        }
    }

    private func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard !pendingText.isEmpty || !pendingThoughts.isEmpty else { return }
        let thoughts = pendingThoughts
        let chunks = pendingText
        pendingThoughts.removeAll()
        pendingText.removeAll()
        for (messageId, text) in thoughts {
            update(messageId) { $0.thoughts = ($0.thoughts ?? "") + text }
        }
        for (messageId, text) in chunks {
            update(messageId) { $0.text += text }
        }
    }
}
