import Foundation

/// What transcribes a recording, in the order they are tried.
enum TranscriptionEngine: String, Sendable {
    /// The gateway's speech-to-text service: the most accurate, needs the network.
    case cloud
    /// Whisper on the device, once its model is downloaded.
    case whisper
    /// Apple's recognizer on the device, always there.
    case apple

    /// The cloud first unless it is off, known to be missing, or the device is offline; Whisper when its model is on
    /// the device, except in the background where the GPU is off limits; Apple's recognizer last.
    static func order(cloudEnabled: Bool, cloudAvailable: Bool?, whisperReady: Bool, inBackground: Bool) -> [TranscriptionEngine] {
        var engines: [TranscriptionEngine] = []
        if cloudEnabled, cloudAvailable != false { engines.append(.cloud) }
        if whisperReady, !inBackground { engines.append(.whisper) }
        engines.append(.apple)
        return engines
    }
}

/// The gateway's answer to `POST /api/transcriptions`, whichever provider wrote it.
struct CloudTranscript: Decodable, Sendable, Equatable {
    struct Segment: Decodable, Sendable, Equatable {
        var start: Double
        var end: Double
        var text: String
        /// "1", "2"… in order of first appearance, when speakers were asked for.
        var speaker: String?
    }

    var text: String
    var language: String?
    var segments: [Segment]?
    var provider: String?
    var model: String?
    /// Time the provider took, in milliseconds.
    var ms: Int?
}

/// The multipart body of `POST /api/transcriptions`: the audio and how to read it.
struct TranscriptionForm: Sendable {
    var audio: Data
    var filename = "audio.m4a"
    var mimeType = "audio/mp4"
    /// ISO 639-1; nil lets the service detect it.
    var language: String?
    /// Other languages that may come up, such as English technical terms in French speech.
    var otherLanguages: [String] = []
    var keyterms: [String] = []
    var segments = false
    var speakers = false
    /// Most speakers to tell apart, when the attendees are known.
    var maxSpeakers: Int?
    var seconds: Double
    var background = false
    /// Names a background job, so sending it again after a lost answer finds it on the gateway.
    var jobID: String?
    /// Seconds into the audio where it was cut and joined (silences removed): no segment runs across them.
    var breaks: [Double] = []

    let boundary: String

    init(audio: Data, filename: String = "audio.m4a", language: String?, otherLanguages: [String] = [], keyterms: [String] = [],
         segments: Bool = false, speakers: Bool = false, maxSpeakers: Int? = nil, seconds: Double,
         boundary: String = "nuo-\(UUID().uuidString)") {
        self.audio = audio
        self.filename = filename
        self.language = language
        self.otherLanguages = otherLanguages
        self.keyterms = keyterms
        self.segments = segments
        self.speakers = speakers
        self.maxSpeakers = maxSpeakers
        self.seconds = seconds
        self.boundary = boundary
    }

    /// French first with English terms understood, or the other way round. Without a language, a dictation is French
    /// first; a meeting (`autoDetects`) leaves the service to recognize it.
    static func languages(_ code: String?, autoDetects: Bool = false) -> (language: String?, others: [String]) {
        if code == nil, autoDetects { return (nil, []) }
        return code == "en" ? ("en", ["fr"]) : (code ?? "fr", code == nil || code == "fr" ? ["en"] : [])
    }

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    var body: Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        if let language { field("language", language) }
        if !otherLanguages.isEmpty { field("otherLanguages", otherLanguages.joined(separator: ",")) }
        if !keyterms.isEmpty, let data = try? JSONSerialization.data(withJSONObject: keyterms), let json = String(data: data, encoding: .utf8) {
            field("keyterms", json)
        }
        if segments { field("segments", "true") }
        if speakers { field("speakers", "true") }
        if speakers, let maxSpeakers { field("maxSpeakers", String(maxSpeakers)) }
        if background { field("background", "true") }
        if let jobID { field("id", jobID) }
        if !breaks.isEmpty, let data = try? JSONSerialization.data(withJSONObject: breaks), let json = String(data: data, encoding: .utf8) {
            field("breaks", json)
        }
        field("seconds", String(format: "%.1f", seconds))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
}

/// The first of some work and a timeout. Returns on time even when the work waits on something it cannot cancel (a
/// token refresh shared with other requests), and at once when the caller is cancelled: the work is left to end on its
/// own.
enum Deadline {
    static func first<T: Sendable>(within timeout: Duration, otherwise fallback: T, _ work: @escaping @Sendable () async -> T) async -> T {
        let pending = Pending<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pending.hold(continuation)
                Task { pending.resume(await work()) }
                Task {
                    try? await Task.sleep(for: timeout)
                    pending.resume(fallback)
                }
                if Task.isCancelled { pending.resume(fallback) }
            }
        } onCancel: {
            pending.resume(fallback)
        }
    }

    private final class Pending<T: Sendable>: @unchecked Sendable {
        private let once = ResumeOnce()
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Never>?

        func hold(_ continuation: CheckedContinuation<T, Never>) { lock.withLock { self.continuation = continuation } }

        /// The first value wins; a cancellation before the continuation is held is caught by the caller's own check.
        func resume(_ value: T) {
            guard let continuation = lock.withLock({ self.continuation }), once.claim() else { return }
            continuation.resume(returning: value)
        }
    }
}

