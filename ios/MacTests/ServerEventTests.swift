import Foundation
import Testing

struct ServerEventTests {
    private func decode(_ json: String) throws -> ServerEvent {
        try JSONDecoder().decode(ServerEvent.self, from: Data(json.utf8))
    }

    @Test func aScheduledRunEndIsMarkedSoTheAppDoesNotAnnounceItAgain() throws {
        let event = try decode("""
        {"type": "message.end", "conversationId": "conv-propositions", "messageId": "msg-rien",
         "durationMs": 9968, "steps": 2, "stopReason": "end_turn", "scheduled": true}
        """)
        guard case let .messageEnd(conversationId, messageId, _, _, stopReason, _, _, scheduled) = event else {
            Issue.record("expected message.end, got \(event)")
            return
        }
        #expect(conversationId == "conv-propositions")
        #expect(messageId == "msg-rien")
        #expect(stopReason == .endTurn)
        #expect(scheduled)
    }

    @Test func anAnswerToTheUserIsNotScheduled() throws {
        let event = try decode("""
        {"type": "message.end", "conversationId": "conv-lisbonne", "messageId": "msg-vol-af1234",
         "durationMs": 4700, "steps": 1, "stopReason": "end_turn", "agent": "claude", "model": "claude-sonnet-4-5"}
        """)
        guard case let .messageEnd(_, _, _, _, _, _, _, scheduled) = event else {
            Issue.record("expected message.end, got \(event)")
            return
        }
        #expect(!scheduled)
    }

    @Test func aBotAlertPointsAtTheConversationThatHoldsIt() throws {
        let event = try decode("""
        {"type": "notification", "title": "🎪 Illusions Tour", "body": "Séance du 9 novembre à 17h disponible.",
         "botId": "bot-sorties", "conversationId": "conv-illusions-tour"}
        """)
        guard case let .notification(title, body, botId, conversationId) = event else {
            Issue.record("expected notification, got \(event)")
            return
        }
        #expect(title == "🎪 Illusions Tour")
        #expect(body == "Séance du 9 novembre à 17h disponible.")
        #expect(botId == "bot-sorties")
        #expect(conversationId == "conv-illusions-tour")
        #expect(event.conversationId == "conv-illusions-tour")
    }

    @Test func anAlertFromAScriptHasNoConversation() throws {
        let event = try decode("""
        {"type": "notification", "title": "Colis", "body": "Ton colis Vinted est arrivé au relais Pickup."}
        """)
        #expect(event.conversationId == nil)
    }
}
