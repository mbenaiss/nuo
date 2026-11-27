import Foundation
import Testing

struct GoalPromptTests {
    private func wire(_ event: ClientEvent) throws -> [String: Any] {
        let data = try JSONEncoder().encode(event)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func aGoalPromptTellsTheGateway() throws {
        let sent = try wire(.prompt(conversationId: "c-maison", text: "Trouve un plombier dispo samedi et prépare le message", goal: true))
        #expect(sent["type"] as? String == "prompt")
        #expect(sent["goal"] as? Bool == true)
    }

    @Test func anOrdinaryPromptSendsNoGoalField() throws {
        let sent = try wire(.prompt(conversationId: "c-maison", text: "Quand passe le plombier ?"))
        #expect(sent["goal"] == nil)
    }

    @Test func aQueuedMessageKeepsItsGoal() {
        let queued = QueuedPrompt(text: "Range les factures EDF 2026 dans Documents", attachments: [], goal: true)
        #expect(queued.goal)
        #expect(!QueuedPrompt(text: "Merci", attachments: []).goal)
    }
}
