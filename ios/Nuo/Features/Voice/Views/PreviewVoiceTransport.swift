#if DEBUG
import Foundation

/// Fake gateway for previews: answers every prompt with a scripted, streamed reply and tool calls.
@MainActor
final class PreviewVoiceTransport: ChatTransport {
    private var continuations: [AsyncStream<ServerEvent>.Continuation] = []
    private var replyTask: Task<Void, Never>?
    private var counter = 0

    var script = """
    Your recovery is at 71%, so we keep the intervals: 6 × 800 m at 4:35. \
    Warm up for **15 minutes** at an easy pace first.
    ::callout {"text": "Stay hydrated"}
    And remember to drink plenty of water, it is hot this afternoon!
    """

    func send(_ event: ClientEvent) async throws {
        switch event {
        case let .prompt(conversationId, _, _, _, _, _, _, _, _, _):
            replyTask?.cancel()
            counter += 1
            let messageId = "m\(counter)"
            replyTask = Task { [weak self] in await self?.reply(conversationId: conversationId, messageId: messageId) }
        case let .cancel(conversationId):
            replyTask?.cancel()
            emit(.messageEnd(conversationId: conversationId, messageId: "m\(counter)", durationMs: 0, steps: 0, stopReason: .cancelled))
        case .permission, .ping, .turnsSync, .presence:
            break
        }
    }

    func events() -> AsyncStream<ServerEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: ServerEvent.self)
        continuations.append(continuation)
        return stream
    }

    private func reply(conversationId: String, messageId: String) async {
        emit(.messageStart(conversationId: conversationId, messageId: messageId, at: .now, botId: nil, phase: .thinking))
        emit(.toolStart(conversationId: conversationId, messageId: messageId, toolCallId: "t1", title: "whoop_today", kind: "fetch"))
        guard await pause(0.9) else { return }
        emit(.toolEnd(conversationId: conversationId, messageId: messageId, toolCallId: "t1", status: .completed, durationMs: 900))
        emit(.toolStart(conversationId: conversationId, messageId: messageId, toolCallId: "t2", title: "week_plan", kind: "fetch"))
        guard await pause(0.6) else { return }
        emit(.toolEnd(conversationId: conversationId, messageId: messageId, toolCallId: "t2", status: .completed, durationMs: 600))
        for word in script.split(separator: " ", omittingEmptySubsequences: false) {
            emit(.messageDelta(conversationId: conversationId, messageId: messageId, text: word + " "))
            guard await pause(0.06) else { return }
        }
        emit(.messageEnd(conversationId: conversationId, messageId: messageId, durationMs: 4000, steps: 2, stopReason: .endTurn))
    }

    private func pause(_ seconds: Double) async -> Bool {
        try? await Task.sleep(for: .seconds(seconds))
        return !Task.isCancelled
    }

    private func emit(_ event: ServerEvent) {
        continuations.forEach { $0.yield(event) }
    }

    static let sampleBot = Bot(
        id: "coach",
        published: BotVersion(
            version: 1,
            config: BotConfig(
                name: "Coach",
                emoji: "🏃",
                color: "#F26B3A",
                description: "Meals, workouts, WHOOP",
                agent: .claude,
                model: "claude-opus-5-5",
                instructions: "",
                toolServers: [],
                permissionPolicy: .auto
            ),
            publishedAt: .now
        ),
        createdAt: .now,
        updatedAt: .now
    )
}
#endif
