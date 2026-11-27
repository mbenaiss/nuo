@preconcurrency import AVFoundation
import Foundation
import Testing

/// The watch's one button: a request under a minute, a recorded meeting past it.
struct WatchCaptureRuleTests {
    private let startedAt = Date(timeIntervalSince1970: 1_794_650_400)

    @Test func whatIsSaidInUnderAMinuteLeavesAsARequest() {
        // « Rappelle-moi d'appeler Julie Martin demain à 9 h », stopped after 4.2 s.
        #expect(CaptureRule.ending(seconds: 4.2, tentative: true) == .request)
        #expect(CaptureRule.ending(seconds: CaptureRule.shortestRequest, tentative: true) == .request)
        #expect(CaptureRule.ending(seconds: 59.9, tentative: true) == .request)
    }

    @Test func aTapByMistakeSendsNothing() {
        #expect(CaptureRule.ending(seconds: 0.3, tentative: true) == .discard)
        #expect(CaptureRule.ending(seconds: 0, tentative: true) == .discard)
    }

    @Test func pastTheMinuteAStopFinishesTheRecording() {
        #expect(CaptureRule.becomesRecording(seconds: 59.9) == false)
        #expect(CaptureRule.becomesRecording(seconds: 60))
        #expect(CaptureRule.ending(seconds: 754, tentative: false) == .recording)
        // Back from a pause right after the switch: still the meeting, never a request.
        #expect(CaptureRule.ending(seconds: 0.2, tentative: false) == .recording)
    }

    @Test func theFirstPieceIsEncodedLikeARequest() {
        #expect(CaptureRule.bitRate(ofSegment: 0) == 32_000)
        #expect(CaptureRule.bitRate(ofSegment: 1) == AACWriter.bitRate)
        #expect(CaptureRule.bitRate(ofSegment: 24) == AACWriter.bitRate)
    }

    @Test func theFirstPieceHoldsTheMinuteThenThirtySecondsEach() {
        #expect(RecordingJournal.seconds(ofSegment: 0) == 60)
        #expect(RecordingJournal.seconds(ofSegment: 1) == 30)
        #expect(RecordingJournal.seconds(ofSegment: 12) == 30)
        #expect(CaptureRule.requestLimit == RecordingJournal.seconds(ofSegment: 0))
    }

    @Test func theIPhoneReadsTheLongerFirstPieceFromTheManifest() {
        // A team meeting of 1 min 42 s: the first minute, one 30 s piece, then 12.4 s until « Stop ».
        var journal = RecordingJournal(id: "6e1d9c42-3b7a-4f85-a0c2-9d4e7b1f3a58", startedAt: startedAt)
        for index in 0..<2 {
            journal.openNextSegment()
            journal.closeSegment(duration: RecordingJournal.seconds(ofSegment: index))
        }
        journal.openNextSegment()
        journal.finish(openDuration: 12.4)
        let manifest = journal.manifest
        #expect(manifest.segmentDurations == [60, 30, 12.4])
        #expect(manifest.segmentCount == 3)
        #expect(abs(manifest.duration - 102.4) < 0.001)

        var arrival = RecordingArrival()
        arrival.manifest = manifest
        #expect(arrival.seconds(of: 0, total: manifest.duration) == 60)
        #expect(arrival.seconds(of: 1, total: manifest.duration) == 30)
        #expect(arrival.seconds(of: 2, total: manifest.duration) == 12.4)
    }

    @Test func aShortRequestFitsInALiveMessage() throws {
        let folder = URL.temporaryDirectory.appending(path: "capture-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let request = folder.appending(path: "segment-0000.m4a"), meeting = folder.appending(path: "segment-0001.m4a")
        try write(seconds: 10, to: request, bitRate: CaptureRule.bitRate(ofSegment: 0))
        try write(seconds: 10, to: meeting, bitRate: CaptureRule.bitRate(ofSegment: 1))
        let requestSize = try Data(contentsOf: request).count, meetingSize = try Data(contentsOf: meeting).count
        // What a WatchConnectivity message carries (`AskCenter.liveMessageLimit`).
        #expect(requestSize < 60_000)
        #expect(requestSize < meetingSize)
    }

    @Test func aMeetingAssemblesAcrossTheSwitchWithoutAGap() throws {
        let folder = URL.temporaryDirectory.appending(path: "switch-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appending(path: RecordingJournal.fileName(index: 0)), second = folder.appending(path: RecordingJournal.fileName(index: 1))
        try write(seconds: 60, to: first, bitRate: CaptureRule.bitRate(ofSegment: 0))
        try write(seconds: 7.5, to: second, bitRate: CaptureRule.bitRate(ofSegment: 1))
        let report = try RecordingAudio.assembleAtomically([
            .init(index: 0, url: first, seconds: 60),
            .init(index: 1, url: second, seconds: 7.5),
        ], into: folder.appending(path: RecordingAudio.fileName))
        #expect(report.missing.isEmpty)
        #expect(report.unreadable.isEmpty)
        #expect(abs(report.seconds - 67.5) < 0.05)
    }

    private func write(seconds: Double, to url: URL, bitRate: Int) throws {
        let count = Int(seconds * Double(AACWriter.sampleRate))
        let samples = (0..<count).map { Float(sin(Double($0) * 2 * .pi * 180 / Double(AACWriter.sampleRate)) * 0.3 * (1 + sin(Double($0) * 0.0004)) / 2) }
        let writer = try AACWriter(url: url, bitRate: bitRate)
        try writer.append(samples)
        writer.close()
    }
}
