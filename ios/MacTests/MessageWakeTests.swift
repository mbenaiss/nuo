import Foundation
import Testing

struct MessageWakeTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try NuoJSON.decoder().decode(type, from: Data(json.utf8))
    }

    @Test func historyCarriesAStrangersMailAndAWebhookCall() throws {
        let messages = try decode([Message].self, """
        [
          {"id": "msg-julie", "conversationId": "conv-unverified", "role": "user",
           "text": "[Nuo] E-mail reçu sur cobot@bots.example.com. L'expéditeur n'est pas l'utilisateur…",
           "wake": {"kind": "mail", "from": "julie.martin@lumen.example", "fromName": "Julie Martin",
                    "to": "cobot@bots.example.com", "subject": "Devis cuisine, version 2",
                    "text": "Bonjour, voici la version 2 du devis pour la cuisine.", "verified": false,
                    "attachments": ["devis-cuisine-v2.pdf"]},
           "createdAt": "2026-11-26T09:14:00.000Z"},
          {"id": "msg-linear", "conversationId": "conv-linear", "role": "user",
           "text": "[Nuo] Réveil par le webhook « Linear ». Ce qui suit vient d'un service extérieur…",
           "wake": {"kind": "hook", "name": "Linear", "event": "Issue", "contentType": "application/json",
                    "body": "{\\n  \\"title\\": \\"Bug checkout iOS\\"\\n}"},
           "createdAt": "2026-11-26T10:02:00.000Z"}
        ]
        """)
        guard case let .mail(mail) = messages[0].wake else { Issue.record("expected a mail"); return }
        #expect(mail == MessageWake.Mail(
            from: "julie.martin@lumen.example", fromName: "Julie Martin", to: "cobot@bots.example.com",
            subject: "Devis cuisine, version 2", text: "Bonjour, voici la version 2 du devis pour la cuisine.", verified: false,
            attachments: ["devis-cuisine-v2.pdf"]))
        #expect(messages[0].wake?.title == "Email from Julie Martin")
        #expect(messages[0].wake?.summary == "Email from Julie Martin · Devis cuisine, version 2")
        #expect(messages[0].wake?.copyText == "Devis cuisine, version 2\n\nBonjour, voici la version 2 du devis pour la cuisine.")

        guard case let .hook(hook) = messages[1].wake else { Issue.record("expected a webhook"); return }
        #expect(hook.name == "Linear")
        #expect(hook.event == "Issue")
        #expect(hook.body.contains("Bug checkout iOS"))
        #expect(messages[1].wake?.title == "Linear webhook")
        #expect(messages[1].wake?.summary == "Linear webhook · Issue")
        #expect(messages[1].wake?.copyText == hook.body)
    }

    @Test func theOwnersVerifiedMailReadsAsHisOwn() throws {
        let message = try decode(Message.self, """
        {"id": "msg-own", "conversationId": "conv-mine", "role": "user",
         "text": "[Nuo] E-mail de l'utilisateur lui-même (alex@example.com, expéditeur vérifié)…",
         "wake": {"kind": "mail", "from": "alex@example.com", "fromName": "Alex Morgan",
                  "to": "cobot@bots.example.com", "subject": "Relance Julie pour le devis",
                  "text": "Relance Julie Martin avant vendredi.", "verified": true},
         "createdAt": "2026-11-26T08:00:00.000Z"}
        """)
        #expect(message.wake?.title == "Email from you")
        #expect(message.wake?.isShown == true)
    }

    @Test func aSenderWithoutANameIsShownByAddress() throws {
        let wake = try decode(MessageWake.self, """
        {"kind": "mail", "from": "julie.martin@lumen.example", "to": "cobot@bots.example.com",
         "subject": "", "text": "Le devis est en pièce jointe.", "verified": false}
        """)
        #expect(wake.title == "Email from julie.martin@lumen.example")
        #expect(wake.summary == "Email from julie.martin@lumen.example")
        #expect(wake.copyText == "Le devis est en pièce jointe.")
    }

    @Test func theLiveEventBringsTheWokenMessage() throws {
        let event = try decode(ServerEvent.self, """
        {"type": "message.user", "conversationId": "conv-linear", "botId": "cobot",
         "message": {"id": "msg-linear", "conversationId": "conv-linear", "role": "user",
                     "text": "[Nuo] Réveil par le webhook « Linear »…",
                     "wake": {"kind": "hook", "name": "Linear", "body": "title: Bug checkout iOS"},
                     "createdAt": "2026-11-26T10:02:00.000Z"}}
        """)
        guard case let .messageUser(conversationId, message) = event else { Issue.record("expected message.user"); return }
        #expect(conversationId == "conv-linear")
        #expect(event.conversationId == "conv-linear")
        #expect(message.wake == .hook(MessageWake.Hook(name: "Linear", body: "title: Bug checkout iOS")))
        #expect(message.wake?.summary == "Linear webhook")
    }

    @Test func aMessageWithoutWakeStillDecodes() throws {
        let message = try decode(Message.self, """
        {"id": "msg-typed", "conversationId": "conv-mine", "role": "user",
         "text": "Où en est le devis de Julie Martin ?", "createdAt": "2026-11-26T11:30:00.000Z"}
        """)
        #expect(message.wake == nil)
        #expect(message.text == "Où en est le devis de Julie Martin ?")
    }

    @Test func aKindFromANewerGatewayFallsBackToTheText() throws {
        let messages = try decode([Message].self, """
        [{"id": "msg-sms", "conversationId": "conv-sms", "role": "user", "text": "SMS de Julie Martin : rappelle-moi.",
          "wake": {"kind": "sms", "from": "+33 6 12 34 56 78"}, "createdAt": "2026-11-26T12:00:00.000Z"},
         {"id": "msg-broken", "conversationId": "conv-sms", "role": "user", "text": "Devis cuisine",
          "wake": {"kind": "mail", "from": "julie.martin@lumen.example"}, "createdAt": "2026-11-26T12:01:00.000Z"}]
        """)
        #expect(messages.map(\.wake) == [.unknown, .unknown])
        #expect(messages.allSatisfy { $0.wake?.isShown == false })
    }

    @Test func aWokenMessageRoundTrips() throws {
        let wake = MessageWake.mail(.init(
            from: "julie.martin@lumen.example", fromName: "Julie Martin", to: "cobot@bots.example.com",
            subject: "Devis cuisine, version 2", text: "Bonjour, voici la version 2.", verified: false))
        let data = try NuoJSON.encoder().encode(wake)
        #expect(try NuoJSON.decoder().decode(MessageWake.self, from: data) == wake)
    }
}
