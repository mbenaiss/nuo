import Foundation
import Testing

struct RelayOfferTests {
    private let device = "4f1c2e1a-0b7d-4c55-9a3e-2d8f6b1c7e90"
    private let registered = RelayPlan.Server(registered: true, thumbprint: "kq3Z0bO1sFjXo2c6vH9m4yQe5tW8rL7uN1aD3gP6iC0")

    @Test func aWorkingKeyIsLeftAlone() {
        let local = RelayPlan.LocalKey.key(deviceId: device, thumbprint: "kq3Z0bO1sFjXo2c6vH9m4yQe5tW8rL7uN1aD3gP6iC0")
        #expect(!RelayPlan.shouldOffer(local: local, server: registered, deviceId: device, isOwner: true, atHome: true, declined: false))
    }

    @Test func aKeychainThatCannotBeReadNowDecidesNothing() {
        #expect(!RelayPlan.shouldOffer(local: .unreadable, server: registered, deviceId: device, isOwner: true, atHome: true, declined: false))
        let none = RelayPlan.Server(registered: false, thumbprint: nil)
        #expect(!RelayPlan.shouldOffer(local: .unreadable, server: none, deviceId: device, isOwner: true, atHome: true, declined: false))
    }

    @Test func aGatewayThatCannotBeAskedDecidesNothing() {
        #expect(!RelayPlan.shouldOffer(local: .absent, server: nil, deviceId: device, isOwner: true, atHome: true, declined: false))
    }

    @Test func aKeyTheGatewayDoesNotKnowIsOfferedAgain() {
        let other = RelayPlan.LocalKey.key(deviceId: device, thumbprint: "Zx9yW8vU7tS6rQ5pO4nM3lK2jI1hG0fE9dC8bA7z6Y5")
        #expect(RelayPlan.shouldOffer(local: other, server: registered, deviceId: device, isOwner: true, atHome: true, declined: false))
        #expect(RelayPlan.shouldOffer(local: .absent, server: registered, deviceId: device, isOwner: true, atHome: true, declined: false))
        // A key left from an earlier pairing of this iPhone.
        let stale = RelayPlan.LocalKey.key(deviceId: "9b2d7e4c-1a3f-4e6b-8c5d-0f7a2b9e3d61", thumbprint: "kq3Z0bO1sFjXo2c6vH9m4yQe5tW8rL7uN1aD3gP6iC0")
        #expect(RelayPlan.shouldOffer(local: stale, server: registered, deviceId: device, isOwner: true, atHome: true, declined: false))
    }

    @Test func offeredOnlyToTheOwnerAtHomeWhoNeverSaidLater() {
        let none = RelayPlan.Server(registered: false, thumbprint: nil)
        #expect(RelayPlan.shouldOffer(local: .absent, server: none, deviceId: device, isOwner: true, atHome: true, declined: false))
        #expect(!RelayPlan.shouldOffer(local: .absent, server: none, deviceId: device, isOwner: false, atHome: true, declined: false))
        #expect(!RelayPlan.shouldOffer(local: .absent, server: none, deviceId: device, isOwner: true, atHome: false, declined: false))
        #expect(!RelayPlan.shouldOffer(local: .absent, server: none, deviceId: device, isOwner: true, atHome: true, declined: true))
    }
}

struct RelayScopeTests {
    @Test func commandsAndLongRequestsWaitForTheUnlock() {
        #expect(!RelayScope.waitsForUnlock("Ajoute acheter du pain à ma liste de courses"))
        for command in ["/purge prod", "  /purge prod", "\u{FEFF}/purge prod", "\u{200B}/purge prod", "\n/purge prod", "\u{2060}\u{00A0}/purge prod"] {
            #expect(RelayScope.waitsForUnlock(command))
        }
        #expect(!RelayScope.waitsForUnlock(String(repeating: "a", count: RelayScope.maxText)))
        #expect(RelayScope.waitsForUnlock(String(repeating: "a", count: RelayScope.maxText + 1)))
        // A slash further in is just text.
        #expect(!RelayScope.waitsForUnlock("Rappelle-moi le devis 12/11 de Julie Martin"))
    }

    private func message(_ id: String, _ role: Message.Role, _ text: String, done: Bool = true, at seconds: TimeInterval) -> Message {
        Message(id: id, conversationId: "c-relay-1", role: role, text: text, durationMs: role == .assistant ? 2100 : nil,
                stopReason: role == .assistant && done ? .endTurn : nil, createdAt: Date(timeIntervalSince1970: 1_794_000_000 + seconds))
    }

    @Test func theAnswerIsTheOneAfterItsOwnPrompt() {
        let messages = [
            message("u-1", .user, "Ajoute acheter du pain", at: 0),
            message("a-1", .assistant, "Rappel ajouté : « Acheter du pain ».", at: 4),
            message("u-2", .user, "Et appeler Julie Martin demain à 9 h", at: 30),
        ]
        // The second request's answer is not stored yet: the first one's is not taken for it.
        #expect(RelayScope.answer(to: "u-2", in: messages) == nil)
        #expect(RelayScope.answer(to: "u-1", in: messages)?.id == "a-1")
        let answered = messages + [message("a-2", .assistant, "Rappel ajouté : « Appeler Julie Martin ».", at: 34)]
        #expect(RelayScope.answer(to: "u-2", in: answered)?.id == "a-2")
        #expect(RelayScope.answer(to: "u-9", in: answered) == nil)
    }
}
