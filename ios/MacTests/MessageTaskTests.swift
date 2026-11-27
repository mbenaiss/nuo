import Foundation
import Testing

struct MessageTaskTests {
    private func decode(_ json: String) throws -> [Message] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = ISO8601Wire.parse(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: text)
            }
            return date
        }
        return try decoder.decode([Message].self, from: Data(json.utf8))
    }

    @Test func aScheduledRunPromptIsMarkedAndItsAnswerIsNot() throws {
        let messages = try decode("""
        [
          {"id": "msg-prompt", "conversationId": "conv-homelab", "role": "user",
           "text": "Relevé quotidien des températures de nuit. Lance `python3 -I ~/homelab/temperatures_nuits.py --report`.",
           "task": {"id": "task-temperatures", "title": "Températures de nuit"},
           "createdAt": "2026-10-28T06:30:00.000Z"},
          {"id": "msg-answer", "conversationId": "conv-homelab", "role": "assistant",
           "text": "Nuit du 27 au 28 : salon 19,4 °C, chambre d'Inès 18,1 °C.", "createdAt": "2026-10-28T06:30:42.000Z"}
        ]
        """)
        #expect(messages[0].isTaskPrompt)
        #expect(messages[0].task == MessageTask(id: "task-temperatures", title: "Températures de nuit"))
        #expect(!messages[1].isTaskPrompt)
    }

    @Test func aTypedMessageFromAnOlderGatewayIsNotATaskPrompt() throws {
        let messages = try decode("""
        [{"id": "msg-typed", "conversationId": "conv-homelab", "role": "user",
          "text": "Et la chambre d'Inès cette nuit ?", "createdAt": "2026-10-28T07:02:00.000Z"}]
        """)
        #expect(messages[0].task == nil)
        #expect(!messages[0].isTaskPrompt)
    }

    @Test func chatsShowOnlyWhatAScheduledRunAnswered() throws {
        let messages = try decode("""
        [
          {"id": "msg-prompt", "conversationId": "conv-homelab", "role": "user",
           "text": "Relevé quotidien des températures de nuit (chauffage collectif Gecina).",
           "task": {"id": "task-temperatures", "title": "Températures de nuit"},
           "createdAt": "2026-10-31T06:30:00.000Z"},
          {"id": "msg-answer", "conversationId": "conv-homelab", "role": "assistant",
           "text": "Nuit du 30 au 31 : moyenne 19,2 °C, chambre d'Inès la plus froide à 18,3 °C.", "createdAt": "2026-10-31T06:30:40.000Z"},
          {"id": "msg-typed", "conversationId": "conv-homelab", "role": "user",
           "text": "Et l'an dernier à la même date ?", "createdAt": "2026-10-31T08:10:00.000Z"}
        ]
        """)
        #expect(messages.withoutTaskPrompts.map(\.id) == ["msg-answer", "msg-typed"])
    }
}
