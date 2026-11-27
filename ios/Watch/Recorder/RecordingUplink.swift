import Foundation
import Observation
import WatchConnectivity

/// Where the watch keeps recordings and spoken requests until the iPhone has them.
enum WatchFiles {
    static var recordings: URL { folder("Recordings") }
    static var asks: URL { folder("Asks") }

    static func recording(_ id: String) -> URL {
        let url = recordings.appending(path: id, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func folder(_ name: String) -> URL {
        let url = URL.applicationSupportDirectory.appending(path: name, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save(_ value: some Encodable, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// Sends the recordings to the iPhone with WatchConnectivity's file transfers: the system queues them, keeps going
/// when the app is suspended and delivers them once the iPhone is in reach. A segment leaves the watch only when the
/// iPhone says it stored it; a transfer that failed or vanished is sent again.
@MainActor
@Observable
final class RecordingUplink {
    static let shared = RecordingUplink()

    private(set) var outbox: RecordingOutbox
    /// The iPhone is reachable right now (live messages); file transfers go anyway when it is not.
    private(set) var phoneReachable = false
    /// Recordings the iPhone acknowledged in full during this launch.
    private(set) var delivered: Set<String> = []

    @ObservationIgnored private var manifestsSent: [String: RecordingManifest] = [:]
    @ObservationIgnored private var manifestSentAt: [String: Date] = [:]
    @ObservationIgnored private var manifestWake: Task<Void, Never>?
    @ObservationIgnored private var wake: Task<Void, Never>?
    private static var outboxURL: URL { WatchFiles.recordings.appending(path: "outbox.json") }

    private init() {
        outbox = WatchFiles.load(RecordingOutbox.self, from: Self.outboxURL) ?? RecordingOutbox()
    }

    func enqueue(recordingId: String, index: Int, file: String) {
        outbox.enqueue(.init(recordingId: recordingId, index: index, file: file))
        persist()
        pump()
    }

    /// A manifest of a recording under way changes every 30 s: it leaves at most once a minute. The final one, at once.
    func update(_ manifest: RecordingManifest) {
        outbox.update(manifest)
        persist()
        if !manifest.isFinished, let last = manifestSentAt[manifest.id], Date().timeIntervalSince(last) < 60 {
            manifestWake?.cancel()
            manifestWake = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(1, 60 - Date().timeIntervalSince(last))))
                guard !Task.isCancelled else { return }
                self?.pump()
            }
            return
        }
        pump()
    }

    func pendingSegments(_ recordingId: String) -> Int { outbox.pending(recordingId: recordingId) }

    func isDelivered(_ recordingId: String) -> Bool {
        delivered.contains(recordingId) || (outbox.pending(recordingId: recordingId) == 0 && outbox.manifests[recordingId] == nil)
    }

    /// Hands every pending segment and changed manifest to the system's queue.
    func pump() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        phoneReachable = session.activationState == .activated && session.isReachable
        guard session.activationState == .activated else { return }
        let inFlight = Set(session.outstandingFileTransfers.compactMap { Self.item(from: $0.file.metadata) })
        for item in outbox.toSend(inFlight: inFlight) {
            let url = WatchFiles.recording(item.recordingId).appending(path: item.file)
            guard FileManager.default.fileExists(atPath: url.path) else {
                // Lost with a crash before it was closed: the iPhone is told, so it puts silence there instead of waiting.
                _ = outbox.acknowledge(recordingId: item.recordingId, indices: [item.index])
                session.transferUserInfo([RecordingLink.kind: RecordingLink.segmentLost, RecordingLink.recordingId: item.recordingId,
                                          RecordingLink.index: item.index])
                continue
            }
            session.transferFile(url, metadata: [
                RecordingLink.kind: RecordingLink.segment,
                RecordingLink.recordingId: item.recordingId,
                RecordingLink.index: item.index,
            ])
            // In flight from now until the system reports it, a relaunch included: a wake-up does not send it twice.
            outbox.markHandedOver(item)
        }
        for manifest in outbox.manifests.values where manifestsSent[manifest.id] != manifest {
            // A recording under way: its manifest leaves at most once a minute, whoever calls pump (update has a wake-up).
            if !manifest.isFinished, let last = manifestSentAt[manifest.id], Date().timeIntervalSince(last) < 60 { continue }
            guard let data = try? JSONEncoder().encode(manifest) else { continue }
            session.transferUserInfo([RecordingLink.kind: RecordingLink.manifest, RecordingLink.payload: data])
            manifestsSent[manifest.id] = manifest
            manifestSentAt[manifest.id] = Date()
        }
        persist()
        scheduleWake()
    }

    /// Back when the next piece waiting for a retry or for the iPhone's word is due.
    private func scheduleWake() {
        wake?.cancel()
        guard let due = outbox.nextDue() else { return }
        wake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, due.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.pump()
        }
    }

    // MARK: - From PhoneLink

    /// Delivered: the piece waits for the iPhone's word instead of going again at every pump. Failed: it goes
    /// again later and later.
    func transferFinished(metadata: [String: Any]?, failed: Bool) {
        guard let item = Self.item(from: metadata) else { return }
        if failed {
            outbox.markFailed(item)
        } else {
            outbox.markTransferred(item)
        }
        persist()
        scheduleWake()
    }

    func receive(_ info: [String: Any]) {
        guard let id = info[RecordingLink.recordingId] as? String else { return }
        switch info[RecordingLink.kind] as? String {
        case RecordingLink.segmentAck:
            let indices = info[RecordingLink.indices] as? [Int] ?? []
            for item in outbox.acknowledge(recordingId: id, indices: indices) {
                try? FileManager.default.removeItem(at: WatchFiles.recording(id).appending(path: item.file))
            }
        case RecordingLink.manifestAck:
            _ = outbox.acknowledgeManifest(id: id)
            manifestsSent[id] = nil
        default:
            return
        }
        if outbox.pending(recordingId: id) == 0, outbox.manifests[id] == nil {
            delivered.insert(id)
            VoiceRecorder.shared.transferred(id)
        }
        persist()
    }

    func reachabilityChanged(_ reachable: Bool) {
        phoneReachable = reachable
        if reachable { pump() }
    }

    private func persist() {
        WatchFiles.save(outbox, to: Self.outboxURL)
    }

    private static func item(from metadata: [String: Any]?) -> RecordingOutbox.Item? {
        guard let metadata, metadata[RecordingLink.kind] as? String == RecordingLink.segment,
              let id = metadata[RecordingLink.recordingId] as? String, let index = metadata[RecordingLink.index] as? Int
        else { return nil }
        return .init(recordingId: id, index: index, file: RecordingJournal.fileName(index: index))
    }
}
