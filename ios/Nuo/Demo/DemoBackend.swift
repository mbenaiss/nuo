import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// In-memory gateway used with the `-demo` launch argument (previews and screenshots without a gateway).
actor DemoBackend: NuoAPI {
    private var botList: [Bot]
    private var versionsByBot: [String: [BotVersion]]
    private var conversationList: [Conversation]
    private var messagesByConversation: [String: [Message]]
    private let agentList: [AgentInfo]
    private let toolList: [ToolServer]
    private var scheduleList: [ScheduledTask]
    private var runsByTask: [String: [TaskRun]]
    private var memories: [String: BotMemory]
    private var workingTurn: TurnSnapshot?

    init() {
        let seed = DemoSeed.make()
        botList = seed.bots
        versionsByBot = seed.versions
        conversationList = seed.conversations
        messagesByConversation = seed.messages
        agentList = DemoSeed.agents
        toolList = DemoSeed.tools
        let schedules = DemoSeed.schedules()
        scheduleList = schedules.tasks
        runsByTask = schedules.runs
        memories = DemoSeed.memories()
        conversationList += schedules.conversations
        messagesByConversation.merge(schedules.messages) { current, _ in current }
        if DemoLongChat.enabled {
            conversationList.append(DemoLongChat.conversation())
            messagesByConversation[DemoLongChat.conversationId] = DemoLongChat.messages()
        }
        if DemoTurns.enabled {
            let turn = DemoTurns.working
            workingTurn = turn
            messagesByConversation[turn.conversationId, default: []].append(DemoTurns.userMessage)
            if let index = conversationList.firstIndex(where: { $0.id == turn.conversationId }) { conversationList[index].updatedAt = turn.startedAt }
            if let index = botList.firstIndex(where: { $0.id == turn.botId }) {
                botList[index].lastMessageAt = turn.startedAt
                botList[index].lastMessagePreview = DemoTurns.prompt
            }
        }
    }

    private func decorated(_ bot: Bot) -> Bot {
        var bot = bot
        let running = workingTurn?.botId == bot.id
        bot.activeTurns = running ? 1 : 0
        bot.activeConversationId = running ? workingTurn?.conversationId : nil
        return bot
    }

    private func decorated(_ conversation: Conversation, full: Bool = false) -> Conversation {
        var conversation = conversation
        guard let turn = workingTurn, turn.conversationId == conversation.id else { return conversation }
        conversation.activeTurn = DemoTurns.activeTurn
        if full { conversation.turn = turn }
        return conversation
    }

    /// The scripted long turn was stopped: persist what it had written, as the gateway does.
    func endWorkingTurn(stopReason: StopReason) {
        guard var turn = workingTurn else { return }
        workingTurn = nil
        turn.steps = turn.steps.map { var step = $0; if step.status == .running { step.status = .failed }; return step }
        record(conversationId: turn.conversationId, messages: [
            Message(
                id: turn.messageId, conversationId: turn.conversationId, role: .assistant, text: turn.text, thoughts: turn.thoughts,
                steps: turn.steps, durationMs: Int(Date().timeIntervalSince(turn.startedAt) * 1000), stopReason: stopReason, createdAt: turn.startedAt),
        ])
    }

    func health() async throws -> HealthInfo { HealthInfo(ok: true, version: "0.1.0-demo", agents: agentList) }
    func agents() async throws -> [AgentInfo] { agentList }
    func tools() async throws -> [ToolServer] { toolList }
    func machineTools() async throws -> [MachineTool] { DemoSeed.machineTools }
    func bots() async throws -> [Bot] { botList.map(decorated) }

    func bot(id: String) async throws -> Bot {
        guard let bot = botList.first(where: { $0.id == id }) else { throw NuoError.notFound }
        return decorated(bot)
    }

    func createBot(name: String, fromBotId: String?) async throws -> Bot {
        var config = DemoSeed.blankConfig(name: name)
        if let fromBotId, let source = botList.first(where: { $0.id == fromBotId })?.config {
            config = source
            config.name = name
        }
        let bot = Bot(id: "bot-\(UUID().uuidString.prefix(6))", published: nil, draft: config, createdAt: Date(), updatedAt: Date())
        botList.append(bot)
        return bot
    }

    func saveDraft(botId: String, config: BotConfig) async throws -> Bot {
        try mutate(botId) { $0.draft = config }
    }

    func discardDraft(botId: String) async throws -> Bot {
        try mutate(botId) { bot in
            bot.draft = bot.published == nil ? bot.draft : nil
        }
    }

    func setPermissions(botId: String, policy: PermissionPolicy) async throws -> Bot {
        try mutate(botId) { bot in
            bot.draft?.permissionPolicy = policy
            if let published = bot.published {
                var config = published.config
                config.permissionPolicy = policy
                bot.published = BotVersion(version: published.version + 1, config: config, note: String(localized: "Permissions: \(policy.rawValue)"), publishedAt: Date())
            }
        }
    }

    func publish(botId: String, note: String?) async throws -> Bot {
        var versions = versionsByBot[botId] ?? []
        let bot = try mutate(botId) { bot in
            guard let config = bot.draft ?? bot.published?.config else { return }
            let version = BotVersion(version: (bot.published?.version ?? 0) + 1, config: config, note: note, publishedAt: Date())
            bot.published = version
            bot.draft = nil
            versions.insert(version, at: 0)
        }
        versionsByBot[botId] = versions
        return bot
    }

    func versions(botId: String) async throws -> [BotVersion] { versionsByBot[botId] ?? [] }

    func rollback(botId: String, version: Int) async throws -> Bot {
        guard let target = versionsByBot[botId]?.first(where: { $0.version == version }) else { throw NuoError.notFound }
        _ = try mutate(botId) { $0.draft = target.config }
        return try await publish(botId: botId, note: String(localized: "Rolled back to v\(version)"))
    }

    func deleteBot(id: String) async throws {
        botList.removeAll { $0.id == id }
    }

    func conversations(botId: String?) async throws -> [Conversation] {
        conversationList.filter { botId == nil || $0.botId == botId }.sorted { $0.updatedAt > $1.updatedAt }.map { decorated($0) }
    }

    func searchConversations(_ text: String, botId: String?) async throws -> [ConversationSearchHit] {
        let terms = ConversationSearchText.terms(text)
        guard !terms.isEmpty else { return [] }
        return try await conversations(botId: botId).compactMap { conversation in
            if ConversationSearchText.matches(conversation.title, terms) { return ConversationSearchHit(conversation: conversation) }
            guard let message = messagesByConversation[conversation.id]?.first(where: { ConversationSearchText.matches($0.text, terms) }) else { return nil }
            return ConversationSearchHit(conversation: conversation, messageId: message.id, role: message.role,
                                         snippet: ConversationSearchText.excerpt(message.text, around: terms))
        }
    }

    func conversation(id: String) async throws -> Conversation {
        guard let conversation = conversationList.first(where: { $0.id == id }) else { throw NuoError.notFound }
        return decorated(conversation, full: true)
    }

    func createConversation(botId: String, useDraft: Bool) async throws -> Conversation {
        let conversation = Conversation(id: "c-\(UUID().uuidString.prefix(8))", botId: botId, title: Self.newConversationTitle, useDraft: useDraft, createdAt: Date(), updatedAt: Date())
        conversationList.append(conversation)
        messagesByConversation[conversation.id] = []
        return conversation
    }

    private static var newConversationTitle: String { String(localized: "New conversation") }

    func messages(conversationId: String) async throws -> [Message] {
        messagesByConversation[conversationId] ?? []
    }

    func deleteConversation(id: String) async throws {
        conversationList.removeAll { $0.id == id }
        messagesByConversation[id] = nil
    }

    func registerDevice(apnsToken: String, environment: String) async throws {}
    func registerLiveActivity(conversationId: String, pushToken: String, environment: String) async throws {}

    func media(path: String) async throws -> Data {
        if let raw = URLComponents(string: path), raw.path == "/api/docs/raw",
           let file = raw.queryItems?.first(where: { $0.name == "path" })?.value,
           let data = await DemoWorkspace.shared.docFile(file) {
            return data
        }
        if let raw = URLComponents(string: path), raw.path == "/api/data/files",
           let file = raw.queryItems?.first(where: { $0.name == "path" })?.value,
           let data = await DemoWorkspace.shared.dataFile(file) {
            return data
        }
        let seed = abs(path.hashValue)
        func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
        let palettes: [[CGColor]] = [
            [rgb(1, 0.55, 0.3), rgb(0.55, 0.2, 0.45)],
            [rgb(0.35, 0.6, 1), rgb(0.1, 0.2, 0.45)],
            [rgb(0.4, 0.8, 0.55), rgb(0.1, 0.35, 0.3)],
        ]
        let colors = palettes[seed % palettes.count]
        let width = 800, height = 600
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return Data() }
        // CoreGraphics has a bottom-left origin; flip so the drawing matches the top-left coordinates below.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85))
        context.fillEllipse(in: CGRect(x: 520, y: 90, width: 140, height: 140))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.25))
        context.move(to: CGPoint(x: 0, y: 600))
        context.addCurve(to: CGPoint(x: 800, y: 420), control1: CGPoint(x: 250, y: 300), control2: CGPoint(x: 500, y: 560))
        context.addLine(to: CGPoint(x: 800, y: 600))
        context.closePath()
        context.fillPath()
        guard let image = context.makeImage() else { return Data() }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    // MARK: - Scheduled tasks

    func schedules(botId: String?) async throws -> [ScheduledTask] {
        scheduleList.filter { botId == nil || $0.botId == botId }
    }

    func createSchedule(_ draft: ScheduledTaskDraft) async throws -> ScheduledTask {
        let enabled = draft.enabled ?? true
        let action = draft.action ?? .prompt
        let task = ScheduledTask(
            id: "t-\(UUID().uuidString.prefix(6).lowercased())", botId: draft.botId, title: draft.title, action: action,
            prompt: action.type == "command" ? "" : draft.prompt,
            schedule: draft.schedule, enabled: enabled, conversation: draft.conversation ?? "dedicated", conversationId: nil,
            notify: action.type == "command" ? action.notifyOn != "never" : draft.notify ?? true, createdBy: "user",
            nextRunAt: enabled ? ScheduleText.nextRun(draft.schedule, after: Date()) : nil,
            lastRunAt: nil, lastStatus: nil, createdAt: Date(), updatedAt: Date())
        scheduleList.append(task)
        return task
    }

    func updateSchedule(id: String, patch: ScheduledTaskPatch) async throws -> ScheduledTask {
        guard let index = scheduleList.firstIndex(where: { $0.id == id }) else { throw NuoError.notFound }
        var task = scheduleList[index]
        if let title = patch.title { task.title = title }
        if let prompt = patch.prompt { task.prompt = prompt }
        if let schedule = patch.schedule { task.schedule = schedule }
        if let enabled = patch.enabled { task.enabled = enabled }
        if let notify = patch.notify { task.notify = notify }
        if let conversation = patch.conversation { task.conversation = conversation }
        if let action = patch.action {
            task.action = action
            if action.type == "command" { task.prompt = "" }
        }
        if task.isCommand, var action = task.action {
            if patch.action == nil, let notify = patch.notify { action.notifyOn = notify ? (action.notifyOn == "never" ? "failure" : action.notifyOn) : "never" }
            task.action = action
            task.notify = action.notifyOn != "never"
        }
        task.nextRunAt = task.enabled ? ScheduleText.nextRun(task.schedule, after: Date()) : nil
        task.updatedAt = Date()
        scheduleList[index] = task
        return task
    }

    func deleteSchedule(id: String) async throws {
        scheduleList.removeAll { $0.id == id }
        runsByTask[id] = nil
    }

    func runSchedule(id: String) async throws -> TaskRun {
        guard let index = scheduleList.firstIndex(where: { $0.id == id }) else { throw NuoError.notFound }
        let task = scheduleList[index]
        if task.isCommand {
            let run = TaskRun(id: "r-\(UUID().uuidString.prefix(8))", taskId: id, conversationId: "", startedAt: Date(), status: "running")
            runsByTask[id, default: []].insert(run, at: 0)
            scheduleList[index].lastRunAt = run.startedAt
            scheduleList[index].lastStatus = "running"
            Task {
                try? await Task.sleep(for: .seconds(2))
                self.finishCommand(runId: run.id, taskId: id)
            }
            return run
        }
        let conversationId: String
        if task.conversation == "dedicated", let existing = task.conversationId, conversationList.contains(where: { $0.id == existing }) {
            conversationId = existing
        } else {
            let conversation = Conversation(id: "c-\(UUID().uuidString.prefix(8))", botId: task.botId, title: task.title, useDraft: false, createdAt: Date(), updatedAt: Date())
            conversationList.append(conversation)
            conversationId = conversation.id
        }
        let run = TaskRun(id: "r-\(UUID().uuidString.prefix(8))", taskId: id, conversationId: conversationId, startedAt: Date(), status: "running")
        runsByTask[id, default: []].insert(run, at: 0)
        scheduleList[index].lastRunAt = run.startedAt
        scheduleList[index].lastStatus = "running"
        if task.conversation == "dedicated" { scheduleList[index].conversationId = conversationId }
        record(conversationId: conversationId, messages: [Message(id: "m-\(run.id)", conversationId: conversationId, role: .user, text: task.prompt, createdAt: run.startedAt)])
        Task {
            try? await Task.sleep(for: .seconds(3))
            self.finish(runId: run.id, taskId: id)
        }
        return run
    }

    func scheduleRuns(id: String) async throws -> [TaskRun] { runsByTask[id] ?? [] }

    // MARK: - Alerts

    private var alertList: [AlertItem] = [
        AlertItem(
            id: "alert-colis", title: String(localized: "📦 Parcel arrived"), body: String(localized: "Your parcel (48213906) is waiting for you at the pickup point on Rue des Martyrs."),
            destination: AlertDestination(kind: "home"), createdAt: Date().addingTimeInterval(-1_800)),
        AlertItem(
            id: "alert-securite", title: String(localized: "🔐 New device"), body: String(localized: "A MacBook Pro was paired with your gateway."),
            destination: AlertDestination(kind: "settings"), createdAt: Date().addingTimeInterval(-86_400), readAt: Date()),
    ]

    func alerts() async throws -> [AlertItem] { alertList }

    func markAlertsRead(ids: [String]?) async throws {
        let now = Date()
        for index in alertList.indices where ids?.contains(alertList[index].id) ?? true {
            alertList[index].readAt = alertList[index].readAt ?? now
        }
    }

    func deleteAlert(id: String) async throws { alertList.removeAll { $0.id == id } }

    func deleteAlerts(readOnly: Bool) async throws { alertList = readOnly ? alertList.unread : [] }

    // MARK: - Latency

    /// A few slow mornings and steady days per bot, the same on every launch so screenshots match.
    func latency(days: Int, scheduled: Bool) async throws -> LatencyReport {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let report = botList.enumerated().compactMap { index, bot -> BotLatency? in
            guard let config = bot.config else { return nil }
            let base = 1_400 + index * 900
            let daily = (0..<days).compactMap { offset -> LatencyDay? in
                let back = days - 1 - offset
                guard (back + index) % 4 != 3, let date = calendar.date(byAdding: .day, value: -back, to: today) else { return nil }
                let wave = [0, 350, -200, 900, 120, -150, 600][(back + index) % 7]
                let parts = calendar.dateComponents([.year, .month, .day], from: date)
                return LatencyDay(
                    day: String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0),
                    responses: 2 + (back + index) % 5 + (scheduled ? 1 : 0),
                    firstTextMedianMs: base + wave,
                    firstTextP90Ms: (base + wave) * 5 / 2,
                    durationMedianMs: (base + wave) * 6,
                    avgSteps: Double(2 + index % 3)
                )
            }
            guard !daily.isEmpty else { return nil }
            let firstText = daily.compactMap(\.firstTextMedianMs).sorted()
            return BotLatency(
                botId: bot.id, name: config.name, emoji: config.emoji, color: config.color,
                responses: daily.reduce(0) { $0 + $1.responses },
                firstTextMedianMs: firstText[firstText.count / 2],
                firstTextP90Ms: firstText[firstText.count * 9 / 10] * 2,
                firstEventMedianMs: firstText[firstText.count / 2] / 3,
                durationMedianMs: firstText[firstText.count / 2] * 6,
                toolMedianMs: firstText[firstText.count / 2] * 3,
                avgSteps: Double(2 + index % 3) + 0.4,
                daily: daily
            )
        }
        return LatencyReport(days: days, scheduled: scheduled, bots: report.sorted { $0.responses > $1.responses })
    }

    // MARK: - Memory

    func memory(botId: String) async throws -> BotMemory {
        guard botList.contains(where: { $0.id == botId }) else { throw NuoError.notFound }
        return memories[botId] ?? BotMemory(content: "")
    }

    func writeMemory(botId: String, content: String) async throws -> BotMemory {
        guard botList.contains(where: { $0.id == botId }) else { throw NuoError.notFound }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let memory = BotMemory(content: trimmed.isEmpty ? "" : trimmed + "\n", updatedAt: Date())
        memories[botId] = memory
        return memory
    }

    func addMemory(botId: String, fact: String) async throws -> BotMemory {
        let line = fact.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let current = try await memory(botId: botId).content
        let separator = current.isEmpty || current.hasSuffix("\n") ? "" : "\n"
        return try await writeMemory(botId: botId, content: "\(current)\(separator)- \(MemoryDocument.day(Date())) \(line)")
    }

    private func finishCommand(runId: String, taskId: String) {
        guard let runIndex = runsByTask[taskId]?.firstIndex(where: { $0.id == runId }),
              let run = runsByTask[taskId]?[runIndex] else { return }
        let output = DemoSeed.commandOutput(taskId: taskId)
        runsByTask[taskId]?[runIndex].status = "ok"
        runsByTask[taskId]?[runIndex].endedAt = Date()
        runsByTask[taskId]?[runIndex].exitCode = 0
        runsByTask[taskId]?[runIndex].output = output
        runsByTask[taskId]?[runIndex].preview = output.split(separator: "\n").last.map(String.init)
        runsByTask[taskId]?[runIndex].durationMs = Int(Date().timeIntervalSince(run.startedAt) * 1000)
        if let index = scheduleList.firstIndex(where: { $0.id == taskId }) { scheduleList[index].lastStatus = "ok" }
    }

    private func finish(runId: String, taskId: String) {
        guard let runIndex = runsByTask[taskId]?.firstIndex(where: { $0.id == runId }),
              let run = runsByTask[taskId]?[runIndex] else { return }
        let task = scheduleList.first { $0.id == taskId }
        let preview = switch task?.botId {
        case "coach": String(localized: "Recovery 68%: short intervals, 10 × 400 m at 4:20/km, 1 min 30 s recovery.")
        case "cobot": String(localized: "Nothing new since Monday: 4 appointments, the first on Tuesday at 10:00 at the dentist.")
        case "voyages": String(localized: "TO8285 is on time: leaves Rome at 14:40, gate F32, boarding 13:55.")
        default: String(localized: "demo.backend.done", defaultValue: "Done.")
        }
        runsByTask[taskId]?[runIndex].status = "ok"
        runsByTask[taskId]?[runIndex].endedAt = Date()
        runsByTask[taskId]?[runIndex].preview = preview
        if let index = scheduleList.firstIndex(where: { $0.id == taskId }) { scheduleList[index].lastStatus = "ok" }
        record(conversationId: run.conversationId, messages: [
            Message(id: "m-\(runId)-a", conversationId: run.conversationId, role: .assistant, text: preview, durationMs: 3000, stopReason: .endTurn, createdAt: Date()),
        ])
    }

    // MARK: - Used by DemoTransport

    func record(conversationId: String, messages: [Message]) {
        messagesByConversation[conversationId, default: []].append(contentsOf: messages)
        guard let index = conversationList.firstIndex(where: { $0.id == conversationId }) else { return }
        conversationList[index].updatedAt = Date()
        if conversationList[index].title == Self.newConversationTitle, let first = messages.first(where: { $0.role == .user }) {
            conversationList[index].title = String(first.text.prefix(40))
        }
        if let botIndex = botList.firstIndex(where: { $0.id == conversationList[index].botId }), let last = messages.last {
            botList[botIndex].lastMessageAt = Date()
            botList[botIndex].lastMessagePreview = ResponseBlockParser.plainText(last.text)
        }
    }

    /// Grows the demo context after a turn, as the gateway's `context` event would report it.
    func addContext(conversationId: String, tokens: Int) -> ContextUsage? {
        guard let index = conversationList.firstIndex(where: { $0.id == conversationId }) else { return nil }
        var context = conversationList[index].context ?? ContextUsage(usedTokens: 6_000, maxTokens: 200_000, compactions: 0, updatedAt: Date())
        context.usedTokens = min(context.maxTokens ?? .max, context.usedTokens + tokens)
        context.updatedAt = Date()
        conversationList[index].context = context
        return context
    }

    func compact(conversationId: String) -> (before: Int, context: ContextUsage)? {
        guard let index = conversationList.firstIndex(where: { $0.id == conversationId }) else { return nil }
        var context = conversationList[index].context ?? ContextUsage(usedTokens: 6_000, maxTokens: 200_000, compactions: 0, updatedAt: Date())
        let before = context.usedTokens
        context.usedTokens = max(3_000, before / 20)
        context.compactions += 1
        context.updatedAt = Date()
        conversationList[index].context = context
        return (before, context)
    }

    func botId(conversationId: String) -> String? {
        conversationList.first { $0.id == conversationId }?.botId
    }

    private func mutate(_ botId: String, _ change: (inout Bot) -> Void) throws -> Bot {
        guard let index = botList.firstIndex(where: { $0.id == botId }) else { throw NuoError.notFound }
        change(&botList[index])
        botList[index].updatedAt = Date()
        return botList[index]
    }
}
