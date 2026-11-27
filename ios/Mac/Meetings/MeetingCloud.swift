import Foundation

/// A finished meeting transcribed by the gateway's service, in one pass per stream: only the voice is sent (the
/// others' stream is silent whenever the user talks), as AAC, and the gateway tells the other participants apart.
enum MeetingCloud {
    struct Stream: Sendable {
        let speaker: MeetingSpeaker
        let url: URL
        let startOffset: TimeInterval
        /// Names the stream's job on the gateway, kept with the meeting: a retry finds the job instead of sending it again.
        let jobID: String
    }

    struct Result: Sendable {
        var transcript: MeetingTranscript
        var language: String?
    }

    struct Request: Sendable {
        var language: String?
        var terms: [String]
        var voices: (diarize: Bool, max: Int?)
    }

    struct Prepared: Sendable {
        let stream: Stream
        let audio: Data
        let map: MeetingSpeech.Compacted
        var seconds: Double { Double(map.pieces.last.map { $0.at + $0.count } ?? 0) / Double(MeetingSpeech.sampleRate) }
        /// Where the sent audio jumps over a silence: no line may run across one.
        var breaks: [Double] { MeetingSpeech.breaks(map) }
    }

    /// A minute at a time, so a two-hour meeting never sits in memory.
    private static let block = 60 * MeetingSpeech.sampleRate

