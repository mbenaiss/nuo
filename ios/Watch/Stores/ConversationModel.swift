import Foundation
import Observation
import WatchKit

/// One conversation on the watch: persisted messages plus the turn in flight.
@MainActor
@Observable
final class ConversationModel {
    struct LiveTurn: Equatable {
        var prompt: String
        /// Off once the stored messages already show the question.
        var showsPrompt = true
        var text = ""
        var currentTool: String?
        var currentToolCallId: String?
        var steps = 0
        let startedAt = Date()
    }

    /// A confirmation the agent waits for, answered in one tap.
    struct Confirmation: Equatable {
        var requestId: String
        var title: String
        var confirm: PermissionOption?
        var cancel: PermissionOption?
    }

    let bot: Bot
    private(set) var conversationId: String?
    private(set) var messages: [Message] = []
    private(set) var live: LiveTurn?
    private(set) var error: String?
    /// Where the request stands, as the iPhone says (locked: a new conversation, or waiting for the unlock).
    private(set) var notice: String?
    private(set) var isLoading = false
    private(set) var confirmation: Confirmation?
    private(set) var isAnswering = false
    /// From the end of speech to the answer on screen, for the last spoken request.
    private(set) var latency: TimeInterval?

    @ObservationIgnored private let session: WatchSession
    @ObservationIgnored private let speaker: Speaker
    @ObservationIgnored private var turn: Task<Void, Never>?
    @ObservationIgnored private var speechEndedAt: Date?

    init(bot: Bot, conversationId: String?, session: WatchSession, speaker: Speaker) {
        self.bot = bot
        self.conversationId = conversationId
        self.session = session
        self.speaker = speaker
    }

    var isRunning: Bool { live != nil }

    func load() async {
        guard let conversationId else { return }
        isLoading = messages.isEmpty
        defer { isLoading = false }
        do {
            messages = try await session.api.messages(conversationId: conversationId)
            error = nil
        } catch {
            if messages.isEmpty { self.error = error.localizedDescription }
        }
    }

