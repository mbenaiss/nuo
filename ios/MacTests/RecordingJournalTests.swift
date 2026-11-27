import Foundation
import Testing

struct RecordingJournalTests {
    private let start = Date(timeIntervalSince1970: 1_794_650_400)

    @Test func segmentsAddUpToTheRecordingAndLeaveWhenClosed() {
        var journal = RecordingJournal(id: "4b0f2c1e-6d8a-4c55-9a43-0d3f6f1e2a10", startedAt: start)
        journal.openNextSegment()
        journal.updateOpenSegment(duration: 12)
        #expect(journal.closedSegments.isEmpty)
        #expect(journal.duration == 12)
        journal.openNextSegment()
        #expect(journal.closedSegments.map(\.file) == ["segment-0000.m4a"])
        journal.finish(openDuration: 30)
        #expect(journal.status == .finished)
        #expect(journal.duration == 42)
        #expect(journal.manifest.segmentCount == 2)
        #expect(journal.manifest.isFinished)
    }

    @Test func anEmptyLastSegmentIsDropped() {
        var journal = RecordingJournal(startedAt: start)
        journal.openNextSegment()
        journal.closeSegment(duration: 30)
        journal.openNextSegment()
        journal.finish(openDuration: 0)
        #expect(journal.closedSegments.count == 1)
    }

    @Test func aDoubleTapFeltTwiceIsOneMarker() throws {
        var journal = RecordingJournal(startedAt: start)
        let marked = journal.mark(at: 754)
        let first = try #require(marked)
        #expect(journal.mark(at: 754.8) == nil)
        #expect(journal.mark(at: 790) != nil)
        #expect(journal.markers.map(\.offset) == [754, 790])
        #expect(first.offset == 754)
    }

    @Test func aCrashKeepsTheReadablePartOfTheOpenSegment() {
        var journal = RecordingJournal(startedAt: start)
        journal.openNextSegment()
        journal.closeSegment(duration: 30)
        journal.openNextSegment()
        journal.updateOpenSegment(duration: 20)
        _ = journal.mark(at: 49)
        let recovered = journal.recovered { _ in 18 }
        #expect(recovered.status == .finished)
        #expect(recovered.manifest.interrupted)
        #expect(recovered.duration == 48)
        #expect(recovered.markers.map(\.offset) == [48])
        #expect(recovered.manifest.segmentCount == 2)
    }

    @Test func aCrashDropsAnUnreadableOpenSegment() {
        var journal = RecordingJournal(startedAt: start)
        journal.openNextSegment()
        journal.closeSegment(duration: 30)
        journal.openNextSegment()
        journal.updateOpenSegment(duration: 9)
        let recovered = journal.recovered { _ in nil }
        #expect(recovered.closedSegments.map(\.index) == [0])
        #expect(recovered.duration == 30)
    }

    @Test func aFinishedJournalIsLeftAlone() {
        var journal = RecordingJournal(startedAt: start)
        journal.openNextSegment()
        journal.finish(openDuration: 12)
        #expect(journal.recovered { _ in 0 } == journal)
    }

    @Test func theJournalSurvivesARelaunch() throws {
        var journal = RecordingJournal(id: "4b0f2c1e-6d8a-4c55-9a43-0d3f6f1e2a10", startedAt: start)
        journal.openNextSegment()
        _ = journal.mark(at: 3)
        let data = try JSONEncoder().encode(journal)
        #expect(try JSONDecoder().decode(RecordingJournal.self, from: data) == journal)
    }
}

struct RecordingTransferTests {
    private let id = "4b0f2c1e-6d8a-4c55-9a43-0d3f6f1e2a10"

    private func item(_ index: Int) -> RecordingOutbox.Item {
        .init(recordingId: id, index: index, file: RecordingJournal.fileName(index: index))
    }

    @Test func aSegmentIsSentAgainUntilTheIPhoneStoresIt() {
        var outbox = RecordingOutbox()
        outbox.enqueue(item(0))
        outbox.enqueue(item(1))
        outbox.enqueue(item(1))
        #expect(outbox.toSend(inFlight: []) == [item(0), item(1)])
        // Segment 0 is on its way; a failed transfer of segment 1 leaves it out of the system's queue.
        #expect(outbox.toSend(inFlight: [item(0)]) == [item(1)])
        let stored = outbox.acknowledge(recordingId: id, indices: [0])
        #expect(stored == [item(0)])
        #expect(outbox.toSend(inFlight: []) == [item(1)])
    }

    @Test func theRecordingFolderGoesOnlyOnceEverythingArrived() {
        var outbox = RecordingOutbox()
        outbox.enqueue(item(0))
        outbox.update(RecordingManifest(id: id, startedAt: Date(), duration: 30, markers: [], segmentCount: 1, isFinished: false))
        #expect(outbox.acknowledgeManifest(id: id) == false)
        outbox.update(RecordingManifest(id: id, startedAt: Date(), duration: 30, markers: [], segmentCount: 1, isFinished: true))
        #expect(outbox.acknowledgeManifest(id: id) == false)
        _ = outbox.acknowledge(recordingId: id, indices: [0])
        #expect(outbox.pending(recordingId: id) == 0)
        #expect(outbox.isEmpty)
    }

    @Test func theIPhoneWaitsForEverySegmentTheManifestAnnounces() {
        var arrival = RecordingArrival()
        arrival.receive(index: 1)
        #expect(!arrival.isComplete)
        arrival.manifest = RecordingManifest(id: id, startedAt: Date(), duration: 75, markers: [], segmentCount: 3, isFinished: false)
        #expect(arrival.missing == [0, 2])
        #expect(!arrival.isComplete)
        arrival.manifest?.isFinished = true
        arrival.receive(index: 0)
        arrival.receive(index: 2)
        #expect(arrival.isComplete)
    }
}