/// True once, for whoever asks first: a continuation raced by several tasks is resumed exactly once.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}

/// A background transcription on the gateway (`GET /api/transcriptions/:id`).
enum TranscriptionJob {
    /// Names the job before its upload is read, so a job sent again is found without paying for it twice.
    static let header = "x-nuo-transcription-id"

    enum State: Equatable, Sendable {
        case running
        case done(CloudTranscript)
        /// The job's own error, as the provider gave it.
        case failed(status: Int, message: String)
    }

    struct Unreadable: Error {}

    /// The gateway stopped answering while the job ran: the job may still finish there.
    struct Unreachable: Error {}

    /// The job itself failed on the gateway (the provider refused it, whatever its status, 429 included): it is
    /// stopped and named anew for the next try, never polled again.
    struct Failed: Error, Equatable {
        let status: Int
        let message: String
    }

    /// A failed job is a 200 too, with its error: no proxy can pass for it.
    static func state(status: Int, body: Data) throws -> State {
        if status == 202 { return .running }
        struct Header: Decodable {
            struct Failure: Decodable { let status: Int; let message: String }
            let status: String?
            let error: Failure?
        }
        guard let header = try? JSONDecoder().decode(Header.self, from: body) else { throw Unreadable() }
        switch header.status {
        case "running": return .running
        case "failed": return .failed(status: header.error?.status ?? 502, message: header.error?.message ?? "")
        default:
            guard let transcript = try? JSONDecoder().decode(CloudTranscript.self, from: body) else { throw Unreadable() }
            return .done(transcript)
        }
    }
}

/// Whether polling a background transcription should go on after a failed request.
enum TranscriptionPolling {
    /// How long the gateway may stay silent before the Mac stops waiting for it.
    struct Silence {
        var limit: TimeInterval = 120
        private(set) var since: Date?

        mutating func answered() { since = nil }

        /// True once the gateway has not answered for `limit` in a row.
        mutating func unanswered(at now: Date) -> Bool {
            let start = since ?? now
            since = start
            return now.timeIntervalSince(start) >= limit
        }
    }

    enum Failure: Equatable {
        /// No answer: offline, a timeout, a dropped connection.
        case unreachable
        /// The gateway no longer knows the job (restarted, or the result expired).
        case unknownJob
        case server(status: Int, message: String)
        case other
    }

    /// An error from a request to the gateway, seen as a polling failure.
    protocol Classified {
        var pollFailure: Failure { get }
    }

    /// Whether the cloud's side of a meeting goes on (the gateway is away, or busy for a moment) after `error`, rather
    /// than having failed. A job's own failure (`TranscriptionJob.Failed`) never does, even a 429 from the provider.
    static func keepsRacing(_ error: Error) -> Bool {
        if error is TranscriptionJob.Unreachable || error is TranscriptionJob.Unreadable { return true }
        guard let failure = (error as? Classified)?.pollFailure else { return false }
        return isTransient(failure) || isBusy(failure)
    }

    /// The gateway turned a named job away for a moment (429: its device already has three under way, a retry racing the
    /// first send): sending it again later finds it, so this is no failure of the job.
    static func isBusy(_ failure: Failure) -> Bool {
        if case .server(429, _) = failure { return true }
        return false
    }

    /// Only the job's own error (the gateway's message about the provider) or a forgotten job ends the wait; a proxy
    /// answering for a gateway that restarts says nothing.
    static func isTransient(_ failure: Failure) -> Bool {
        switch failure {
        case .unreachable: true
        case .unknownJob, .other: false
        case let .server(status, message): status >= 500 && message.isEmpty
        }
    }
}

/// Names to spell right, once each, in the order given.
enum DictationTerms {
    static func unique(_ candidates: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for term in candidates {
            let clean = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, clean.count <= 40, seen.insert(clean.lowercased()).inserted else { continue }
            terms.append(clean)
            if terms.count == limit { break }
        }
        return terms
    }
}

/// How long to wait for a transcription before trying the device: the upload and the provider's own time, never less
/// than a quarter of a minute.
enum TranscriptionDeadline {
    static func seconds(forAudio seconds: Double, bytes: Int) -> Double {
        // 1 Mbit/s up at worst, and a provider many times faster than real time.
        let upload = Double(bytes) * 8 / 1_000_000
        return min(30 * 60, 15 + upload + seconds * 0.15)
    }
}
