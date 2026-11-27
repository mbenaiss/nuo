import Foundation
import Testing

struct LongRecordingTests {
    private let id = "3f6c2a1e-8d4b-4f0a-9c1e-5a7b2d9e4c10"

    @Test func upToTwoHoursFiftyTheAudioGoesAsItIs() {
        let plan = RecordingParts.plan(duration: 2 * 3600 + 45 * 60)
        #expect(plan.bitRate == 48_000)
        #expect(plan.parts == [.init(index: 0, start: 0, duration: 2 * 3600 + 45 * 60)])
    }

    @Test func upToFiveHoursFortyItGoesInOneJobAtALowerRate() {
        let plan = RecordingParts.plan(duration: 5 * 3600)
        #expect(plan.bitRate == 24_000)
        #expect(plan.parts.count == 1)
        // 24 kbit/s for the longest single job stays under the gateway's 64 MB.
        #expect(Double(plan.bitRate) / 8 * RecordingParts.singleJobSeconds < 64 * 1024 * 1024 * 0.97)
    }

    @Test func longerRecordingsOverlapByTwoMinutes() {
        let plan = RecordingParts.plan(duration: 8 * 3600)
        #expect(plan.parts.count == 2)
        #expect(plan.parts[1].start == plan.parts[0].start + plan.parts[0].duration - RecordingParts.overlap)
        #expect(abs((plan.parts.last.map { $0.start + $0.duration } ?? 0) - 8 * 3600) < 0.001)
        #expect(plan.parts.allSatisfy { $0.duration <= RecordingParts.singleJobSeconds })
    }

    private func line(_ start: TimeInterval, _ end: TimeInterval, _ speaker: String, _ text: String) -> RecordingLine {
        RecordingLine(start: start, end: end, text: text, speaker: speaker)
    }

    /// The window 20000–20120 heard twice: Alex is « 1 » before and « 2 » after, Julie Martin the other way round.
    private var before: [RecordingLine] {
        [line(19900, 19990, "1", "On reprend le planning du salon de Lyon."),
         line(20005, 20030, "1", "Le montage commence le mercredi 3 décembre."),
         line(20040, 20070, "2", "Très bien, on valide 12 000 € avant vendredi."),
         line(20085, 20115, "1", "Je vous envoie le bon de commande ce soir.")]
    }

    private var after: [RecordingLine] {
        [line(20005.4, 20030.2, "2", "Le montage commence le mercredi 3 décembre."),
         line(20040.1, 20070.3, "1", "Très bien, on valide 12 000 € avant vendredi."),
         line(20085.2, 20115.1, "2", "Je vous envoie le bon de commande ce soir."),
         line(20200, 20230, "3", "Bonjour, je suis Hugo Bernard, le monteur.")]
    }

    @Test func voicesHeardInBothPartsKeepTheirNumbers() {
        let names = RecordingParts.matchVoices(before: before, after: after, window: 20000...20120, existing: ["1", "2"])
        #expect(names["2"] == "1")
        #expect(names["1"] == "2")
    }

    @Test func aVoiceOnlyInTheNewPartGetsANewNumber() {
        let names = RecordingParts.matchVoices(before: before, after: after, window: 20000...20120, existing: ["1", "2", "3"])
        #expect(names["3"] == "4")
    }

    @Test func thePartsAreJoinedInASilenceWithoutRepeatingOrCuttingASentence() {
        let joined = RecordingParts.join(before: before, after: after, window: 20000...20120, existing: ["1", "2"])
        #expect(joined.filter { $0.text.hasPrefix("Très bien") }.count == 1)
        #expect(joined.filter { $0.text.hasPrefix("Le montage") }.count == 1)
        #expect(joined.last?.text == "Bonjour, je suis Hugo Bernard, le monteur.")
        #expect(joined.last?.speaker == "3")
        #expect(joined.map(\.start) == joined.map(\.start).sorted())
        // A marker at the join still quotes the sentence said then.
        let quote = MarkerQuote.align([RecordingMarker(id: "m", offset: 20052)], to: joined).first
        #expect(quote?.line?.text == "Très bien, on valide 12 000 € avant vendredi.")
        #expect(quote?.line?.speaker == "2")
    }
}