    /// The voice of a stream as an .m4a; nil when it holds less than a second of it.
    static func prepare(_ stream: Stream, progress: @Sendable (Double) -> Void) throws -> Prepared? {
        let total = MeetingStreamReader.frameCount(stream.url)
        let out = URL.temporaryDirectory.appending(path: "meeting-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: out) }
        let writer = try AACWriter(url: out)
        var pieces: [MeetingSpeech.Compacted.Piece] = []
        var start = 0
        while start < total {
            try Task.checkCancellation()
            let samples = try MeetingStreamReader.read(stream.url, from: start, count: min(block, total - start))
            guard !samples.isEmpty else { break }
            let voiced = MeetingSpeech.voiced(samples, blockStart: start, keptSoFar: writer.samplesWritten, previous: pieces.last)
            try writer.append(voiced.samples)
            pieces += voiced.pieces
            start += samples.count
            progress(Double(start) / Double(max(total, 1)))
        }
        writer.close()
        let voice = pieces.reduce(0) { $0 + $1.count }
        guard voice >= MeetingSpeech.sampleRate else { return nil }
        return Prepared(stream: stream, audio: try Data(contentsOf: out), map: MeetingSpeech.Compacted(samples: [], pieces: pieces))
    }

    /// The meeting's transcript and the language heard. Throws when the gateway is away, a stream fails, or every
    /// stream came back empty: the Mac then does it all.
    static func transcribe(_ streams: [Stream], request: Request, client: NuoClient,
                           progress: @escaping @MainActor (Double) -> Void) async throws -> Result {
        // A gateway that does not answer sends the meeting to the Mac in seconds, not after a long upload's wait, even
        // when the warm-up waits on a token refresh it cannot cancel.
        let reach = await Deadline.first(within: .seconds(8), otherwise: Reach.silent) { () -> Reach in
            do {
                _ = try await client.warmTranscription(timeout: 8)
                return .reached
            } catch NuoError.notFound {
                return .noService
            } catch {
                return .silent
            }
        }
        switch reach {
        case .reached: break
        // A gateway without a provider will not get one by asking again: the Mac does it, and nobody asks again.
        case .noService: throw MeetingNoTranscriptionService()
        case .silent: throw TranscriptionJob.Unreachable()
        }
        let preparing = streams.map { _ in Progress() }
        let prepared = try await withThrowingTaskGroup(of: (Int, Prepared?).self) { group in
            for (index, stream) in streams.enumerated() {
                group.addTask(priority: .userInitiated) {
                    let result = try prepare(stream) { fraction in
                        preparing[index].set(fraction)
                        let all = preparing.reduce(0) { $0 + $1.value } / Double(max(preparing.count, 1))
                        Task { @MainActor in progress(0.2 * all) }
                    }
                    return (index, result)
                }
            }
            var results = [Prepared?](repeating: nil, count: streams.count)
            for try await (index, result) in group { results[index] = result }
            return results.compactMap { $0 }
        }
        let languages = TranscriptionForm.languages(request.language, autoDetects: true)
        let seconds = prepared.reduce(0) { $0 + $1.seconds }
        let bytes = prepared.reduce(0) { $0 + $1.audio.count }
        let started = Date()
        // Cloud services run many times faster than real time; the bar eases towards the end and never claims to be done.
        let expected = 10 + seconds * 0.04 + Double(bytes) * 8 / 20_000_000
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                progress(0.2 + 0.75 * (1 - exp(-Date().timeIntervalSince(started) / expected)))
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { ticker.cancel() }
        let replies = try await withThrowingTaskGroup(of: (Prepared, CloudTranscript).self) { group in
            for item in prepared {
                let speakers = item.stream.speaker == .them && request.voices.diarize
                let form = TranscriptionForm(
                    audio: item.audio, filename: "meeting-\(item.stream.speaker.rawValue).m4a", language: languages.language,
                    otherLanguages: languages.others, keyterms: request.terms, segments: true, speakers: speakers,
                    maxSpeakers: speakers ? request.voices.max : nil, seconds: item.seconds)
                var named = form
                named.jobID = item.stream.jobID
                named.breaks = item.breaks
                // The upload keeps sending data: a minute without any is a dead connection. The job then gets its time.
                let poll = min(3600, 300 + TranscriptionDeadline.seconds(forAudio: item.seconds, bytes: item.audio.count) * 2)
                group.addTask {
                    do {
                        return (item, try await stream(named, client: client, poll: poll))
                    } catch let failed as TranscriptionJob.Failed {
                        // Only this stream's job failed: the other one, maybe done, is kept for the next try.
                        throw MeetingStreamFailed(speaker: item.stream.speaker, status: failed.status, message: failed.message)
                    }
                }
            }
            var replies: [(Prepared, CloudTranscript)] = []
            for try await reply in group { replies.append(reply) }
            return replies
        }
        if MeetingVoices.allEmpty(replies.map { (sentSeconds: $0.0.seconds, segments: $0.1.segments?.count ?? 0) }) { throw EmptyTranscript() }
        var transcript = MeetingTranscript()
        for (item, reply) in replies {
            transcript.insert(cloud: reply.segments ?? [], speaker: item.stream.speaker, map: item.map, startOffset: item.stream.startOffset,
                              language: reply.language ?? languages.language)
        }
        NSLog("Nuo meeting: cloud transcript of %.0f s of voice (%d KB) in %.1f s", seconds, bytes / 1024, Date().timeIntervalSince(started))
        return Result(transcript: transcript, language: replies.lazy.compactMap(\.1.language).first)
    }

    private enum Reach: Sendable { case reached, noService, silent }

    /// A stream's job: found on the gateway when it was sent before (a retry, a restart), sent otherwise. A network
    /// failure on the way, or a gateway too busy for a named job (429), is the gateway being away, not the job failing:
    /// the caller keeps the race going.
    private static func stream(_ form: TranscriptionForm, client: NuoClient, poll: TimeInterval) async throws -> CloudTranscript {
        do {
            if let id = form.jobID, let transcript = try await existing(id, client: client, poll: poll) { return transcript }
            do {
                return try await client.transcribe(form, background: true, timeout: 60, pollFor: poll)
            } catch NuoError.notFound where form.jobID != nil {
                // Accepted, then unknown: the upload it was waiting on died. The next round finds nothing and sends again.
                throw TranscriptionJob.Unreachable()
            }
        } catch let error where !(error is TranscriptionJob.Unreachable) && TranscriptionPolling.keepsRacing(error) {
            throw TranscriptionJob.Unreachable()
        }
    }

    /// Whether every stream's job is past running on the gateway: a follower asks this before preparing any audio, so
    /// nothing is encoded again while the gateway works. Every stream is asked, so a failure of the last one is not seen
    /// a round late: it throws `MeetingStreamFailed`.
    static func settled(_ streams: [Stream], client: NuoClient) async throws -> Bool {
        var running = false
        for stream in streams {
            do {
                switch try await client.transcriptionJob(stream.jobID) {
                case .running: running = true
                case .done: continue
                case let .failed(status, message): throw MeetingStreamFailed(speaker: stream.speaker, status: status, message: message)
                }
            } catch NuoError.notFound {
                // Never sent (a silent stream) or lost: the full pass sends it.
                continue
            } catch let error where !(error is MeetingStreamFailed) && TranscriptionPolling.keepsRacing(error) {
                throw TranscriptionJob.Unreachable()
            }
        }
        return !running
    }

    /// The job sent before under this id, waited for; nil when the gateway does not know it, and the audio must go.
    private static func existing(_ id: String, client: NuoClient, poll: TimeInterval) async throws -> CloudTranscript? {
        do {
            switch try await client.transcriptionJob(id) {
            case let .done(transcript): return transcript
            case .running: return try await client.awaitTranscription(id, for: poll)
            case let .failed(status, message): throw TranscriptionJob.Failed(status: status, message: message)
            }
        } catch is TranscriptionJob.Unreadable {
            // A proxy's page while the gateway restarts: the job, if it exists, is polled through it.
            do {
                return try await client.awaitTranscription(id, for: poll)
            } catch NuoError.notFound {
                return nil
            }
        } catch NuoError.notFound {
            // Never sent, expired, or lost by the gateway while it ran.
            return nil
        }
    }

    /// Voice went out on every stream and no line came back: treated as a failure, so the Mac transcribes it all.
    struct EmptyTranscript: Error {}

    private final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private var fraction = 0.0
        var value: Double { lock.withLock { fraction } }
        func set(_ value: Double) { lock.withLock { fraction = value } }
    }
}