    /// A request typed with the watch's keyboard.
    func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, live == nil else { return }
        speaker.stop()
        error = nil
        notice = nil
        latency = nil
        speechEndedAt = nil
        live = LiveTurn(prompt: text)
        WKInterfaceDevice.current().play(.click)
        turn = Task { await run(text) }
    }

    /// A spoken request the iPhone already transcribed and sent: the answer is followed from here.
    func follow(_ delivery: AskCenter.Delivery) {
        guard live == nil else { return }
        speaker.stop()
        error = nil
        notice = nil
        latency = nil
        speechEndedAt = delivery.speechEndedAt
        conversationId = delivery.conversationId
        live = LiveTurn(prompt: delivery.text)
        let known = Set(messages.map(\.id))
        turn = Task {
            await load()
            // The iPhone sent it: the stored question is shown once, not again above the answer.
            if messages.last(where: { $0.role == .user })?.text.trimmingCharacters(in: .whitespacesAndNewlines) == delivery.text.trimmingCharacters(in: .whitespacesAndNewlines) {
                live?.showsPrompt = false
            }
            let stream = session.runner.follow(conversationId: delivery.conversationId, prompt: delivery.text, knownMessageIds: known)
            let outcome = await consume(stream)
            await finish(conversationId: delivery.conversationId, prompt: delivery.text, outcome: outcome)
        }
    }

    func answer(_ option: PermissionOption) {
        guard let confirmation, !isAnswering else { return }
        isAnswering = true
        WKInterfaceDevice.current().play(.click)
        Task {
            defer { isAnswering = false }
            do {
                try await session.runner.answer(requestId: confirmation.requestId, optionId: option.id)
                if self.confirmation?.requestId == confirmation.requestId { self.confirmation = nil }
            } catch {
                self.error = error.localizedDescription
                WKInterfaceDevice.current().play(.failure)
            }
        }
    }

    private func run(_ text: String) async {
        do {
            let id: String
            if let conversationId {
                id = conversationId
            } else {
                id = try await session.api.createConversation(botId: bot.id).id
                conversationId = id
            }
            let known = Set(messages.map(\.id))
            let outcome = await consume(session.runner.run(conversationId: id, text: text, knownMessageIds: known, viaPhone: bot.needsPhone))
            await finish(conversationId: id, prompt: text, outcome: outcome)
        } catch {
            self.error = error.localizedDescription
            live = nil
            WKInterfaceDevice.current().play(.failure)
        }
    }

    private func consume(_ stream: AsyncStream<TurnUpdate>) async -> (durationMs: Int, steps: Int, stopReason: StopReason)? {
        var outcome: (durationMs: Int, steps: Int, stopReason: StopReason)?
        for await update in stream {
            switch update {
            case let .delta(chunk):
                live?.text += chunk
                noteFirstText()
            case let .replace(full):
                live?.text = full
                noteFirstText()
            case let .toolStarted(toolCallId, title):
                live?.currentTool = title
                live?.currentToolCallId = toolCallId
                live?.steps += 1
            case let .toolDetail(toolCallId, detail):
                let text = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                if live?.currentToolCallId == toolCallId, !text.isEmpty { live?.currentTool = text }
            case .toolEnded:
                live?.currentTool = nil
                live?.currentToolCallId = nil
            case let .permission(requestId, title, options, answerable):
                let choice = ConfirmationChoice.pick(options)
                confirmation = answerable
                    ? Confirmation(requestId: requestId, title: title, confirm: choice.confirm, cancel: choice.cancel)
                    : Confirmation(requestId: requestId, title: title, confirm: nil, cancel: nil)
                WKInterfaceDevice.current().play(.notification)
            case .permissionResolved:
                confirmation = nil
            case let .finished(durationMs, steps, stopReason):
                outcome = (durationMs, steps, stopReason)
            case let .failed(message):
                error = message
            case let .notice(text):
                notice = text
            }
        }
        return outcome
    }

    private func noteFirstText() {
        guard let speechEndedAt, latency == nil, live?.text.isEmpty == false else { return }
        latency = Date().timeIntervalSince(speechEndedAt)
        NSLog("Nuo watch ask: answer on screen %.2f s after the end of speech", latency ?? 0)
    }

    private func finish(conversationId: String, prompt: String, outcome: (durationMs: Int, steps: Int, stopReason: StopReason)?) async {
        let streamed = live
        confirmation = nil
        if let fresh = try? await session.api.messages(conversationId: conversationId), !fresh.isEmpty {
            messages = fresh
        } else if let streamed, outcome != nil {
            let now = Date()
            messages.append(Message(id: "local-u-\(now.timeIntervalSince1970)", conversationId: conversationId, role: .user, text: prompt, createdAt: streamed.startedAt))
            messages.append(Message(
                id: "local-a-\(now.timeIntervalSince1970)", conversationId: conversationId, role: .assistant, text: streamed.text,
                durationMs: outcome?.durationMs, stopReason: outcome?.stopReason, createdAt: now))
        }
        live = nil
        if latency == nil, let speechEndedAt, outcome != nil { latency = Date().timeIntervalSince(speechEndedAt) }
        guard let outcome, error == nil else {
            WKInterfaceDevice.current().play(.failure)
            return
        }
        WKInterfaceDevice.current().play(outcome.stopReason == .endTurn ? .success : .failure)
        if let answer = messages.last(where: { $0.role == .assistant }) {
            ComplicationStore.saveLastReply(bot: bot, text: MessageContent.spokenText(answer.text))
            if session.speaksAnswers, outcome.stopReason == .endTurn {
                speaker.speak(MessageContent.spokenText(answer.text))
            }
        }
    }

    func cancel() {
        turn?.cancel()
        live = nil
        confirmation = nil
    }
}
