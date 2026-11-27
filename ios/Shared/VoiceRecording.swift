import Foundation

/// A moment flagged on the watch while recording, in seconds of audio since the start.
struct RecordingMarker: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var offset: TimeInterval

    init(id: String = UUID().uuidString.lowercased(), offset: TimeInterval) {
        self.id = id
        self.offset = offset
    }
}

/// What the watch tells the iPhone about a recording, sent again at every change (start, stop, recovery).
struct RecordingManifest: Codable, Hashable, Sendable {
    /// Lowercase UUID: also names the gateway's transcription job, so sending it twice is never paid twice.
    var id: String
    var startedAt: Date
    var duration: TimeInterval
    var markers: [RecordingMarker]
    /// Segments written so far; the full count once `isFinished`.
    var segmentCount: Int
    var isFinished: Bool
    /// Ended by a crash or a restart of the watch: the last seconds may be missing.
    var interrupted: Bool = false
    /// Seconds of each piece, in order: a piece that never arrives becomes silence of exactly its length.
    var segmentDurations: [TimeInterval]?
}

/// Keys of the WatchConnectivity payloads of recordings and voice requests (the conversation keys are in `WatchLink`).
enum RecordingLink {
    static let kind = "kind"
    static let segment = "recording.segment"
    static let manifest = "recording.manifest"
    static let segmentAck = "recording.ack"
    /// A piece the watch lost: the iPhone stops waiting for it.
    static let segmentLost = "recording.lost"
    static let reason = "reason"
    static let manifestAck = "recording.manifestAck"
    static let recordingId = "recordingId"
    static let index = "index"
    static let indices = "indices"
    static let payload = "payload"

    static let ask = "ask"
    static let askAck = "ask.ack"
    static let askId = "askId"
    static let botId = "botId"
    static let conversationId = "conversationId"
    static let seconds = "seconds"
    static let audio = "audio"
    static let text = "text"
    static let createdAt = "createdAt"
    static let preferredBotId = "preferredBotId"
    static let request = "request"
    static let ok = "ok"
    static let error = "error"
    static let queued = "queued"
    static let locked = "locked"

    /// Live events of a turn the iPhone runs for the watch.
    static let turn = "turn"
    static let event = "event"
    static let requestId = "requestId"
    static let title = "title"
    static let options = "options"
    static let optionId = "optionId"
    static let permissionAnswer = "permissionAnswer"
}

/// The recording on the watch, saved after every change so a crash or a restart loses at most the segment being
/// written. Audio is cut into short AAC files: a closed one is complete on disk and can leave at once.
struct RecordingJournal: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case recording, paused, finished }

    struct Segment: Codable, Equatable, Sendable {
        var index: Int
        var file: String
        var duration: TimeInterval
        var closed: Bool
    }

    /// Seconds of audio per file: what a crash can lose at most.
    static let segmentSeconds: TimeInterval = 30
    /// The first file holds the whole minute during which the capture may still be a request, so a request is one file.
    static let firstSegmentSeconds: TimeInterval = 60

    static func seconds(ofSegment index: Int) -> TimeInterval { index == 0 ? firstSegmentSeconds : segmentSeconds }
    /// Two taps closer than this are one marker (a double tap felt twice, a nervous finger).
    static let markerDebounce: TimeInterval = 1.5

    var id: String
    var startedAt: Date
    var status: Status = .recording
    private(set) var segments: [Segment] = []
    private(set) var markers: [RecordingMarker] = []
    private(set) var interrupted = false

    init(id: String = UUID().uuidString.lowercased(), startedAt: Date) {
        self.id = id
        self.startedAt = startedAt
    }

    /// Seconds of audio in the closed segments.
    var closedDuration: TimeInterval { segments.filter(\.closed).reduce(0) { $0 + $1.duration } }
    var duration: TimeInterval { segments.reduce(0) { $0 + $1.duration } }
    var openSegment: Segment? { segments.last.flatMap { $0.closed ? nil : $0 } }
    var closedSegments: [Segment] { segments.filter(\.closed) }

    static func fileName(index: Int) -> String { String(format: "segment-%04d.m4a", index) }

    @discardableResult
    mutating func openNextSegment() -> Segment {
        if openSegment != nil { closeSegment(duration: openSegment?.duration ?? 0) }
        let segment = Segment(index: segments.count, file: Self.fileName(index: segments.count), duration: 0, closed: false)
        segments.append(segment)
        return segment
    }

    /// Keeps the open segment's length current, so a crash knows how much audio it held.
    mutating func updateOpenSegment(duration: TimeInterval) {
        guard let last = segments.indices.last, !segments[last].closed else { return }
        segments[last].duration = duration
    }

    mutating func closeSegment(duration: TimeInterval) {
        guard let last = segments.indices.last, !segments[last].closed else { return }
        segments[last].duration = duration
        segments[last].closed = true
        // An empty file (stopped right after a rotation) is not worth sending.
        if duration < 0.05 { segments.removeLast() }
    }

    /// The marker added at `elapsed`, or nil when it repeats the previous one.
    mutating func mark(at elapsed: TimeInterval) -> RecordingMarker? {
        let offset = max(0, elapsed)
        if let last = markers.last, offset - last.offset < Self.markerDebounce { return nil }
        let marker = RecordingMarker(offset: offset)
        markers.append(marker)
        return marker
    }

    mutating func finish(openDuration: TimeInterval) {
        closeSegment(duration: openDuration)
        status = .finished
    }

    /// A journal found at launch while it still says it records: the app crashed or the watch restarted. The open
    /// segment is kept when its file can still be read (with the length read from it), dropped otherwise, and markers
    /// past the end of the audio are moved onto it.
    func recovered(readableDuration: (Segment) -> TimeInterval?) -> RecordingJournal {
        var journal = self
        guard journal.status != .finished else { return journal }
        if let open = journal.openSegment {
            journal.segments.removeLast()
            if let seconds = readableDuration(open), seconds > 0.05 {
                journal.segments.append(Segment(index: open.index, file: open.file, duration: seconds, closed: true))
            }
        }
        let end = journal.duration
        journal.markers = journal.markers.map { RecordingMarker(id: $0.id, offset: min($0.offset, end)) }
        journal.status = .finished
        journal.interrupted = true
        return journal
    }

    var manifest: RecordingManifest {
        RecordingManifest(id: id, startedAt: startedAt, duration: duration, markers: markers, segmentCount: closedSegments.count,
                          isFinished: status == .finished, interrupted: interrupted, segmentDurations: closedSegments.map(\.duration))
    }
}

