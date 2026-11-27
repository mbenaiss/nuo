import Foundation
import Testing

@MainActor
struct PhoneTurnFeedTests {
    private func relay(_ event: String, _ text: String = "", conversationId: String) -> [String: Any] {
        [RecordingLink.conversationId: conversationId, RecordingLink.event: event, RecordingLink.text: text]
    }

    private func collect(_ stream: AsyncStream<TurnUpdate>) async -> [String] {
        var seen: [String] = []
        for await update in stream {
            switch update {
            case let .delta(text): seen.append("delta:\(text)")
            case .finished: seen.append("end")
            default: seen.append("other")
            }
            if update.endsTurn { break }
        }
        return seen
    }

    /// The iPhone relays a whole agenda answer before the watch opens a screen, and the same answer can open twice:
    /// the screen on top waited forever for an end the first one had taken.
    @Test func everyScreenOpenedAfterTheTurnGetsTheWholeAnswer() async {
        let feed = PhoneTurnFeed.shared
        let conversation = "c-agenda-2026-11-16-1213"
        feed.receive(relay("delta", "Voici ton agenda d'aujourd'hui, lundi 16 novembre :", conversationId: conversation))
        feed.receive(relay("end", conversationId: conversation))

        let first = await collect(feed.updates(conversationId: conversation))
        let second = await collect(feed.updates(conversationId: conversation))
        #expect(first == ["delta:Voici ton agenda d'aujourd'hui, lundi 16 novembre :", "end"])
        #expect(second == first)
    }

    @Test func aNewRequestInTheConversationDoesNotReplayTheLastAnswer() async {
        let feed = PhoneTurnFeed.shared
        let conversation = "c-courses-2026-11-16"
        feed.receive(relay("delta", "C'est noté : acheter du pain.", conversationId: conversation))
        feed.receive(relay("end", conversationId: conversation))
        feed.reset(conversationId: conversation)
        feed.receive(relay("delta", "Rappel ajouté : appeler Julie Martin demain à 9 h.", conversationId: conversation))
        feed.receive(relay("end", conversationId: conversation))

        let seen = await collect(feed.updates(conversationId: conversation))
        #expect(seen == ["delta:Rappel ajouté : appeler Julie Martin demain à 9 h.", "end"])
    }
}
