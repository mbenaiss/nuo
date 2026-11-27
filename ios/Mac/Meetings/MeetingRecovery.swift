import Foundation

/// The meeting kept on disk (text only) until the next one starts or it is discarded. While it is still being
/// recorded or transcribed, `resume` says where its audio is and how far it was transcribed, so a quit or a crash
/// does not lose it.
struct MeetingArchive: Codable {
    var title: String
    var participants: String
    var notes: String
    var eventId: String?
    var startedAt: Date
    var endedAt: Date
    var transcript: MeetingTranscript
    var note: String?
    var savedPath: String?
    var resume: MeetingResume?
    /// The transcript came from the gateway's service, as « en ligne » says next to it.
    var transcribedInCloud: Bool? = nil
}

extension MeetingArchive {
    /// How often a meeting being recorded is saved for a crash.
    static let saveEvery: TimeInterval = 30

    static func saveIsDue(last: Date, now: Date) -> Bool { now.timeIntervalSince(last) >= saveEvery }

    /// The meeting under way, or recorded and not transcribed yet, as it stands at `now`: still recording, it ends now.
    static func inProgress(title: String, participants: String, notes: String, eventId: String?, startedAt: Date, endedAt: Date?, now: Date,
                           transcript: MeetingTranscript, resume: MeetingResume) -> MeetingArchive {
        MeetingArchive(title: title, participants: participants, notes: notes, eventId: eventId, startedAt: startedAt, endedAt: endedAt ?? now,
                       transcript: transcript, note: nil, savedPath: nil, resume: resume)
    }
}

/// The recording of a meeting whose transcription did not end, and how far each stream had been transcribed.
struct MeetingResume: Codable, Equatable, Sendable {
    struct Stream: Codable, Equatable, Sendable {
        var speaker: MeetingSpeaker
        /// File name inside the meetings audio directory.
        var file: String
        var startOffset: TimeInterval?
        /// Samples already transcribed.
        var cursor: Int
        /// The stream's job on the gateway, once it was named: a resume asks for it before sending the audio again.
        var jobID: String?
    }

    var engine: MeetingEngine
    var streams: [Stream]

    /// The streams whose file is still there; none means there is nothing left to transcribe from.
    func available(in directory: URL, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> [Stream] {
        streams.filter { exists(directory.appending(path: $0.file)) }
    }

    /// Files of the audio directory that belong to no meeting to resume: left by a meeting that was discarded.
    static func orphans(_ files: [String], keeping resume: MeetingResume?) -> [String] {
        let kept = Set(resume?.streams.map(\.file) ?? [])
        return files.filter { !kept.contains($0) }
    }
}

extension MeetingEngine: Codable {}

/// Stops of gateway jobs the gateway did not hear (it was away), kept on disk to be sent again when it answers.
struct MeetingPendingDeletes: Codable, Equatable {
    private(set) var ids: [String] = []
    /// Enough for many meetings' streams; the oldest go first, a job is gone from the gateway within a day anyway.
    static let limit = 200

    mutating func add(_ new: [String]) {
        for id in new where !ids.contains(id) { ids.append(id) }
        if ids.count > Self.limit { ids.removeFirst(ids.count - Self.limit) }
    }

    mutating func done(_ id: String) {
        ids.removeAll { $0 == id }
    }
}

/// Why quitting now would lose part of the meeting; nil when nothing would be.
enum MeetingQuitReason {
    static func reason(recording: Bool, finalizing: Bool) -> String? {
        if recording { return String(localized: "A meeting is being recorded") }
        if finalizing { return String(localized: "The meeting transcript isn't finished") }
        return nil
    }
}

/// How long one chunk may take before its transcription is given up.
enum MeetingDeadline {
    struct TimedOut: LocalizedError {
        var errorDescription: String? { String(localized: "Transcribing a segment is taking too long.") }
    }

    /// A minute of margin, then four times the audio: Whisper on the GPU of an M1 runs at about a third of real time.
    static func seconds(forSamples count: Int, rate: Int) -> TimeInterval {
        60 + 4 * Double(count) / Double(max(rate, 1))
    }

    /// `work`'s result, or `TimedOut` once `seconds` pass. A late `work` is cancelled and left to end on its own: an
    /// engine stuck in a system service cannot be interrupted.
    static func run<T: Sendable>(seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let once = Once()
        let task = Task { try await work() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                Task {
                    let result = await task.result
                    if once.claim() { continuation.resume(with: result) }
                }
                Task {
                    try? await Task.sleep(for: .seconds(seconds))
                    if once.claim() {
                        task.cancel()
                        continuation.resume(throwing: TimedOut())
                    }
                }
            }
        } onCancel: {
            task.cancel()
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        func claim() -> Bool {
            lock.withLock {
                defer { done = true }
                return !done
            }
        }
    }
}

/// Keeps a stream's samples on the meeting's clock: a device switch stops the capture for a moment, and without the
/// missing time the following speech would be dated too early and the two speakers would drift apart.
enum MeetingTimeline {
    /// Samples of silence to write before a buffer of `incoming` samples arriving when the stream should hold
    /// `expectedEnd`, given `written` so far. Jitter under `tolerance` is left alone.
    static func silence(written: Int, expectedEnd: Int, incoming: Int, tolerance: Int) -> Int {
        let gap = expectedEnd - incoming - written
        return gap > tolerance ? gap : 0
    }
}

/// Picks the system audio among the buffers of the private aggregate device: its output sub-device may bring its own
/// input streams (the mic of a USB or Bluetooth headset), listed before the tap's.
enum MeetingTapBuffer {
    /// The buffers holding the tap, given the channel count of each buffer the aggregate delivers.
    static func range(channels: [UInt32], expected: UInt32, interleaved: Bool) -> Range<Int>? {
        guard !channels.isEmpty else { return nil }
        if expected <= 1 || interleaved {
            let index = channels.lastIndex(of: max(expected, 1)) ?? channels.count - 1
            return index..<index + 1
        }
        let count = Int(expected)
        guard channels.count >= count, channels.suffix(count).allSatisfy({ $0 == 1 }) else { return nil }
        return channels.count - count..<channels.count
    }
}