/// The segments and manifests the watch still has to get to the iPhone. A segment stays here, and on disk, until the
/// iPhone says it stored it. A transfer the system reports as delivered waits a while for that word before going
/// again; one that failed goes again later and later, up to a ceiling.
struct RecordingOutbox: Codable, Equatable, Sendable {
    struct Item: Codable, Hashable, Sendable {
        var recordingId: String
        var index: Int
        var file: String

        var key: String { "\(recordingId)#\(index)" }
    }

    struct Attempt: Codable, Equatable, Sendable {
        var failures = 0
        var notBefore: Date?
        /// Handed to the system's queue at this time: in flight until the system reports it, even across a relaunch.
        var handedAt: Date?
        /// Delivered by the system at this time, not yet acknowledged by the iPhone.
        var transferredAt: Date?
    }

    /// How long a delivered piece waits for the iPhone's word before it is sent again.
    static let ackWait: TimeInterval = 10 * 60
    static let maxBackoff: TimeInterval = 15 * 60

    /// 20 s, 40 s, 80 s… after each failure in a row, never more than a quarter of an hour.
    static func backoff(failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        return min(maxBackoff, 20 * pow(2, Double(min(failures, 16) - 1)))
    }

    private(set) var items: [Item] = []
    /// The latest manifest of each recording, until the iPhone acknowledges a finished one.
    private(set) var manifests: [String: RecordingManifest] = [:]
    private(set) var attempts: [String: Attempt] = [:]

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([Item].self, forKey: .items) ?? []
        manifests = try container.decodeIfPresent([String: RecordingManifest].self, forKey: .manifests) ?? [:]
        attempts = try container.decodeIfPresent([String: Attempt].self, forKey: .attempts) ?? [:]
    }

    var isEmpty: Bool { items.isEmpty && manifests.isEmpty }

    mutating func enqueue(_ item: Item) {
        guard !items.contains(item) else { return }
        items.append(item)
    }

    mutating func update(_ manifest: RecordingManifest) {
        manifests[manifest.id] = manifest
    }

    /// The items to (re)send now: not stored by the iPhone, not on their way, not waiting for a word or a retry.
    func toSend(inFlight: Set<Item>, now: Date = Date()) -> [Item] {
        items.filter { item in
            guard !inFlight.contains(item) else { return false }
            guard let attempt = attempts[item.key] else { return true }
            if let notBefore = attempt.notBefore, notBefore > now { return false }
            if let handedAt = attempt.handedAt, now.timeIntervalSince(handedAt) < Self.ackWait { return false }
            if let transferredAt = attempt.transferredAt, now.timeIntervalSince(transferredAt) < Self.ackWait { return false }
            return true
        }
    }

    mutating func markHandedOver(_ item: Item, at now: Date = Date()) {
        guard items.contains(item) else { return }
        attempts[item.key, default: Attempt()].handedAt = now
    }

    mutating func markTransferred(_ item: Item, at now: Date = Date()) {
        guard items.contains(item) else { return }
        attempts[item.key, default: Attempt()].transferredAt = now
        attempts[item.key]?.handedAt = nil
        attempts[item.key]?.failures = 0
        attempts[item.key]?.notBefore = nil
    }

    mutating func markFailed(_ item: Item, at now: Date = Date()) {
        guard items.contains(item) else { return }
        var attempt = attempts[item.key] ?? Attempt()
        attempt.failures += 1
        attempt.transferredAt = nil
        attempt.handedAt = nil
        attempt.notBefore = now.addingTimeInterval(Self.backoff(failures: attempt.failures))
        attempts[item.key] = attempt
    }

    /// When the next piece waiting for a retry or a word becomes due, to wake up then.
    func nextDue(now: Date = Date()) -> Date? {
        items.compactMap { item -> Date? in
            guard let attempt = attempts[item.key] else { return nil }
            let dates = [attempt.notBefore, attempt.handedAt.map { $0.addingTimeInterval(Self.ackWait) },
                         attempt.transferredAt.map { $0.addingTimeInterval(Self.ackWait) }].compactMap { $0 }
            return dates.max().flatMap { $0 > now ? $0 : nil }
        }.min()
    }

    /// Removes what the iPhone stored; returns it so its files can go.
    mutating func acknowledge(recordingId: String, indices: [Int]) -> [Item] {
        let done = items.filter { $0.recordingId == recordingId && indices.contains($0.index) }
        items.removeAll { done.contains($0) }
        for item in done { attempts[item.key] = nil }
        return done
    }

    /// The iPhone has the whole recording: true when nothing of it is left to send, so its folder can go.
    mutating func acknowledgeManifest(id: String) -> Bool {
        guard manifests[id]?.isFinished == true else { return false }
        manifests[id] = nil
        return !items.contains { $0.recordingId == id }
    }

    func pending(recordingId: String) -> Int { items.filter { $0.recordingId == recordingId }.count }
}

