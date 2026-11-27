import Foundation

/// The gateway's speech to text (`POST /api/transcriptions`): the app sends audio and gets text back, without knowing
/// which provider the gateway uses or holding its key.
extension NuoClient {
    struct TranscriptionService: Decodable, Sendable {
        let provider: String
        let model: String
    }

    /// Opens the connections to the gateway and from it to the provider while the user speaks. NotFound when the
    /// gateway has no provider configured. `timeout` makes it a quick check that the gateway answers at all.
    func warmTranscription(timeout: TimeInterval? = nil) async throws -> TranscriptionService {
        var request = try makeRequest("POST", "/api/transcriptions/warm", body: Optional<String>.none)
        if let timeout { request.timeoutInterval = timeout }
        let (data, _) = try await perform(request)
        return try decode(data)
    }

    /// The transcript of `form`'s audio, waiting for it. `background` suits a long recording: the gateway answers at
    /// once and is polled, so no proxy times the request out. `timeout` bounds the upload; `pollFor` (by default
    /// `timeout` too) bounds the wait for the job, which is left running on the gateway: `cancelTranscription` stops it.
    func transcribe(_ form: TranscriptionForm, background: Bool = false, timeout: TimeInterval, pollFor: TimeInterval? = nil) async throws -> CloudTranscript {
        var form = form
        form.background = background
        if background, form.jobID == nil { form.jobID = UUID().uuidString.lowercased() }
        var request = try makeRequest("POST", "/api/transcriptions", body: Optional<String>.none)
        request.httpBody = form.body
        request.timeoutInterval = timeout
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        // Read before the upload: a job sent again after a lost answer is found without being sent twice.
        if background, let id = form.jobID { request.setValue(id, forHTTPHeaderField: TranscriptionJob.header) }
        // A named job can be sent again safely; a dictation could be paid twice.
        let reply: Data, response: HTTPURLResponse
        do {
            (reply, response) = try await perform(request, replayable: background)
        } catch NuoError.offline where background {
            (reply, response) = try await perform(request, replayable: true)
        }
        guard background, response.statusCode == 202 else { return try decode(reply) }
        struct Started: Decodable { let id: String }
        let job: Started = try decode(reply)
        return try await awaitTranscription(job.id, for: pollFor ?? timeout)
    }

    /// Where a job sent earlier stands. NotFound when the gateway does not know it (never sent, or expired).
    func transcriptionJob(_ id: String) async throws -> TranscriptionJob.State {
        let (data, http) = try await perform(try makeRequest("GET", "/api/transcriptions/\(id)", body: Optional<String>.none))
        return try TranscriptionJob.state(status: http.statusCode, body: data)
    }

    /// Polls a job until it is done. Network errors and proxy pages are waited out, up to `TranscriptionJob.Unreachable`
    /// after two minutes without the gateway; the job's own error ends the wait as `TranscriptionJob.Failed` (whatever
    /// its status, 429 included), and so does the deadline. The job is
    /// left running on the gateway in every case: only a caller that wants it stopped calls `cancelTranscription`.
    func awaitTranscription(_ id: String, for duration: TimeInterval) async throws -> CloudTranscript {
        let deadline = Date().addingTimeInterval(duration)
        var silence = TranscriptionPolling.Silence()
        while Date() < deadline {
            try await Task.sleep(for: .seconds(2))
            let state: TranscriptionJob.State
            do {
                state = try await transcriptionJob(id)
                silence.answered()
            } catch let error as NuoError where TranscriptionPolling.isTransient(error.pollFailure) {
                // A dropped connection or the gateway restarting: the job goes on, ask again.
                if silence.unanswered(at: Date()) { throw TranscriptionJob.Unreachable() }
                continue
            } catch is TranscriptionJob.Unreadable {
                // A proxy's page while the gateway restarts.
                if silence.unanswered(at: Date()) { throw TranscriptionJob.Unreachable() }
                continue
            }
            switch state {
            case .running: continue
            case let .done(transcript): return transcript
            case let .failed(status, message): throw TranscriptionJob.Failed(status: status, message: message)
            }
        }
        throw NuoError.transport(String(localized: "The transcription took too long"))
    }

    /// Stops a job and deletes its audio on the gateway; quiet when it is already gone. False when the gateway did not
    /// hear it (away, offline), so the caller can send it again later.
    @discardableResult
    func cancelTranscription(_ id: String) async -> Bool {
        do {
            _ = try await perform(try makeRequest("DELETE", "/api/transcriptions/\(id)", body: Optional<String>.none))
            return true
        } catch NuoError.notFound {
            return true
        } catch {
            // Only a stop the gateway acted on, or a job it does not know, is done with.
            return false
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try NuoJSON.decoder().decode(T.self, from: data)
        } catch {
            throw NuoError.decoding(String(describing: error).prefix(160).description)
        }
    }
}

extension NuoError: TranscriptionPolling.Classified {
    var pollFailure: TranscriptionPolling.Failure {
        switch self {
        case .offline, .transport: .unreachable
        case .notFound: .unknownJob
        case let .server(status, message): .server(status: status, message: message)
        default: .other
        }
    }
}
