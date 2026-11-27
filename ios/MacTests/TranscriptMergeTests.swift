import Foundation
import Testing

struct TranscriptMergeTests {
    private let startedAt = Date(timeIntervalSince1970: 1_793_610_000)

    private func message(_ id: String, _ role: Message.Role, _ text: String, stopReason: StopReason? = nil) -> Message {
        Message(id: id, conversationId: "conv-cuisine", role: role, text: text, stopReason: stopReason, createdAt: startedAt)
    }

    private func turn(_ messageId: String, text: String) -> TurnSnapshot {
        TurnSnapshot(conversationId: "conv-cuisine", botId: "bot-cuisine", messageId: messageId, startedAt: startedAt,
                     phase: .answering, text: text, steps: [])
    }

    /// Address of the text's UTF-8 buffer: the same address means the same storage, not just equal text.
    private func buffer(_ text: String) -> UInt? {
        text.utf8.withContiguousStorageIfAvailable { $0.baseAddress.map { UInt(bitPattern: $0) } } ?? nil
    }

    private func copied(_ text: String) -> String { String(decoding: Array(text.utf8), as: UTF8.self) }

    // MARK: - Ended turns

    @Test func anAnswerRequestedBeforeTheTurnEndedIsStale() {
        var ended = EndedTurns()
        let mark = ended.count
        #expect(!ended.endedSince(mark))
        ended.record("msg-risotto-answer")
        #expect(ended.endedSince(mark))
        #expect(!ended.endedSince(ended.count))
    }

    @Test func aTurnSeenEndingIsNotBroughtBackAsRunning() {
        var ended = EndedTurns()
        ended.record("msg-risotto-answer")
        #expect(ended.isOver(turn("msg-risotto-answer", text: "Pour quatre personnes, compte 320 g de riz carnaroli")))
        #expect(!ended.isOver(turn("msg-dessert-answer", text: "Une tarte fine aux pommes")))
    }

    @Test func aSendCancelledBeforeItsTurnStartedStillMakesPendingAnswersStale() {
        var ended = EndedTurns()
        let mark = ended.count
        ended.record(nil)
        #expect(ended.endedSince(mark))
        #expect(!ended.isOver(turn("msg-risotto-answer", text: "")))
    }

    @Test func onlyTheLatestEndedTurnsAreRemembered() {
        var ended = EndedTurns()
        for index in 1...20 { ended.record("msg-answer-\(index)") }
        #expect(ended.count == 20)
        #expect(!ended.isOver(turn("msg-answer-1", text: "")))
        #expect(ended.isOver(turn("msg-answer-20", text: "")))
    }

    // MARK: - Reused messages

    @Test func anUnchangedReloadKeepsTheShownMessagesAndTheirTextBuffers() {
        let answer = "Pour un risotto aux cèpes pour quatre : 320 g de carnaroli, 1,2 l de bouillon chaud, 40 g de parmesan."
        let shown = [
            message("msg-question", .user, "Une recette de risotto aux cèpes pour ce soir ?"),
            message("msg-answer", .assistant, answer, stopReason: .endTurn),
        ]
        let fetched = [
            message("msg-question", .user, copied("Une recette de risotto aux cèpes pour ce soir ?")),
            message("msg-answer", .assistant, copied(answer), stopReason: .endTurn),
        ]
        #expect(buffer(fetched[1].text) != buffer(shown[1].text))

        let merged = TranscriptMerge.reusing(shown, in: fetched)
        #expect(merged == shown)
        #expect(buffer(merged[1].text) == buffer(shown[1].text))
    }

    @Test func aChangedMessageTakesTheFetchedValue() {
        let shown = [message("msg-answer", .assistant, "Pour un risotto aux cèpes pour quatre : 320 g de carnaroli")]
        let full = message("msg-answer", .assistant, "Pour un risotto aux cèpes pour quatre : 320 g de carnaroli, 1,2 l de bouillon.", stopReason: .endTurn)
        let merged = TranscriptMerge.reusing(shown, in: [full])
        #expect(merged == [full])
    }

    @Test func theFetchedOrderAndNewMessagesWin() {
        let question = message("msg-question", .user, "Et un dessert de saison ?")
        let shown = [message("local-7F3A", .user, "Et un dessert de saison ?")]
        let answer = message("msg-dessert", .assistant, "Une tarte fine aux pommes et au miel de châtaignier.", stopReason: .endTurn)
        #expect(TranscriptMerge.reusing(shown, in: [question, answer]) == [question, answer])
        #expect(TranscriptMerge.reusing([], in: [question]) == [question])
    }

    // MARK: - Prompt given back

    @Test func aPromptComesBackIntoAnEmptyComposer() {
        #expect(TranscriptMerge.draft(returning: "Liste de courses pour le risotto", before: "") == "Liste de courses pour le risotto")
        #expect(TranscriptMerge.draft(returning: "Liste de courses pour le risotto", before: "  \n") == "Liste de courses pour le risotto")
    }

    @Test func aPromptComesBackAboveWhatWasTypedSince() {
        let draft = TranscriptMerge.draft(returning: "Liste de courses pour le risotto", before: "Et pour six personnes ?")
        #expect(draft == "Liste de courses pour le risotto\nEt pour six personnes ?")
    }

    @Test func anAttachmentOnlyPromptLeavesTheDraftAlone() {
        #expect(TranscriptMerge.draft(returning: "", before: "Que penses-tu de ce plat ?") == "Que penses-tu de ce plat ?")
    }
}