/// The watch's room for recordings: they wait there until the iPhone has them.
enum StorageBudget {
    enum State: Equatable { case ok, nearlyFull, full }

    /// Most the recordings may take on the watch.
    static let cap: Int64 = 1_000_000_000
    /// Space the watch keeps for itself.
    static let reserve: Int64 = 200_000_000

    static func state(used: Int64, free: Int64?) -> State {
        if used >= cap { return .full }
        if let free, free <= reserve { return .full }
        if used >= cap * 8 / 10 { return .nearlyFull }
        if let free, free <= reserve * 2 { return .nearlyFull }
        return .ok
    }
}

/// What the iPhone holds of a recording sent by the watch.
struct RecordingArrival: Codable, Equatable, Sendable {
    var manifest: RecordingManifest?
    private(set) var received: Set<Int> = []
    /// Pieces the watch says it lost (a crash before they were closed): never coming, silence in their place.
    private(set) var lost: Set<Int> = []

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        manifest = try container.decodeIfPresent(RecordingManifest.self, forKey: .manifest)
        received = try container.decodeIfPresent(Set<Int>.self, forKey: .received) ?? []
        lost = try container.decodeIfPresent(Set<Int>.self, forKey: .lost) ?? []
    }

    mutating func receive(index: Int) {
        received.insert(index)
        lost.remove(index)
    }

    mutating func markLost(index: Int) {
        guard !received.contains(index) else { return }
        lost.insert(index)
    }

    var expected: Int? { manifest.flatMap { $0.isFinished ? $0.segmentCount : nil } }

    /// Segments announced by the manifest that are neither here nor known to be lost.
    var missing: [Int] {
        guard let manifest else { return [] }
        return (0..<manifest.segmentCount).filter { !received.contains($0) && !lost.contains($0) }
    }

    var isComplete: Bool {
        guard let expected else { return false }
        return expected > 0 && missing.isEmpty && !received.isEmpty
    }

    /// The length of a piece on the watch's clock: from the manifest, else the standard length (the last one gets the rest).
    func seconds(of index: Int, total: TimeInterval) -> TimeInterval {
        if let durations = manifest?.segmentDurations, index < durations.count { return durations[index] }
        let count = max(1, expected ?? received.count)
        return index == count - 1 ? max(0.1, total - RecordingJournal.segmentSeconds * Double(count - 1)) : RecordingJournal.segmentSeconds
    }
}
