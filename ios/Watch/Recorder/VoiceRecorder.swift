@preconcurrency import AVFoundation
import Foundation
import Observation
import UserNotifications
import WatchKit

/// The watch's one capture: under a minute it is a request to the general bot, handed to `AskCenter` when it stops;
/// past the minute it goes on, without a gap, as a meeting or a conversation recorded on the watch, cut into AAC files
/// (the first minute, then 30 s each) that leave for the iPhone as soon as each one closes. A journal on disk keeps
/// the recording through a crash or a restart.
@MainActor
@Observable
final class VoiceRecorder {
    static let shared = VoiceRecorder()

    enum Phase: Equatable {
        case idle, starting, recording
        /// The microphone stopped (a call, Siri, the audio services): watchOS lets it start again only from the screen.
        case interrupted
        case finished
    }

    private(set) var phase: Phase = .idle
    private(set) var journal: RecordingJournal?
    private(set) var level: Float = 0
    private(set) var openSeconds: TimeInterval = 0
    private(set) var error: String?
    /// Shown on the recording screen without stopping it: a file that could not be written, the watch filling up.
    private(set) var warning: String?
    /// Bumped by every marker, for the flash on screen.
    private(set) var markerPulse = 0
    /// The recordings made on this watch, newest first, while they are being sent.
    private(set) var history: [RecordingManifest] = []
    /// Under a minute: the capture may still be a request, and the iPhone knows nothing of it yet.
    private(set) var isTentative = false
    /// Where the answer to a capture sent as a request lands, for the screen to open it.
    private(set) var answer: AskCenter.Delivery?
    /// Asked by a complication, a control or Siri: the app shows the capture and starts.
    var startRequested = false

    @ObservationIgnored private let mic = WatchMic(owner: "recorder")
    @ObservationIgnored private var writer: AACWriter?
    @ObservationIgnored private var lastSave = Date.distantPast
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var recovered = false
    @ObservationIgnored private var storageState: StorageBudget.State = .ok
    @ObservationIgnored private var storageCheckedAt = Date.distantPast
    @ObservationIgnored private var demo: Task<Void, Never>?
    @ObservationIgnored private var sending = false
    @ObservationIgnored private(set) var isDemo = ProcessInfo.processInfo.arguments.contains("-demo")

    private static var historyURL: URL { WatchFiles.recordings.appending(path: "history.json") }
    private static func samplesPerSegment(_ index: Int) -> Int { Int(RecordingJournal.seconds(ofSegment: index) * WatchMic.sampleRate) }
    /// No sample for this long while recording: the microphone stopped without saying so.
    private static let silenceLimit: TimeInterval = 4
    private static let pausedReminder = AppIdentity.local(.recordingPausedNotification)

    private init() {
        history = WatchFiles.load([RecordingManifest].self, from: Self.historyURL) ?? []
        mic.onSamples = { [weak self] samples, level in self?.consume(samples, level: level) }
        mic.onInterruption = { [weak self] began in self?.interruption(began: began) }
    }

    var elapsed: TimeInterval { (journal?.closedDuration ?? 0) + openSeconds }
    var markerCount: Int { journal?.markers.count ?? 0 }
    var isActive: Bool { [.starting, .recording, .interrupted].contains(phase) }

    // MARK: - Recording

    func start() async {
        guard !isActive else { return }
        // A start asked while the last recording's summary is still on screen begins a new one.
        if phase == .finished { dismiss() }
        error = nil
        warning = nil
        answer = nil
        if isDemo {
            playDemoListening(seconds: 0)
            return
        }
        // What a crash left is sent before anything new is recorded.
        recoverAtLaunch()
        phase = .starting
        await refreshStorage()
        if storageState == .full {
            fail(message: String(localized: "The watch is full: bring the iPhone closer so it can collect the pending recordings."))
            return
        }
        guard await WatchMic.allowed() else {
            fail(message: WatchMic.Failure.denied.localizedDescription)
            return
        }
        guard !AskCenter.shared.isListening else {
            fail(message: String(localized: "Finish your request to Nuo first."))
            return
        }
        var journal = RecordingJournal(startedAt: Date())
        let segment = journal.openNextSegment()
        do {
            writer = try AACWriter(url: WatchFiles.recording(journal.id).appending(path: segment.file),
                                   bitRate: CaptureRule.bitRate(ofSegment: segment.index))
            self.journal = journal
            openSeconds = 0
            try mic.start()
        } catch {
            writer = nil
            self.journal = nil
            fail(message: error.localizedDescription)
            return
        }
        isTentative = true
        phase = .recording
        startWatchdog()
        // Saved from the first second: a crash keeps what was said, as a recording.
        save()
        WKInterfaceDevice.current().play(.start)
    }

