import Foundation
import Testing

@MainActor
struct AskReplyTests {
    /// WatchConnectivity answers on a queue of its own while the ask screen waits on the main actor: the watch app
    /// stopped there with EXC_BREAKPOINT right after a request reached the iPhone.
    @Test func theIPhonesAnswerOnAnotherQueueReachesTheWaitingRequest() async {
        let answer: [String: Any] = [
            RecordingLink.ok: true,
            RecordingLink.conversationId: "c-general-2026-11-16",
            RecordingLink.botId: "general",
            RecordingLink.text: "Rappelle-moi d'appeler Julie Martin demain à 9 h",
        ]
        nonisolated(unsafe) let sent = answer
        let reply = await withCheckedContinuation { continuation in
            let handler = AskReply.resuming(continuation)
            DispatchQueue.global(qos: .utility).async { handler(sent) }
        }
        #expect(reply == AskReply(ok: true, queued: false, conversationId: "c-general-2026-11-16", botId: "general",
                                  text: "Rappelle-moi d'appeler Julie Martin demain à 9 h"))
    }

    @Test func aLockedIPhoneKeepsTheRequestAndSaysWhy() {
        let reply = AskReply([RecordingLink.ok: false, RecordingLink.queued: true, RecordingLink.locked: true])
        #expect(reply == AskReply(ok: false, queued: true, locked: true))
        #expect(AskReply([RecordingLink.error: "Bot introuvable"]).error == "Bot introuvable")
    }
}

struct AskFollowTests {
    @Test func aRequestKeptUntilTheUnlockOpensItsAnswerWhileTheUserStillWaits() {
        let asked = Date(timeIntervalSince1970: 1_794_826_404)
        #expect(AskFollow.opensAnswer(askedAt: asked, now: asked.addingTimeInterval(9)))
        #expect(AskFollow.opensAnswer(askedAt: asked, now: asked.addingTimeInterval(14 * 60)))
    }

    @Test func anAcknowledgementOvertakingTheLiveReplyIsLeftToTheReply() {
        #expect(!AskFollow.handlesAck(liveReplyPending: true))
        #expect(AskFollow.handlesAck(liveReplyPending: false))
    }

    @Test func anAnswerHoursLaterIsLeftToTheNotification() {
        let asked = Date(timeIntervalSince1970: 1_794_826_404)
        #expect(!AskFollow.opensAnswer(askedAt: asked, now: asked.addingTimeInterval(16 * 60)))
        #expect(!AskFollow.opensAnswer(askedAt: asked, now: asked.addingTimeInterval(3 * 3600)))
    }
}
