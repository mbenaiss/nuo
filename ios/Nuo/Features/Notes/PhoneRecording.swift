import Foundation

/// A recording made on the watch, as the iPhone follows it: pieces arriving, one transcription with the voices,
/// then the note written by a bot and saved in the docs' `reunions/` folder, where the Mac lists its meetings too.
struct PhoneRecording: Codable, Identifiable, Equatable {
    enum Stage: String, Codable {
        /// Still recording on the watch.
        case recording
        case transferring
        case transcribing
        case writing
        case ready
        case failed
    }

    var id: String
    var title: String
    var startedAt: Date
    var duration: TimeInterval
    var markers: [RecordingMarker]
    var template: MeetingTemplate
    var arrival = RecordingArrival()
    var stage: Stage = .transferring
    /// The gateway's transcription job: checked first after a relaunch, so the audio is not uploaded twice.
    var jobId: String?
    var lines: [RecordingLine]?
    var language: String?
    var note: String?
    var savedPath: String?
    var speakerNames: [String: String] = [:]
    var hasAudio = false
    var error: String?
    var interrupted = false
    /// The gateway went silent: the work goes on there and is picked up again later, nothing failed.
    var waitingGateway = false
    /// The failure comes from the network, not from the content: tried again on its own.
    var retryable = false
    /// Transcribed with the pieces that had arrived, the rest never came.
    var partial = false
    /// The pieces are put together in `audio.m4a`: any piece still arriving is a late copy.
    var assembled = false
    /// Bumped by each new transcription of the same recording, so its jobs get new ids.
    var generation = 0
    /// The parts of a long recording already transcribed, on the recording's clock.
    var doneParts: [Int: [RecordingLine]] = [:]
    /// The conversation where the note was asked: read again before asking twice.
    var noteConversationId: String?
    var noteAttempts = 0
    /// The iPhone is locked: its key cannot sign, everything waits for the unlock.
    var waitingUnlock = false
    /// Said once the audio is together: pieces that never came or could not be read became silence.
    var warning: String?
    var lastArrivalAt: Date?
    /// The note could not be saved in the docs.
    var saveError: String?
    /// The job each finished part was transcribed by, whatever the pass: all are dropped from the gateway at the end.
    var partJobs: [Int: String] = [:]
    /// Stretches filled with silence (pieces never come or unreadable), on the recording's clock.
    var silenceGaps: [[TimeInterval]] = []
    /// New tries after the provider refused a job for a moment (its own 429).
    var providerRetries = 0