struct WatchQueueReviewThreeTests {
    private let now = Date(timeIntervalSince1970: 1_794_650_400)

    @Test func resendsWaitLongerEachTimeUpToACeiling() {
        #expect(AskQueue.resendDelay(attempts: 1) == 10 * 60)
        #expect(AskQueue.resendDelay(attempts: 2) == 20 * 60)
        #expect(AskQueue.resendDelay(attempts: 3) == 40 * 60)
        #expect(AskQueue.resendDelay(attempts: 12) == AskQueue.maxResendDelay)
        var queue = AskQueue()
        queue.enqueue(WatchAsk(id: "lyon", createdAt: now, botId: nil, audioFile: "lyon.m4a", seconds: 5))
        queue.markSending("lyon")
        queue.markSending("lyon")
        queue.markTransferred("lyon", at: now)
        #expect(queue.due(now: now.addingTimeInterval(15 * 60)).isEmpty)
        #expect(queue.due(now: now.addingTimeInterval(21 * 60)).map(\.id) == ["lyon"])
    }

    @Test func onlyARequestOnItsWayGoesBackToWaiting() {
        var queue = AskQueue()
        queue.enqueue(WatchAsk(id: "pain", createdAt: now, botId: nil, audioFile: "pain.m4a", seconds: 3))
        queue.markDelivered("pain", conversationId: "c-general-7", botId: "general", transcript: "Ajoute acheter du pain")
        queue.markWaiting("pain")
        #expect(queue.ask(id: "pain")?.state == .delivered)
    }

    @Test func requestsDroppedFromTheListGiveBackTheirAudio() {
        var queue = AskQueue()
        var dropped: [String] = []
        for index in 0..<7 {
            queue.enqueue(WatchAsk(id: "demande-\(index)", createdAt: now, botId: nil, audioFile: "demande-\(index).m4a", seconds: 3))
            dropped += queue.markFailed("demande-\(index)", message: "La passerelle a refusé la demande.").droppedAudio
        }
        #expect(dropped == ["demande-0.m4a", "demande-1.m4a"])
        #expect(queue.remove("demande-6")?.audioFile == "demande-6.m4a")
    }
}

struct SegmentClockTests {
    @Test func theManifestCarriesEachPiecesLength() {
        var journal = RecordingJournal(startedAt: Date(timeIntervalSince1970: 1_794_650_400))
        journal.openNextSegment()
        journal.closeSegment(duration: 30)
        journal.openNextSegment()
        journal.closeSegment(duration: 12.4)
        journal.openNextSegment()
        journal.finish(openDuration: 30)
        #expect(journal.manifest.segmentDurations == [30, 12.4, 30])
    }

    @Test func aPieceTheWatchLostCountsAsArrivedAndBecomesSilence() {
        var arrival = RecordingArrival()
        arrival.manifest = RecordingManifest(id: "4b0f2c1e-6d8a-4c55-9a43-0d3f6f1e2a10", startedAt: Date(), duration: 72, markers: [],
                                             segmentCount: 3, isFinished: true)
        arrival.receive(index: 0)
        arrival.receive(index: 2)
        #expect(!arrival.isComplete)
        arrival.markLost(index: 1)
        #expect(arrival.isComplete)
        #expect(arrival.lost == [1])
    }

    @Test func linesHeardInASilenceWeAddedAreDropped() {
        let lines = [
            RecordingLine(start: 10, end: 14, text: "On valide 12 000 € avant vendredi.", speaker: "1"),
            RecordingLine(start: 31, end: 33, text: "Merci.", speaker: "2"),
            RecordingLine(start: 61, end: 64, text: "Je vous envoie le bon de commande.", speaker: "1"),
        ]
        let kept = SilenceGaps.drop(lines, in: [30...60])
        #expect(kept.map(\.start) == [10, 61])
    }
}
