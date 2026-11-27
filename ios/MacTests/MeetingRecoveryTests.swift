import Foundation
import Testing

struct MeetingRecoveryTests {
    private let startedAt = Date(timeIntervalSince1970: 1_792_400_000)

    private func archive(resume: MeetingResume?) -> MeetingArchive {
        var transcript = MeetingTranscript()
        transcript.insert("On valide la date de la bêta au vendredi 24.", speaker: .them, start: 44, end: 47)
        return MeetingArchive(
            title: "Point hebdo produit", participants: "Léa Martin, Hugo Bernard", notes: "Bêta : vendredi 24", eventId: "evt-2026-1026-hebdo",
            startedAt: startedAt, endedAt: startedAt.addingTimeInterval(1_840), transcript: transcript, note: nil, savedPath: nil,
            resume: resume)
    }

    @Test func anArchiveWrittenBeforeResumeExistedStillReads() throws {
        let legacy = """
        {"title":"Point hebdo produit","participants":"Léa Martin","notes":"","startedAt":0,"endedAt":1840,"transcript":{"segments":[]}}
        """
        let decoded = try JSONDecoder().decode(MeetingArchive.self, from: Data(legacy.utf8))
        #expect(decoded.title == "Point hebdo produit")
        #expect(decoded.resume == nil)
    }

    @Test func anInterruptedMeetingKeepsWhereEachStreamWasTranscribed() throws {
        let resume = MeetingResume(engine: .whisper, streams: [
            .init(speaker: .me, file: "6F1C-moi.caf", startOffset: 0.12, cursor: 1_920_000),
            .init(speaker: .them, file: "6F1C-eux.caf", startOffset: 0.4, cursor: 1_440_000),
        ])
        let data = try JSONEncoder().encode(archive(resume: resume))
        let decoded = try JSONDecoder().decode(MeetingArchive.self, from: data)
        #expect(decoded.resume == resume)
        #expect(decoded.transcript.segments.count == 1)
    }

    @Test func eachStreamKeepsItsGatewayJobAcrossARestart() throws {
        let resume = MeetingResume(engine: .whisper, streams: [
            .init(speaker: .me, file: "6F1C-moi.caf", startOffset: 0.12, cursor: 0, jobID: "6f1c2b9e-4a7d-4c55-9e1f-2b8a7c3d1e40"),
            .init(speaker: .them, file: "6F1C-eux.caf", startOffset: 0.4, cursor: 0, jobID: "6f1c2b9e-4a7d-4c55-9e1f-2b8a7c3d1e41"),
        ])
        let decoded = try JSONDecoder().decode(MeetingArchive.self, from: JSONEncoder().encode(archive(resume: resume)))
        #expect(decoded.resume?.streams.map(\.jobID) == ["6f1c2b9e-4a7d-4c55-9e1f-2b8a7c3d1e40", "6f1c2b9e-4a7d-4c55-9e1f-2b8a7c3d1e41"])
        let older = #"{"engine":"whisper","streams":[{"speaker":"me","file":"6F1C-moi.caf","cursor":0}]}"#
        #expect(try JSONDecoder().decode(MeetingResume.self, from: Data(older.utf8)).streams.first?.jobID == nil)
    }

    @Test func aCloudTranscriptStaysLabelledAfterARelaunch() throws {
        var saved = archive(resume: nil)
        saved.transcribedInCloud = true
        let decoded = try JSONDecoder().decode(MeetingArchive.self, from: JSONEncoder().encode(saved))
        #expect(decoded.transcribedInCloud == true)
        let older = #"{"title":"Point hebdo produit","participants":"","notes":"","startedAt":0,"endedAt":1840,"transcript":{"segments":[]}}"#
        #expect(try JSONDecoder().decode(MeetingArchive.self, from: Data(older.utf8)).transcribedInCloud == nil)
    }

    @Test func onlyStreamsWhoseAudioIsStillThereCanResume() {
        let resume = MeetingResume(engine: .apple, streams: [
            .init(speaker: .me, file: "6F1C-moi.caf", startOffset: 0, cursor: 0),
            .init(speaker: .them, file: "6F1C-eux.caf", startOffset: nil, cursor: 0),
        ])
        let directory = URL(filePath: "/tmp/Meetings")
        let available = resume.available(in: directory) { $0.lastPathComponent == "6F1C-moi.caf" }
        #expect(available.map(\.speaker) == [.me])
    }

    @Test func audioOfAnyOtherMeetingIsRemovedAtLaunch() {
        let resume = MeetingResume(engine: .whisper, streams: [.init(speaker: .me, file: "6F1C-moi.caf", startOffset: 0, cursor: 0)])
        let files = ["6F1C-moi.caf", "A03B-moi.caf", "A03B-eux.caf"]
        #expect(MeetingResume.orphans(files, keeping: resume) == ["A03B-moi.caf", "A03B-eux.caf"])
        #expect(MeetingResume.orphans(files, keeping: nil) == files)
    }

    @Test func aCrashFourteenMinutesInKeepsTheLengthNotesAndTitle() throws {
        let resume = MeetingResume(engine: .whisper, streams: [
            .init(speaker: .me, file: "6F1C-moi.caf", startOffset: 0.12, cursor: 0),
            .init(speaker: .them, file: "6F1C-eux.caf", startOffset: 0.4, cursor: 0),
        ])
        let now = startedAt.addingTimeInterval(14 * 60 + 32)
        let saved = MeetingArchive.inProgress(
            title: "Point hebdo Nuo", participants: "Léa Martin, Hugo Bernard", notes: "Bêta : vendredi 24 ?\nMaquettes → Léa ce soir",
            eventId: "evt-2026-1114-hebdo", startedAt: startedAt, endedAt: nil, now: now, transcript: MeetingTranscript(), resume: resume)
        let restored = try JSONDecoder().decode(MeetingArchive.self, from: JSONEncoder().encode(saved))
        #expect(restored.title == "Point hebdo Nuo")
        #expect(restored.participants == "Léa Martin, Hugo Bernard")
        #expect(restored.notes == "Bêta : vendredi 24 ?\nMaquettes → Léa ce soir")
        // Long enough for a note (60 s), not stuck at the start of the meeting.
        #expect(restored.endedAt.timeIntervalSince(restored.startedAt) == 872)
        #expect(restored.resume == resume)
    }

