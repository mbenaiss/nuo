import AVFoundation
import Foundation
import Testing

struct TranscriptionEngineTests {
    @Test func theCloudComesFirstThenWhisperThenApple() {
        #expect(TranscriptionEngine.order(cloudEnabled: true, cloudAvailable: nil, whisperReady: true, inBackground: false) == [.cloud, .whisper, .apple])
        #expect(TranscriptionEngine.order(cloudEnabled: true, cloudAvailable: true, whisperReady: false, inBackground: false) == [.cloud, .apple])
    }

    @Test func aGatewayWithoutServiceOrTheCloudSwitchedOffStaysOnTheDevice() {
        #expect(TranscriptionEngine.order(cloudEnabled: true, cloudAvailable: false, whisperReady: true, inBackground: false) == [.whisper, .apple])
        #expect(TranscriptionEngine.order(cloudEnabled: false, cloudAvailable: true, whisperReady: true, inBackground: false) == [.whisper, .apple])
    }

    @Test func inTheBackgroundWhisperIsSkippedForTheGPU() {
        #expect(TranscriptionEngine.order(cloudEnabled: true, cloudAvailable: true, whisperReady: true, inBackground: true) == [.cloud, .apple])
    }
}

struct TranscriptionFormTests {
    private func fields(_ form: TranscriptionForm) -> String {
        String(decoding: form.body, as: UTF8.self)
    }

    @Test func aDictationSendsItsLanguageNamesAndLength() {
        let audio = Data([0, 0, 0, 24, 102, 116, 121, 112])
        let form = TranscriptionForm(audio: audio, filename: "dictation.m4a", language: "fr", otherLanguages: ["en"],
                                     keyterms: ["Julie Martin", "Coach"], seconds: 6.42, boundary: "nuo-test-boundary")
        #expect(form.contentType == "multipart/form-data; boundary=nuo-test-boundary")
        let body = fields(form)
        #expect(body.contains("name=\"language\"\r\n\r\nfr\r\n"))
        #expect(body.contains("name=\"otherLanguages\"\r\n\r\nen\r\n"))
        #expect(body.contains("name=\"keyterms\"\r\n\r\n[\"Julie Martin\",\"Coach\"]\r\n"))
        #expect(body.contains("name=\"seconds\"\r\n\r\n6.4\r\n"))
        #expect(body.contains("name=\"audio\"; filename=\"dictation.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n"))
        #expect(!body.contains("speakers") && !body.contains("segments") && !body.contains("background"))
        let end = Data("\r\n--nuo-test-boundary--\r\n".utf8)
        #expect(form.body.suffix(end.count) == end)
    }

    @Test func aMeetingStreamAsksForSpeakersInTheBackground() {
        var form = TranscriptionForm(audio: Data([1, 2, 3]), filename: "meeting-them.m4a", language: "fr", segments: true, speakers: true,
                                     maxSpeakers: 3, seconds: 2710, boundary: "b")
        form.background = true
        form.jobID = "6f1c2b9e-4a7d-4c55-9e1f-2b8a7c3d1e40"
        let body = fields(form)
        #expect(body.contains("name=\"segments\"\r\n\r\ntrue"))
        #expect(body.contains("name=\"speakers\"\r\n\r\ntrue"))
        #expect(body.contains("name=\"maxSpeakers\"\r\n\r\n3"))
        #expect(body.contains("name=\"background\"\r\n\r\ntrue"))
        #expect(body.contains("name=\"id\"\r\n\r\n6f1c2b9e-4a7d-4c55-9e1f-2b8a7c3d1e40"))
    }

    @Test func frenchFirstWithEnglishTermsUnlessEnglishIsChosen() {
        func pair(_ code: String?, autoDetects: Bool = false) -> String {
            let result = TranscriptionForm.languages(code, autoDetects: autoDetects)
            return "\(result.language ?? "auto") \(result.others)"
        }
        #expect(pair(nil) == "fr [\"en\"]")
        #expect(pair("fr") == "fr [\"en\"]")
        #expect(pair("en") == "en [\"fr\"]")
        #expect(pair("de") == "de []")
    }