    init(id: String, title: String, startedAt: Date, duration: TimeInterval, markers: [RecordingMarker], template: MeetingTemplate,
         stage: Stage = .transferring) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.duration = duration
        self.markers = markers
        self.template = template
        self.stage = stage
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? String(localized: "Recording")
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        markers = try c.decodeIfPresent([RecordingMarker].self, forKey: .markers) ?? []
        template = (try? c.decodeIfPresent(MeetingTemplate.self, forKey: .template)) ?? .general
        arrival = try c.decodeIfPresent(RecordingArrival.self, forKey: .arrival) ?? RecordingArrival()
        stage = (try? c.decodeIfPresent(Stage.self, forKey: .stage)) ?? .transferring
        jobId = try c.decodeIfPresent(String.self, forKey: .jobId)
        lines = try c.decodeIfPresent([RecordingLine].self, forKey: .lines)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        savedPath = try c.decodeIfPresent(String.self, forKey: .savedPath)
        speakerNames = try c.decodeIfPresent([String: String].self, forKey: .speakerNames) ?? [:]
        hasAudio = try c.decodeIfPresent(Bool.self, forKey: .hasAudio) ?? false
        error = try c.decodeIfPresent(String.self, forKey: .error)
        interrupted = try c.decodeIfPresent(Bool.self, forKey: .interrupted) ?? false
        waitingGateway = try c.decodeIfPresent(Bool.self, forKey: .waitingGateway) ?? false
        retryable = try c.decodeIfPresent(Bool.self, forKey: .retryable) ?? false
        partial = try c.decodeIfPresent(Bool.self, forKey: .partial) ?? false
        assembled = try c.decodeIfPresent(Bool.self, forKey: .assembled) ?? false
        generation = try c.decodeIfPresent(Int.self, forKey: .generation) ?? 0
        doneParts = try c.decodeIfPresent([Int: [RecordingLine]].self, forKey: .doneParts) ?? [:]
        noteConversationId = try c.decodeIfPresent(String.self, forKey: .noteConversationId)
        noteAttempts = try c.decodeIfPresent(Int.self, forKey: .noteAttempts) ?? 0
        waitingUnlock = try c.decodeIfPresent(Bool.self, forKey: .waitingUnlock) ?? false
        warning = try c.decodeIfPresent(String.self, forKey: .warning)
        lastArrivalAt = try c.decodeIfPresent(Date.self, forKey: .lastArrivalAt)
        saveError = try c.decodeIfPresent(String.self, forKey: .saveError)
        partJobs = try c.decodeIfPresent([Int: String].self, forKey: .partJobs) ?? [:]
        silenceGaps = try c.decodeIfPresent([[TimeInterval]].self, forKey: .silenceGaps) ?? []
        providerRetries = try c.decodeIfPresent(Int.self, forKey: .providerRetries) ?? 0
    }

    var gaps: [ClosedRange<TimeInterval>] {
        silenceGaps.compactMap { $0.count == 2 && $0[0] <= $0[1] ? $0[0]...$0[1] : nil }
    }

    var quotes: [MarkerQuote] { MarkerQuote.align(markers, to: lines ?? []) }
    var voiceCount: Int { Set((lines ?? []).compactMap(\.speaker)).count }
    /// A transfer stuck this long after the watch finished: what arrived can be transcribed already.
    static let stalledAfter: TimeInterval = 5 * 60

    /// The watch finished, some pieces came, the others have not for minutes: offered, never while recording.
    func canTranscribePartially(now: Date = Date()) -> Bool {
        guard stage == .transferring, arrival.manifest?.isFinished == true, !arrival.received.isEmpty, !arrival.isComplete else { return false }
        return now.timeIntervalSince(lastArrivalAt ?? .distantPast) >= Self.stalledAfter
    }

    /// Transcribed in part, and the missing pieces have come since: the whole can be transcribed again.
    var canTranscribeFully: Bool { partial && arrival.isComplete && stage != .transcribing }

    /// Ids of the gateway jobs of this recording: every part of the current pass, and those of earlier passes.
    var jobIds: [String] {
        let current = RecordingParts.plan(duration: duration).parts.map { RecordingParts.jobId(recordingId: id, part: $0.index, generation: generation) }
        return Array(Set(current).union(partJobs.values)).sorted()
    }

    var status: String {
        switch stage {
        case .recording: String(localized: "In progress on the watch")
        case .transferring:
            if let expected = arrival.expected { String(localized: "Transferring \(arrival.received.count)/\(expected)") } else { String(localized: "Transferring from the watch") }
        case .transcribing where waitingUnlock, .writing where waitingUnlock: String(localized: "Unlock your iPhone to continue")
        case .transcribing: waitingGateway ? String(localized: "Gateway unreachable, resuming automatically") : String(localized: "Transcribing…")
        case .writing: String(localized: "Writing summary…")
        case .ready: String(localized: "Ready")
        case .failed: error ?? String(localized: "Failed")
        }
    }
}

/// The list of recordings on disk, read one entry at a time: an entry that no longer decodes is left out and kept
/// aside, never the whole list.
enum PhoneRecordingIndex {
    private struct Lossy: Decodable {
        let recording: PhoneRecording?
        init(from decoder: any Decoder) throws {
            recording = try? PhoneRecording(from: decoder)
        }
    }

    static func decode(_ data: Data, decoder: JSONDecoder) -> (recordings: [PhoneRecording], dropped: Int)? {
        guard let entries = try? decoder.decode([Lossy].self, from: data) else { return nil }
        let recordings = entries.compactMap(\.recording)
        return (recordings, entries.count - recordings.count)
    }
}

/// Stops of gateway jobs the gateway did not hear (it was away), kept to be sent again when it answers. The same
/// rule as the Mac's `MeetingPendingDeletes`, which lives with the Mac's meeting code.
struct PendingJobStops: Codable, Equatable {
    private(set) var ids: [String] = []
    static let limit = 200

    mutating func add(_ new: [String]) {
        for id in new where !ids.contains(id) { ids.append(id) }
        if ids.count > Self.limit { ids.removeFirst(ids.count - Self.limit) }
    }

    mutating func done(_ id: String) {
        ids.removeAll { $0 == id }
    }
}