    @Test func aStoppedMeetingKeepsItsRealEnd() {
        let end = startedAt.addingTimeInterval(1_840)
        let saved = MeetingArchive.inProgress(
            title: "Point hebdo Nuo", participants: "", notes: "", eventId: nil, startedAt: startedAt, endedAt: end,
            now: end.addingTimeInterval(600), transcript: MeetingTranscript(), resume: MeetingResume(engine: .apple, streams: []))
        #expect(saved.endedAt == end)
    }

    @Test func theRecordingIsSavedEveryHalfMinute() {
        #expect(!MeetingArchive.saveIsDue(last: startedAt, now: startedAt.addingTimeInterval(29.9)))
        #expect(MeetingArchive.saveIsDue(last: startedAt, now: startedAt.addingTimeInterval(30)))
    }

    @Test func stopsTheGatewayDidNotHearWaitTheirTurn() throws {
        var queue = MeetingPendingDeletes()
        queue.add(["6f1c2b9e-4a7d-4c55-9e1f-2b8a7c3d1e40", "6f1c2b9e-4a7d-4c55-9e1f-2b8a7c3d1e41"])
        queue.add(["6f1c2b9e-4a7d-4c55-9e1f-2b8a7c3d1e40"])
        #expect(queue.ids.count == 2)
        queue.done("6f1c2b9e-4a7d-4c55-9e1f-2b8a7c3d1e40")
        #expect(queue.ids == ["6f1c2b9e-4a7d-4c55-9e1f-2b8a7c3d1e41"])
        let decoded = try JSONDecoder().decode(MeetingPendingDeletes.self, from: JSONEncoder().encode(queue))
        #expect(decoded == queue)
        var full = MeetingPendingDeletes()
        full.add((0..<250).map { "job-\($0)" })
        #expect(full.ids.count == MeetingPendingDeletes.limit && full.ids.first == "job-50")
    }

    @Test func quittingWarnsWhileRecordingThenWhileTranscribing() {
        #expect(MeetingQuitReason.reason(recording: true, finalizing: false) == "A meeting is being recorded")
        #expect(MeetingQuitReason.reason(recording: false, finalizing: true) == "The meeting transcript isn't finished")
        #expect(MeetingQuitReason.reason(recording: false, finalizing: false) == nil)
    }
}

struct MeetingDeadlineTests {
    @Test func aChunkGetsAMinuteThenFourTimesItsLength() {
        #expect(MeetingDeadline.seconds(forSamples: 90 * 16_000, rate: 16_000) == 420)
        #expect(MeetingDeadline.seconds(forSamples: 0, rate: 16_000) == 60)
    }

    @Test func aStuckChunkTimesOut() async {
        await #expect(throws: MeetingDeadline.TimedOut.self) {
            try await MeetingDeadline.run(seconds: 0.05) {
                try await Task.sleep(for: .seconds(30))
                return "Côté design, les maquettes sont prêtes."
            }
        }
    }

    @Test func aChunkInTimeReturnsItsText() async throws {
        let text = try await MeetingDeadline.run(seconds: 5) { "Je te les envoie ce soir." }
        #expect(text == "Je te les envoie ce soir.")
    }
}

struct MeetingTimelineTests {
    private let rate = 16_000

    @Test func steadyCaptureNeedsNoSilence() {
        #expect(MeetingTimeline.silence(written: 10 * rate, expectedEnd: 10 * rate + 1_365, incoming: 1_365, tolerance: rate) == 0)
    }

    @Test func callbackJitterIsLeftAlone() {
        #expect(MeetingTimeline.silence(written: 10 * rate, expectedEnd: 10 * rate + 1_365 + rate / 2, incoming: 1_365, tolerance: rate) == 0)
    }

    @Test func aDeviceSwitchGapIsFilledSoBothSpeakersStayInStep() {
        // AirPods took 3 s to come up: the next buffer belongs 3 s later than the samples written so far.
        #expect(MeetingTimeline.silence(written: 10 * rate, expectedEnd: 13 * rate + 1_365, incoming: 1_365, tolerance: rate) == 3 * rate)
    }

    @Test func aStreamAheadOfTheClockIsNotCut() {
        #expect(MeetingTimeline.silence(written: 12 * rate, expectedEnd: 10 * rate, incoming: 1_365, tolerance: rate) == 0)
    }
}

struct MeetingTapBufferTests {
    @Test func theTapAloneIsItsOwnBuffer() {
        #expect(MeetingTapBuffer.range(channels: [1], expected: 1, interleaved: false) == 0..<1)
    }

    @Test func aHeadsetMicListedFirstIsSkipped() {
        // A USB headset's stereo mic comes before the mono tap in the aggregate's input.
        #expect(MeetingTapBuffer.range(channels: [2, 1], expected: 1, interleaved: true) == 1..<2)
    }

    @Test func aNonInterleavedStereoTapTakesTheLastBuffers() {
        #expect(MeetingTapBuffer.range(channels: [1, 1, 1], expected: 2, interleaved: false) == 1..<3)
        #expect(MeetingTapBuffer.range(channels: [], expected: 1, interleaved: false) == nil)
    }
}