    /// The minute is up: the capture is a recording from here, its first minute included, with no gap in the audio.
    private func becomeRecording() {
        guard let journal else { return }
        isTentative = false
        RecordingUplink.shared.update(journal.manifest)
        rotate()
        WKInterfaceDevice.current().play(.directionUp)
        // The reminder of a pause comes as a notification: the app may be in the background then.
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    /// The end of a capture still under a minute (« Envoyer », a double tap, a call taking the microphone): it leaves
    /// as a request and nothing of it is kept as a recording.
    func send() async {
        guard isActive, isTentative, !sending, let journal else { return }
        sending = true
        defer { sending = false }
        let ended = Date()
        demo?.cancel()
        watchdog?.cancel()
        // The last words still on their way from the microphone are written first.
        if !isDemo { await mic.stopAndDrain() }
        writer?.close()
        writer = nil
        let seconds = openSeconds
        let folder = WatchFiles.recording(journal.id)
        let file = journal.openSegment.map { folder.appending(path: $0.file) }
        self.journal = nil
        isTentative = false
        openSeconds = 0
        level = 0
        phase = .idle
        // Gone before the file moves: a crash while sending must not leave a journal that comes back as an empty recording.
        try? FileManager.default.removeItem(at: folder.appending(path: "journal.json"))
        if CaptureRule.ending(seconds: seconds, tentative: true) == .request, let file {
            answer = await AskCenter.shared.submit(audioAt: file, seconds: seconds, endedAt: ended)
        }
        try? FileManager.default.removeItem(at: folder)
    }

    /// « Annuler » while the capture may still be a request: nothing is kept.
    func cancel() {
        guard isActive, isTentative, !sending, let journal else { return }
        demo?.cancel()
        watchdog?.cancel()
        mic.stop()
        writer?.close()
        writer = nil
        self.journal = nil
        isTentative = false
        openSeconds = 0
        level = 0
        phase = .idle
        if !isDemo { try? FileManager.default.removeItem(at: WatchFiles.recording(journal.id)) }
    }

    /// The answer the capture screen opened: not opened twice.
    func consumeAnswer() {
        answer = nil
    }

    /// A key moment: double tap (pinch) or the on-screen button.
    func mark() {
        guard isActive, !isTentative, var journal else { return }
        guard journal.mark(at: elapsed) != nil else { return }
        self.journal = journal
        markerPulse += 1
        save()
        WKInterfaceDevice.current().play(.notification)
    }

    func stop() {
        guard isActive, var journal else { return }
        guard !isTentative else {
            Task { await send() }
            return
        }
        demo?.cancel()
        watchdog?.cancel()
        cancelReminder()
        mic.stop()
        writer?.close()
        writer = nil
        journal.finish(openDuration: openSeconds)
        if let last = journal.closedSegments.last, !isDemo {
            RecordingUplink.shared.enqueue(recordingId: journal.id, index: last.index, file: last.file)
        }
        self.journal = journal
        openSeconds = 0
        level = 0
        phase = .finished
        save()
        remember(journal.manifest)
        if !isDemo { RecordingUplink.shared.update(journal.manifest) }
        WKInterfaceDevice.current().play(.stop)
    }

    /// Back on screen after an interruption: a new segment starts where the audio stopped.
    func resume() {
        guard phase == .interrupted else { return }
        cancelReminder()
        closeSegment()
        guard var journal else { return }
        journal.status = .recording
        let segment = journal.openNextSegment()
        do {
            writer = try AACWriter(url: WatchFiles.recording(journal.id).appending(path: segment.file),
                                   bitRate: CaptureRule.bitRate(ofSegment: segment.index))
            self.journal = journal
            try mic.start()
            phase = .recording
            error = nil
            startWatchdog()
            save()
            WKInterfaceDevice.current().play(.start)
        } catch {
            self.error = error.localizedDescription
            WKInterfaceDevice.current().play(.failure)
        }
    }

    /// The finished screen is closed: the next recording starts from a clean state.
    func dismiss() {
        guard phase == .finished else { return }
        journal = nil
        warning = nil
        phase = .idle
    }

    // MARK: - Launch

    /// A journal still recording at launch: the app crashed or the watch restarted. What was written is kept and sent.
    func recoverAtLaunch() {
        guard !isDemo, !isActive, !recovered else { return }
        recovered = true
        let folders = (try? FileManager.default.contentsOfDirectory(at: WatchFiles.recordings, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where folder.hasDirectoryPath {
            let url = folder.appending(path: "journal.json")
            guard let journal = WatchFiles.load(RecordingJournal.self, from: url) else { continue }
            guard journal.status != .finished else {
                // Finished, but a crash may have come before its last manifest left: sent again (the iPhone ignores a copy).
                RecordingUplink.shared.update(journal.manifest)
                continue
            }
            let recovered = journal.recovered { segment in
                (try? AVAudioFile(forReading: folder.appending(path: segment.file))).map { Double($0.length) / $0.fileFormat.sampleRate }
            }
            WatchFiles.save(recovered, to: url)
            for segment in recovered.closedSegments {
                RecordingUplink.shared.enqueue(recordingId: recovered.id, index: segment.index, file: segment.file)
            }
            RecordingUplink.shared.update(recovered.manifest)
            remember(recovered.manifest)
        }
        RecordingUplink.shared.pump()
    }

    /// Everything reached the iPhone: the folder goes, the iPhone keeps the audio until it is transcribed.
    func transferred(_ id: String) {
        guard journal?.id != id || phase == .finished else { return }
        try? FileManager.default.removeItem(at: WatchFiles.recording(id))
    }

    // MARK: - Audio

    private func consume(_ samples: [Float], level: Float) {
        guard phase == .recording else { return }
        self.level = level
        guard let writer = writer ?? reopenWriter() else { return }
        do {
            try writer.append(samples)
        } catch {
            guard !isTentative else {
                if !sending { abandon(String(localized: "The watch couldn't record your request. Try again.")) }
                return
            }
            // The file being written is lost from here: the next piece starts a new one, and the screen says so.
            warn(String(localized: "A piece couldn't be written to the watch. Recording continues."))
            rotate()
            return
        }
        openSeconds = Double(writer.samplesWritten) / WatchMic.sampleRate
        guard var journal else { return }
        journal.updateOpenSegment(duration: openSeconds)
        self.journal = journal
        // A request being sent gets its last words even past the minute: it does not become a recording then.
        guard !sending else { return }
        if writer.samplesWritten >= Self.samplesPerSegment(journal.openSegment?.index ?? 0) {
            if isTentative { becomeRecording() } else { rotate() }
        } else if Date().timeIntervalSince(lastSave) > 5 {
            save()
        }
    }

    /// A writer for the open segment, after a file that could not be created or written.
    private func reopenWriter() -> AACWriter? {
        guard var journal else { return nil }
        let segment = journal.openSegment ?? journal.openNextSegment()
        self.journal = journal
        openSeconds = 0
        do {
            writer = try AACWriter(url: WatchFiles.recording(journal.id).appending(path: segment.file),
                                   bitRate: CaptureRule.bitRate(ofSegment: segment.index))
            return writer
        } catch {
            warn(String(localized: "The watch can't write the recording. Trying again…"))
            return nil
        }
    }

    private func rotate() {
        closeSegment()
        guard var journal else { return }
        if Date().timeIntervalSince(storageCheckedAt) > 60 { Task { await refreshStorage() } }
        switch storageState {
        case .full:
            error = String(localized: "The watch is full: recording stopped. Bring the iPhone closer to free up space.")
            stop()
            return
        case .nearlyFull:
            warn(String(localized: "The watch is almost full: bring the iPhone closer so it can collect the audio."))
        case .ok:
            break
        }
        let segment = journal.openNextSegment()
        self.journal = journal
        writer = try? AACWriter(url: WatchFiles.recording(journal.id).appending(path: segment.file),
                                bitRate: CaptureRule.bitRate(ofSegment: segment.index))
        if writer == nil { warn(String(localized: "The watch can't write the recording. Trying again…")) }
        save()
        RecordingUplink.shared.update(journal.manifest)
    }

    /// Finishes the file being written and hands it over.
    private func closeSegment() {
        guard var journal, let open = journal.openSegment else { return }
        writer?.close()
        writer = nil
        journal.closeSegment(duration: openSeconds)
        openSeconds = 0
        self.journal = journal
        if journal.closedSegments.last?.index == open.index {
            RecordingUplink.shared.enqueue(recordingId: journal.id, index: open.index, file: open.file)
        }
    }

    private func interruption(began: Bool) {
        guard phase == .recording || phase == .interrupted else { return }
        if began {
            // Under a minute, what was said leaves as a request rather than waiting on a paused screen.
            if isTentative {
                Task { await send() }
            } else {
                pause()
            }
        } else if WKApplication.shared().applicationState == .active {
            resume()
        }
    }

    /// The microphone stopped: what was recorded is kept, the screen offers to resume, and the wrist is told. The
    /// session stays ours (the haptic plays while it is still active), so the end of an interruption is heard.
    private func pause() {
        guard phase == .recording else { return }
        watchdog?.cancel()
        WKInterfaceDevice.current().play(.failure)
        mic.suspend()
        closeSegment()
        if var journal {
            journal.status = .paused
            self.journal = journal
        }
        phase = .interrupted
        level = 0
        save()
        scheduleReminder()
    }

    /// Ten seconds later, if still paused: a notification, which reaches the wrist with the app in the background.
    private func scheduleReminder() {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Recording paused")
        content.body = String(localized: "Tap to resume recording.")
        content.sound = .default
        let request = UNNotificationRequest(identifier: Self.pausedReminder, content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 10, repeats: false))
        UNUserNotificationCenter.current().add(request)
    }

    private func cancelReminder() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.pausedReminder])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.pausedReminder])
    }

    /// Any stop of the engine the system does not announce (a session taken by another app) shows as no samples
    /// coming from the audio thread; a second look a moment later rules out a slow main thread.
    private func startWatchdog() {
        watchdog?.cancel()
        let clock = mic.clock
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard Date().timeIntervalSince(clock.lastSample) > Self.silenceLimit else { continue }
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, self.phase == .recording else { return }
                if Date().timeIntervalSince(clock.lastSample) > Self.silenceLimit {
                    if self.isTentative {
                        // Its own task: this one is cancelled by the send, which would cut the last words short.
                        Task { await self.send() }
                    } else {
                        self.pause()
                    }
                    return
                }
            }
        }
    }

    private func refreshStorage() async {
        storageCheckedAt = Date()
        storageState = await Task.detached(priority: .utility) { Self.storage() }.value
    }

    private func warn(_ message: String) {
        guard warning != message else { return }
        warning = message
        WKInterfaceDevice.current().play(.failure)
    }

    private func save() {
        guard let journal, !isDemo else { return }
        lastSave = Date()
        WatchFiles.save(journal, to: WatchFiles.recording(journal.id).appending(path: "journal.json"))
    }

    private func remember(_ manifest: RecordingManifest) {
        history.removeAll { $0.id == manifest.id }
        history.insert(manifest, at: 0)
        history = Array(history.prefix(10))
        if !isDemo { WatchFiles.save(history, to: Self.historyURL) }
    }

    private func fail(message: String) {
        phase = .idle
        error = message
        WKInterfaceDevice.current().play(.failure)
    }

    /// A request that could not be written: nothing of it is sent, the screen says so.
    private func abandon(_ message: String) {
        cancel()
        fail(message: message)
    }

    /// The room the recordings waiting for the iPhone take, against the watch's cap and its free space.
    nonisolated static func storage() -> StorageBudget.State {
        let folder = WatchFiles.recordings
        var used: Int64 = 0
        if let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in files {
                used += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        let free = (try? FileManager.default.attributesOfFileSystem(forPath: folder.path))?[.systemFreeSize] as? Int64
        return StorageBudget.state(used: used, free: free)
    }

    // MARK: - Demo

    /// `-demo`: a recording under way, with markers, and a moving level; no microphone.
    func playDemo(elapsed: TimeInterval, markers: [TimeInterval], finished: Bool = false) {
        isDemo = true
        var journal = RecordingJournal(id: "3f6c2a1e-8d4b-4f0a-9c1e-5a7b2d9e4c10", startedAt: Date().addingTimeInterval(-elapsed))
        var closed: TimeInterval = 0
        while elapsed - closed > RecordingJournal.seconds(ofSegment: journal.closedSegments.count) {
            let length = RecordingJournal.seconds(ofSegment: journal.closedSegments.count)
            journal.openNextSegment()
            journal.closeSegment(duration: length)
            closed += length
        }
        journal.openNextSegment()
        openSeconds = elapsed - closed
        journal.updateOpenSegment(duration: openSeconds)
        for offset in markers { _ = journal.mark(at: offset) }
        self.journal = journal
        isTentative = false
        phase = .recording
        if finished {
            stop()
            return
        }
        animateDemo()
    }

    /// `-demo`: a capture a few seconds in, still a possible request; no microphone.
    func playDemoListening(seconds: TimeInterval) {
        isDemo = true
        var journal = RecordingJournal(id: "8a2e4c6b-1f3d-4b7a-9e5c-2d4f6a8b0c13", startedAt: Date().addingTimeInterval(-seconds))
        journal.openNextSegment()
        journal.updateOpenSegment(duration: seconds)
        self.journal = journal
        openSeconds = seconds
        isTentative = true
        phase = .recording
        animateDemo()
    }

    private func animateDemo() {
        demo?.cancel()
        demo = Task { [weak self] in
            var tick = 0.0
            while let self, !Task.isCancelled, self.phase == .recording {
                tick += 1
                self.level = Float(0.45 + 0.3 * sin(tick * 0.7) + 0.1 * sin(tick * 2.3))
                self.openSeconds += 0.12
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }
}