    @Test func aMeetingInAutoLeavesTheLanguageToTheService() {
        let auto = TranscriptionForm.languages(nil, autoDetects: true)
        #expect(auto.language == nil && auto.others.isEmpty)
        #expect(TranscriptionForm.languages("en", autoDetects: true).language == "en")
        let form = TranscriptionForm(audio: Data([1]), language: auto.language, otherLanguages: auto.others, seconds: 1800, boundary: "b")
        let body = String(decoding: form.body, as: UTF8.self)
        #expect(!body.contains("name=\"language\"") && !body.contains("otherLanguages"))
    }

    @Test func namesAreKeptOnceAndCapped() {
        let terms = DictationTerms.unique(["Alex", " Coach ", "coach", "", "Point hebdo Nuo", String(repeating: "Projet très long ", count: 4)], limit: 100)
        #expect(terms == ["Alex", "Coach", "Point hebdo Nuo"])
        #expect(DictationTerms.unique((1...150).map { "Projet \($0)" }, limit: 100).count == 100)
    }

    @Test func theDeadlineGrowsWithTheUploadAndTheAudio() {
        #expect(TranscriptionDeadline.seconds(forAudio: 8, bytes: 48_000) == 15 + 0.384 + 1.2)
        #expect(TranscriptionDeadline.seconds(forAudio: 7200, bytes: 40_000_000) == 15 + 320 + 1080)
        #expect(TranscriptionDeadline.seconds(forAudio: 100_000, bytes: 0) == 1800)
    }

    @Test func theGatewayAnswerDecodesWithOrWithoutSegments() throws {
        let dictation = try JSONDecoder().decode(CloudTranscript.self, from: Data("""
            {"text":"Peux-tu décaler le rendez-vous chez le kiné à vendredi ?","language":"fr","provider":"elevenlabs","model":"scribe_v3","ms":812}
            """.utf8))
        #expect(dictation.text == "Peux-tu décaler le rendez-vous chez le kiné à vendredi ?")
        #expect(dictation.segments == nil && dictation.ms == 812)
        let meeting = try JSONDecoder().decode(CloudTranscript.self, from: Data("""
            {"text":"On vise le vendredi 24.","segments":[{"start":44,"end":47.5,"text":"On vise le vendredi 24.","speaker":"2"}]}
            """.utf8))
        #expect(meeting.segments == [.init(start: 44, end: 47.5, text: "On vise le vendredi 24.", speaker: "2")])
    }
}

struct TranscriptionJobFailureTests {
    @Test func aJobTheProviderTurnedDownIsItsOwnFailureNotABusyGateway() throws {
        let state = try TranscriptionJob.state(status: 200, body: Data(#"{"status":"failed","error":{"status":429,"message":"ElevenLabs limite les transcriptions pour l'instant"}}"#.utf8))
        guard case let .failed(status, message) = state else {
            Issue.record("a failed job")
            return
        }
        let failure = TranscriptionJob.Failed(status: status, message: message)
        #expect(failure.status == 429)
        // Only a 429 to the upload itself means « come back later ».
        #expect(!TranscriptionPolling.keepsRacing(failure))
        #expect(TranscriptionPolling.keepsRacing(TranscriptionJob.Unreachable()))
    }
}

struct TranscriptionJobTests {
    @Test func aRunningJobADoneOneAndAFailedOne() throws {
        #expect(try TranscriptionJob.state(status: 202, body: Data(#"{"status":"running"}"#.utf8)) == .running)
        let done = try TranscriptionJob.state(status: 200, body: Data(#"{"status":"done","text":"On vise le vendredi 24.","language":"fr","segments":[{"start":44,"end":47.5,"text":"On vise le vendredi 24.","speaker":"1"}]}"#.utf8))
        #expect(done == .done(CloudTranscript(text: "On vise le vendredi 24.", language: "fr",
                                              segments: [.init(start: 44, end: 47.5, text: "On vise le vendredi 24.", speaker: "1")])))
        #expect(try TranscriptionJob.state(status: 200, body: Data(#"{"status":"failed","error":{"status":429,"message":"ElevenLabs limite les transcriptions"}}"#.utf8))
            == .failed(status: 429, message: "ElevenLabs limite les transcriptions"))
    }

    @Test func aProxyPageIsNotAJobsAnswer() {
        #expect(throws: TranscriptionJob.Unreadable.self) { try TranscriptionJob.state(status: 200, body: Data("<html>Bad gateway</html>".utf8)) }
    }
}

