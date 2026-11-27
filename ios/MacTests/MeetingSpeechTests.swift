import Foundation
import Testing

struct MeetingSpeechTests {
    private let rate = MeetingSpeech.sampleRate

    private func silence(_ seconds: Double) -> [Float] {
        Array(repeating: 0, count: Int(seconds * Double(rate)))
    }

    /// A 220 Hz tone standing in for a voice.
    private func voice(_ seconds: Double, amplitude: Float = 0.1) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { amplitude * sin(2 * .pi * 220 * Float($0) / Float(rate)) }
    }

    @Test func energyIsTheRMSOfEach100msFrame() {
        let energy = MeetingSpeech.energy(voice(1))
        #expect(energy.count == 10)
        #expect(energy.allSatisfy { abs($0 - 0.0707) < 0.002 })
    }

    @Test func thresholdStaysLowWhenTheChunkIsAllSpeech() {
        let energy = MeetingSpeech.energy(voice(10, amplitude: 0.5))
        #expect(MeetingSpeech.threshold(energy) == 0.015)
        #expect(MeetingSpeech.threshold(MeetingSpeech.energy(silence(3))) == 0.003)
    }

    @Test func regionsJoinShortPausesAndDropClicks() {
        // « Bonjour… on commence ? », a long silence, then a click on the desk.
        let samples = silence(2) + voice(1.5) + silence(0.4) + voice(1) + silence(3) + voice(0.1) + silence(1)
        let energy = MeetingSpeech.energy(samples)
        let regions = MeetingSpeech.regions(energy, threshold: MeetingSpeech.threshold(energy))
        #expect(regions == [17..<52])
    }

    @Test func regionsKeepTwoSentencesSeparatedByALongPause() {
        let samples = voice(2) + silence(4) + voice(2)
        let energy = MeetingSpeech.energy(samples)
        let regions = MeetingSpeech.regions(energy, threshold: MeetingSpeech.threshold(energy))
        #expect(regions.count == 2)
    }

    @Test func compactedTimeMapsBackToTheRecording() {
        let samples = silence(10) + voice(2) + silence(20) + voice(3)
        let energy = MeetingSpeech.energy(samples)
        let compacted = MeetingSpeech.compact(samples, regions: MeetingSpeech.regions(energy, threshold: MeetingSpeech.threshold(energy)))
        // 2.6 s + 0.3 s pause + 3.3 s: each sentence widened by 0.3 s on both sides, within the chunk.
        #expect(abs(compacted.seconds - 6.2) < 0.01)
        #expect(abs(compacted.sourceTime(0) - 9.7) < 0.01)
        #expect(abs(compacted.sourceTime(1) - 10.7) < 0.01)
        // Just after the inserted pause: the start of the second sentence.
        #expect(abs(compacted.sourceTime(2.95) - 31.75) < 0.01)
    }

    @Test func normalizationRaisesAFaintVoiceWithoutClipping() {
        let faint = MeetingSpeech.normalized(voice(1, amplitude: 0.01))
        #expect(abs(MeetingSpeech.rms(faint[...]) - 0.0566) < 0.002)
        let loud = MeetingSpeech.normalized(voice(1, amplitude: 0.99))
        #expect(loud.allSatisfy { abs($0) <= 0.95 })
        let normal = voice(1, amplitude: 0.113)
        #expect(MeetingSpeech.normalized(normal) == normal)
    }

    @Test func cutFallsInTheLastPauseAfterTheMinimum() {
        let samples = voice(3) + silence(1) + voice(16) + silence(1) + voice(5) + silence(0.8) + voice(2)
        let energy = MeetingSpeech.energy(samples)
        let cut = MeetingSpeech.cut(energy, threshold: MeetingSpeech.threshold(energy), after: 150)
        // Middle of the 0.8 s pause that starts at 26 s.
        #expect(cut == 264)
    }

    @Test func cutWaitsWhenThePauseRunsToTheEnd() {
        let samples = voice(18) + silence(2)
        let energy = MeetingSpeech.energy(samples)
        #expect(MeetingSpeech.cut(energy, threshold: MeetingSpeech.threshold(energy), after: 150) == nil)
    }

    @Test func aBlockKeepsItsVoiceOnTheStreamsClock() {
        let block = silence(2) + voice(3) + silence(4) + voice(2)
        let voiced = MeetingSpeech.voiced(block, blockStart: 60 * rate, keptSoFar: 0, previous: nil)
        #expect(voiced.pieces.count == 2)
        // Each region is padded by 0.3 s so the first and last syllables stay.
        #expect(voiced.pieces[0].at == 0 && voiced.pieces[0].source == 60 * rate + Int(1.7 * Double(rate)))
        #expect(voiced.pieces[1].at == voiced.pieces[0].count + 4_800)
        #expect(voiced.samples.count == voiced.pieces[1].at + voiced.pieces[1].count)
        // 3.6 s into the compacted audio is in the second region, 9 s into the block, 69 s into the stream.
        let second = Double(voiced.pieces[1].at) / Double(rate) + 0.3
        #expect(abs(voiced.sourceTime(second) - 69) < 0.01)
    }

    @Test func speechRunningAcrossTwoBlocksIsNotCutByAPause() {
        let first = silence(58) + voice(2)
        let second = voice(1.5) + silence(58.5)
        let a = MeetingSpeech.voiced(first, blockStart: 0, keptSoFar: 0, previous: nil)
        let b = MeetingSpeech.voiced(second, blockStart: first.count, keptSoFar: a.samples.count, previous: a.pieces.last)
        #expect(b.pieces.first?.at == a.samples.count)
        #expect(b.pieces.first?.source == first.count)
    }

    @Test func theSentAudioIsCutWhereSilencesWereRemoved() {
        let map = MeetingSpeech.Compacted(samples: [], pieces: [
            .init(at: 0, source: 10 * 16_000, count: 16_000),
            .init(at: 16_000 + 4_800, source: 310 * 16_000, count: 3 * 16_000),
            // Carries on from the previous block: no cut.
            .init(at: 16_000 + 4_800 + 3 * 16_000, source: 313 * 16_000, count: 16_000),
        ])
        #expect(MeetingSpeech.breaks(map) == [1.3])
    }

    @Test func aTimePastTheSentAudioStaysWithinIt() {
        let map = MeetingSpeech.Compacted(samples: [], pieces: [.init(at: 0, source: 60 * 16_000, count: 2 * 16_000)])
        #expect(map.sourceTime(1) == 61)
        #expect(map.sourceTime(30) == 62)
        #expect(map.sourceTime(1e300) == 62)
        #expect(map.sourceTime(-4) == 60)
        #expect(map.sourceTime(.nan) == 60)
    }

    @Test func silenceGivesNothingToSend() {
        let voiced = MeetingSpeech.voiced(silence(60), blockStart: 0, keptSoFar: 0, previous: nil)
        #expect(voiced.samples.isEmpty && voiced.pieces.isEmpty)
    }

    @Test func quietestFrameOfARange() {
        let energy: [Float] = [0.2, 0.1, 0.3, 0.01, 0.2, 0.05]
        #expect(MeetingSpeech.quietest(energy, in: 0..<6) == 3)
        #expect(MeetingSpeech.quietest(energy, in: 4..<10) == 5)
    }
}
