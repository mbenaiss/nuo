import Foundation

/// `-demo -demoTurnWorking`: Cobot has been working for a few minutes in its deployment conversation when the app opens,
/// as after reopening the app during a long turn. It runs until it is stopped.
enum DemoTurns {
    static let conversationId = "c-cobot-1"
    static let botId = "cobot"
    static let messageId = "a-working"
    static var prompt: String { String(localized: "#gog plan my week: appointments, travel and emails to handle") }

    static var enabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-demo") && arguments.contains("-demoTurnWorking")
    }

    /// Fixed at launch so the elapsed time keeps counting from the same start.
    static let startedAt = Date().addingTimeInterval(-(3 * 60 + 12))

    static var userMessage: Message {
        Message(id: "u-working", conversationId: conversationId, role: .user, text: prompt, createdAt: startedAt.addingTimeInterval(-1))
    }

    static var working: TurnSnapshot {
        TurnSnapshot(
            conversationId: conversationId, botId: botId, messageId: messageId, startedAt: startedAt, phase: .working,
            currentTool: "gog gmail search \"is:unread newer_than:3d\"",
            text: String(localized: "Your week has **9 appointments**, 3 of them outside Paris. Now I'm going through the emails waiting for a reply."),
            thoughts: String(localized: "List the events, estimate the travel time between each place, then sort the unread emails by urgency."),
            steps: [
                ToolStep(toolCallId: "w1", title: "gog calendar events --from monday --to sunday", kind: "execute", status: .completed, durationMs: 4_200),
                ToolStep(toolCallId: "w2", title: String(localized: "gog maps directions --mode transit (3 routes)"), kind: "execute", status: .completed, durationMs: 38_000),
                ToolStep(toolCallId: "w3", title: "gog gmail search \"is:unread newer_than:3d\"", kind: "execute", status: .running),
            ])
    }

    static var activeTurn: ActiveTurn {
        let turn = working
        return ActiveTurn(
            messageId: turn.messageId, startedAt: turn.startedAt, phase: turn.phase, currentTool: turn.currentTool,
            steps: turn.steps.count, partialText: turn.text)
    }
}