struct DeadlineTests {
    @Test func theAnswerComesOnTimeEvenWhenTheWorkCannotBeCancelled() async {
        let clock = ContinuousClock.now
        let answer = await Deadline.first(within: .milliseconds(100), otherwise: "pas de réponse") {
            try? await Task.sleep(for: .seconds(3))
            return "passerelle"
        }
        #expect(answer == "pas de réponse")
        #expect(ContinuousClock.now - clock < .seconds(1))
        #expect(await Deadline.first(within: .seconds(2), otherwise: "pas de réponse") { "passerelle" } == "passerelle")
    }
}

struct DeadlineCancellationTests {
    @Test func aCancelledCallerIsAnsweredAtOnce() async {
        let clock = ContinuousClock.now
        let waiting = Task {
            await Deadline.first(within: .seconds(3), otherwise: "abandon") {
                try? await Task.sleep(for: .seconds(5))
                return "passerelle"
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        waiting.cancel()
        #expect(await waiting.value == "abandon")
        #expect(ContinuousClock.now - clock < .seconds(1))
    }
}

struct PollingSilenceTests {
    @Test func twoMinutesWithoutTheGatewayEndTheWait() {
        let start = Date(timeIntervalSince1970: 1_792_400_000)
        var silence = TranscriptionPolling.Silence()
        let first = silence.unanswered(at: start)
        let ninety = silence.unanswered(at: start.addingTimeInterval(90))
        silence.answered()
        let againAt100 = silence.unanswered(at: start.addingTimeInterval(100))
        let at219 = silence.unanswered(at: start.addingTimeInterval(219))
        let at220 = silence.unanswered(at: start.addingTimeInterval(220))
        #expect(!first && !ninety)
        #expect(!againAt100 && !at219)
        #expect(at220)
    }
}

struct AACWriterTests {
    private final class BundleToken {}

    private static var bench: URL {
        get throws {
            try #require(Bundle(for: BundleToken.self).url(forResource: "dictation-bench-60s", withExtension: "wav"))
        }
    }

    private static func samples(of url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: input)
        let converter = AVAudioConverter(from: file.processingFormat, to: target)!
        let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(file.length) * 16_000 / file.processingFormat.sampleRate) + 64)!
        nonisolated(unsafe) var given = false
        converter.convert(to: output, error: nil) { _, status in
            if given { status.pointee = .endOfStream; return nil }
            given = true
            status.pointee = .haveData
            return input
        }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    /// A minute of French dictation: five times smaller than 16-bit PCM, encoded at least ten times faster than real time, same length.
    @Test func aMinuteOfDictationIsSmallAndQuickToEncode() throws {
        let samples = try Self.samples(of: Self.bench)
        let url = URL.temporaryDirectory.appending(path: "aac-writer-test-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        var data = Data()
        var runs: [Duration] = []
        for _ in 0..<3 {
            try? FileManager.default.removeItem(at: url)
            let clock = ContinuousClock.now
            data = try AACWriter.encode(samples, to: url)
            runs.append(ContinuousClock.now - clock)
        }
        let elapsed = try #require(runs.min())
        let pcmBytes = samples.count * 2
        let audio = Duration.seconds(Double(samples.count) / 16_000)
        print("AAC 48 kbit/s: \(samples.count / 16_000) s of audio, \(data.count) bytes (PCM \(pcmBytes)), encoded in \(elapsed)")
        #expect(Double(pcmBytes) / Double(data.count) > 4)
        // Best of three, relative to the audio length: a loaded machine slows one run, not all three by tenfold.
        #expect(elapsed < audio / 10)
        let decoded = try AVAudioFile(forReading: url)
        #expect(decoded.fileFormat.channelCount == 1)
        #expect(abs(Double(decoded.length) / decoded.fileFormat.sampleRate - Double(samples.count) / 16_000) < 0.1)
    }

    @Test func aStreamWrittenInBlocksIsOneFile() throws {
        let url = URL.temporaryDirectory.appending(path: "aac-writer-blocks-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AACWriter(url: url)
        let tone = (0..<16_000).map { 0.1 * sin(2 * Float.pi * 220 * Float($0) / 16_000) }
        for _ in 0..<3 { try writer.append(tone) }
        writer.close()
        #expect(writer.samplesWritten == 48_000)
        let decoded = try AVAudioFile(forReading: url)
        #expect(abs(Double(decoded.length) / decoded.fileFormat.sampleRate - 3) < 0.1)
    }
}
