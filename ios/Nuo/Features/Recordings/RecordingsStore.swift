import Foundation
import Observation
import UIKit

/// What can stop a recording on its way to a note, with the words shown for it.
enum RecordingFailure: LocalizedError, Equatable {
    case notConfigured
    case providerFailed(String)
    case noSpeech
    case missingAudio
    case incompleteTransfer
    case noNoteBot
    case notPaired
    /// The bot ended in error or never answered: tried again once on its own at most, then by hand.
    case botNoAnswer

    var errorDescription: String? {
        switch self {
        case .notConfigured: String(localized: "Transcription is not set up on your gateway.")
        case let .providerFailed(message): message.isEmpty ? String(localized: "Transcription failed. Try again: the audio is kept.") : String(localized: "Transcription: \(message). Try again: the audio is kept.")
        case .noSpeech: String(localized: "No speech in the recording.")
        case .missingAudio: String(localized: "The recording audio is no longer on the iPhone.")
        case .incompleteTransfer: String(localized: "Some chunks of the recording are still missing.")
        case .noNoteBot: String(localized: "Choose the bot that writes the summaries in Recordings.")
        case .notPaired: String(localized: "The iPhone is not paired with your gateway.")
        case .botNoAnswer: String(localized: "The bot did not answer. Try again: the transcript is kept.")
        }
    }
}

@MainActor
@Observable
final class RecordingsStore {
    static let shared = RecordingsStore()

    private(set) var recordings: [PhoneRecording] = []
    /// Keep the audio after the transcription (off: deleted from the iPhone and the gateway once transcribed).
    var keepsAudio: Bool = UserDefaults.standard.bool(forKey: "nuo.recordings.keepAudio") {
        didSet { UserDefaults.standard.set(keepsAudio, forKey: "nuo.recordings.keepAudio") }
    }
    var template: MeetingTemplate = MeetingTemplate(rawValue: UserDefaults.standard.string(forKey: "nuo.recordings.template") ?? "") ?? .general {
        didSet { UserDefaults.standard.set(template.rawValue, forKey: "nuo.recordings.template") }
    }
    var noteBotId: String? = UserDefaults.standard.string(forKey: "nuo.recordings.botId") {
        didSet { UserDefaults.standard.set(noteBotId, forKey: "nuo.recordings.botId") }
    }

    @ObservationIgnored private weak var session: SessionStore?
    @ObservationIgnored private weak var bots: BotsStore?
    /// One task per recording: its pipeline, or the wait before trying a silent gateway again.
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    /// Recordings whose task only waits before trying again: « Réessayer » cuts that wait short.
    @ObservationIgnored private var waiting: Set<String> = []
    @ObservationIgnored private var isDemo = false
    @ObservationIgnored private var deleted: [String] = UserDefaults.standard.stringArray(forKey: "nuo.recordings.deleted") ?? []
    @ObservationIgnored private var lastIndex: Data?
    @ObservationIgnored private var lastTranscripts: [String: Int] = [:]
    private static var indexURL: URL { RecordingInbox.root.appending(path: "recordings.json") }
    private static let gatewayRetry: Duration = .seconds(60)

    private struct Transcript: Codable {
        var lines: [RecordingLine]?
        var doneParts: [Int: [RecordingLine]]
    }

    private init() {
        load()
    }

    func attach(session: SessionStore, bots: BotsStore) {
        self.session = session
        self.bots = bots
        isDemo = session.isDemo
        if isDemo {
            recordings = RecordingsDemo.recordings()
            return
        }
        resumeAll()
        Task { await WatchAskRelay.retry() }
    }

    func recording(id: String) -> PhoneRecording? { recordings.first { $0.id == id } }

    var inProgress: Int { recordings.filter { $0.stage != .ready && $0.stage != .failed }.count }

    /// The bot that writes the notes, as the settings show it.
    var noteBot: Bot? { NoteBotChoice.pick(bots: bots?.bots ?? [], chosenId: noteBotId) }
    var noteBotCandidates: [Bot] { (bots?.bots ?? []).filter(NoteBotChoice.isEligible) }

    /// « Réessayer » needs the audio until there is a transcript.
    func canRetry(_ id: String) -> Bool {
        guard let recording = recording(id: id) else { return false }
        if recording.lines != nil { return true }
        let folder = RecordingInbox.folder(recording: id)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return files.contains { $0 == RecordingAudio.fileName || $0.hasPrefix("segment-") }
    }

    // MARK: - From the watch

    func manifestArrived(_ manifest: RecordingManifest) {
        guard !deleted.contains(manifest.id) else { return }
        update(manifest.id, creating: manifest) { recording in
            if recording.note == nil, recording.startedAt != manifest.startedAt {
                // A piece came before the manifest: the recording was named after its arrival time.
                recording.startedAt = manifest.startedAt
                recording.title = Self.defaultTitle(manifest.startedAt)
            }
            recording.duration = manifest.duration
            recording.markers = manifest.markers
            recording.interrupted = manifest.interrupted
            recording.arrival.manifest = manifest
            if recording.stage == .recording || recording.stage == .transferring {
                recording.stage = manifest.isFinished ? .transferring : .recording
            }
            if manifest.isFinished, manifest.segmentCount == 0 {
                recording.stage = .failed
                recording.error = RecordingFailure.noSpeech.errorDescription
            }
        }
        process(manifest.id)
    }

    /// A piece `RecordingInbox` stored. Copies were already dropped there, before touching any file.
    func segmentArrived(recordingId: String, index: Int, stored: RecordingInbox.Stored) {
        guard case .stored = stored else { return }
        if deleted.contains(recordingId) {
            try? FileManager.default.removeItem(at: RecordingInbox.folder(recording: recordingId))
            return
        }
        update(recordingId, creating: nil) {
            $0.arrival.receive(index: index)
            $0.lastArrivalAt = Date()
        }
        process(recordingId)
    }

    /// The watch lost a piece (a crash before it was closed): the iPhone stops waiting, silence goes in its place.
    func segmentLost(recordingId: String, index: Int) {
        guard !deleted.contains(recordingId) else { return }
        update(recordingId, creating: nil) { $0.arrival.markLost(index: index) }
        process(recordingId)
    }

    // MARK: - Pipeline

    /// At launch, back in front and at the unlock: pieces found on disk count, and what waited goes on.
    func resumeAll() {
        guard !isDemo else { return }
        rescanDisk()
        replayStops()
        for recording in recordings {
            if recording.stage == .failed, recording.retryable {
                set(recording.id) {
                    $0.error = nil
                    $0.retryable = false
                    $0.stage = $0.lines == nil ? .transcribing : .writing
                }
            }
            process(recording.id)
        }
    }

    /// By hand: a job that failed at the provider is dropped and the audio sent again under new ids; a job still
    /// running or done is picked up as it is.
    func retry(_ id: String) {
        guard let recording = recording(id: id) else { return }
        if waiting.contains(id) {
            tasks[id]?.cancel()
            tasks[id] = nil
            waiting.remove(id)
        }
        set(id) { $0.noteAttempts = 0 }
        guard recording.lines == nil, case let .ready(client) = AppAccess.state() else {
            restart(id)
            return
        }
        let jobs = recording.jobIds
        Task {
            var failed: [String] = []
            for job in jobs {
                if case .failed? = try? await client.transcriptionJob(job) { failed.append(job) }
            }
            // A stopped id is refused for five minutes: the audio goes again under new ids.
            await stopJobs(failed, client: client)
            if !failed.isEmpty { set(id) { $0.generation += 1 } }
            restart(id)
        }
    }

    /// Some pieces never came: the note is written from those that did, with silence in their place.
    func transcribePartially(_ id: String) {
        guard recording(id: id)?.canTranscribePartially() == true else { return }
        set(id) {
            $0.partial = true
            $0.stage = .transcribing
            $0.error = nil
        }
        process(id)
    }

    /// The missing pieces came after all: everything is transcribed again.
    func transcribeFully(_ id: String) {
        guard recording(id: id)?.canTranscribeFully == true else { return }
        tasks[id]?.cancel()
        tasks[id] = nil
        let folder = RecordingInbox.folder(recording: id)
        try? FileManager.default.removeItem(at: folder.appending(path: RecordingAudio.fileName))
        RecordingAudio.removePasses(in: folder)
        lastTranscripts[id] = nil
        set(id) {
            $0.silenceGaps = []
            $0.partial = false
            $0.assembled = false
            $0.lines = nil
            $0.doneParts = [:]
            $0.note = nil
            $0.noteConversationId = nil
            $0.warning = nil
            $0.generation += 1
            $0.stage = .transcribing
        }
        process(id)
    }

    private func restart(_ id: String) {
        set(id) {
            $0.error = nil
            $0.retryable = false
            $0.stage = $0.lines == nil ? .transcribing : .writing
        }
        process(id)
    }

    /// One task per recording, which waits and tries again by itself while the gateway is silent: a second call
    /// never starts a second run. `delete` and `transcribeFully` cancel it.
    func process(_ id: String) {
        guard !isDemo, tasks[id] == nil, let recording = recording(id: id) else { return }
        switch recording.stage {
        case .ready, .failed, .recording:
            return
        case .transferring:
            guard recording.arrival.isComplete else { return }
        case .transcribing, .writing:
            break
        }
        let task = Task {
            while !Task.isCancelled {
                guard await run(id), !Task.isCancelled else { break }
                waiting.insert(id)
                try? await Task.sleep(for: Self.gatewayRetry)
                waiting.remove(id)
            }
        }
        tasks[id] = task
        Task {
            await task.value
            // A cancelled task may end after its replacement started: only its own entry goes.
            if tasks[id] == task { tasks[id] = nil }
        }
    }

    /// True when it should run again after a wait (silent gateway, provider busy).
    private func run(_ id: String) async -> Bool {
        let window = AppAccess.backgroundWindow("nuo.recording")
        defer { window() }
        guard let recording = recording(id: id) else { return false }
        set(id) { $0.waitingUnlock = false }
        if recording.lines == nil {
            set(id) { $0.stage = .transcribing }
            do {
                var lines = try await transcribe(id)
                guard !Task.isCancelled else { return false }
                // What the recognition may hear in a silence that replaced a missing piece is not what was said.
                lines = SilenceGaps.drop(lines, in: self.recording(id: id)?.gaps ?? [])
                set(id) {
                    $0.lines = lines
                    $0.doneParts = [:]
                    $0.waitingGateway = false
                    $0.stage = .writing
                }
                await dropGatewayCopies(id)
                if !keepsAudio {
                    deleteAudio(id)
                    deleteSegments(id)
                }
            } catch {
                return handle(error, id: id)
            }
        }
        return await writeNote(id)
    }

    /// Locked: waits for the unlock. Silent gateway: tries again later. Anything else: shown, tried again by hand.
    private func handle(_ error: Error, id: String) -> Bool {
        if error is CancellationError { return false }
        if AppAccess.isLockFailure(error) {
            set(id) { $0.waitingUnlock = true }
            return false
        }
        if GatewayWait.isTransient(error) {
            set(id) { $0.waitingGateway = true }
            return true
        }
        // The provider refused a job for a moment: one real new try, under a new id, a minute later.
        if let failed = error as? TranscriptionJob.Failed, failed.status == 429, (recording(id: id)?.providerRetries ?? 1) < 1 {
            set(id) {
                $0.providerRetries += 1
                $0.generation += 1
                $0.waitingGateway = true
            }
            return true
        }
        fail(id, error, retryable: false)
        return false
    }

    private func deleteSegments(_ id: String) {
        let folder = RecordingInbox.folder(recording: id)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix("segment-") {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
    }

    private func client() throws -> NuoClient {
        switch AppAccess.state() {
        case let .ready(client): return client
        case .locked: throw LockedError()
        case .unpaired: throw RecordingFailure.notPaired
        }
    }

    private struct LockedError: LocalizedError {
        var errorDescription: String? { String(localized: "The iPhone is locked: transcription resumes as soon as it is unlocked.") }
    }

    /// The transcript on the recording's clock, part by part: a part already done is never sent again.
    private func transcribe(_ id: String) async throws -> [RecordingLine] {
        let client = try client()
        let audio = try await prepareAudio(id)
        guard let recording = recording(id: id) else { throw RecordingFailure.missingAudio }
        let plan = RecordingParts.plan(duration: recording.duration)
        let folder = RecordingInbox.folder(recording: id)
        let files = try await Task.detached(priority: .userInitiated) { try RecordingAudio.uploads(audio, plan: plan, folder: folder) }.value
        for (part, file) in zip(plan.parts, files) where self.recording(id: id)?.doneParts[part.index] == nil {
            try Task.checkCancellation()
            let job = RecordingParts.jobId(recordingId: id, part: part.index, generation: self.recording(id: id)?.generation ?? recording.generation)
            let transcript = try await transcribePart(file, job: job, seconds: part.duration, client: client)
            let lines = RecordingParts.shift(RecordingLine.from(transcript.segments ?? [], language: transcript.language), by: part.start)
            set(id) {
                $0.doneParts[part.index] = lines
                $0.partJobs[part.index] = job
                $0.language = $0.language ?? transcript.language
            }
        }
        for file in files where file != audio { try? FileManager.default.removeItem(at: file) }
        return RecordingParts.merge(self.recording(id: id)?.doneParts ?? [:], plan: plan.parts)
    }

    private func transcribePart(_ file: URL, job: String, seconds: TimeInterval, client: NuoClient) async throws -> CloudTranscript {
        // A job sent before a relaunch: its result, without sending the audio again.
        do {
            switch try await client.transcriptionJob(job) {
            case let .done(transcript): return transcript
            case .running: return try await awaitJob(job, client: client)
            case let .failed(status, message): throw TranscriptionJob.Failed(status: status, message: message)
            }
        } catch NuoError.notFound {
            // Unknown to the gateway (expired, or never received): the audio goes.
        }
        // Read once: a background upload session cannot carry the per-request signature the gateway checks.
        let audio = try Data(contentsOf: file)
        let names = (bots?.bots.compactMap { $0.config?.name } ?? []) + [session?.userName].compactMap { $0 }
        var form = TranscriptionForm(audio: audio, filename: "montre-\(job).m4a", language: nil, keyterms: DictationTerms.unique(names, limit: 50),
                                     segments: true, speakers: true, seconds: seconds)
        form.jobID = job
        let upload = min(3600, 120 + Double(audio.count) * 8 / 1_000_000)
        do {
            return try await client.transcribe(form, background: true, timeout: upload, pollFor: 60 * 60)
        } catch NuoError.notFound {
            // Either no transcription on the gateway, or the job vanished while it ran (gateway reset).
            if (try? await client.warmTranscription(timeout: 15)) == nil { throw RecordingFailure.notConfigured }
            return try await client.transcribe(form, background: true, timeout: upload, pollFor: 60 * 60)
        } catch let NuoError.server(status, message) where !message.isEmpty && status != 429 && status < 500 {
            throw RecordingFailure.providerFailed(message)
        }
    }

    private func awaitJob(_ job: String, client: NuoClient) async throws -> CloudTranscript {
        try await client.awaitTranscription(job, for: 60 * 60)
    }

    /// The transcript is on the iPhone: nothing of the recording stays on the gateway.
    private func dropGatewayCopies(_ id: String) async {
        guard let recording = recording(id: id), case let .ready(client) = AppAccess.state() else { return }
        await stopJobs(recording.jobIds, client: client)
    }

    /// Stops on the gateway; those it did not hear are kept and sent again at the next resume.
    /// Each answer is written to the stored list at once: two calls crossing never lose a stop.
    private func stopJobs(_ jobs: [String], client: NuoClient) async {
        for job in jobs {
            let heard = await client.cancelTranscription(job)
            var pending = Self.pendingStops
            if heard { pending.done(job) } else { pending.add([job]) }
            Self.pendingStops = pending
        }
    }

    private static var pendingStops: PendingJobStops {
        get { UserDefaults.standard.data(forKey: "nuo.recordings.pendingStops").flatMap { try? JSONDecoder().decode(PendingJobStops.self, from: $0) } ?? PendingJobStops() }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "nuo.recordings.pendingStops") }
    }

    private func replayStops() {
        let jobs = Self.pendingStops.ids
        guard !jobs.isEmpty, case let .ready(client) = AppAccess.state() else { return }
        Task { await stopJobs(jobs, client: client) }
    }

    /// `audio.m4a`, put together once every expected piece is here (or, asked explicitly, with silence for the
    /// missing ones). Written through a temporary file; the pieces go only after a complete assembly.
    private func prepareAudio(_ id: String) async throws -> URL {
        guard let recording = recording(id: id) else { throw RecordingFailure.missingAudio }
        let folder = RecordingInbox.folder(recording: id)
        let audioURL = folder.appending(path: RecordingAudio.fileName)
        let marked = FileManager.default.fileExists(atPath: folder.appending(path: RecordingInbox.assembledMark).path)
        if recording.assembled || marked || (recording.partial && FileManager.default.fileExists(atPath: audioURL.path) && recording.doneParts.isEmpty == false) {
            if marked, !recording.assembled { set(id) { $0.assembled = true } }
            guard FileManager.default.fileExists(atPath: audioURL.path) else { throw RecordingFailure.missingAudio }
            return audioURL
        }
        let expected = recording.arrival.expected ?? recording.arrival.received.count
        guard expected > 0 else { throw RecordingFailure.missingAudio }
        let slots = (0..<expected).map { index -> RecordingAudio.Slot in
            let url = folder.appending(path: RecordingJournal.fileName(index: index))
            return RecordingAudio.Slot(index: index, url: FileManager.default.fileExists(atPath: url.path) ? url : nil,
                                       seconds: recording.arrival.seconds(of: index, total: recording.duration))
        }
        // A piece the watch lost is silence; any other missing one stops the assembly unless asked otherwise.
        if !recording.partial, slots.contains(where: { $0.url == nil && !recording.arrival.lost.contains($0.index) }) {
            if FileManager.default.fileExists(atPath: audioURL.path), !slots.contains(where: { $0.url != nil }) { return audioURL }
            throw RecordingFailure.incompleteTransfer
        }
        let report = try await Task.detached(priority: .userInitiated) { try RecordingAudio.assembleAtomically(slots, into: audioURL) }.value
        let gaps = report.missing.count + report.unreadable.count
        set(id) {
            $0.hasAudio = true
            $0.silenceGaps = report.gaps.map { [$0.lowerBound, $0.upperBound] }
            $0.warning = gaps == 0 ? nil : report.unreadable.isEmpty
                ? String(localized: "\(gaps) chunks of 30 s missing, replaced by silence.")
                : String(localized: "\(gaps) chunks of 30 s missing or unreadable, replaced by silence.")
        }
        if !recording.partial {
            // From here any piece arriving is a copy: it is dropped before it touches a file.
            try? Data().write(to: folder.appending(path: RecordingInbox.assembledMark))
            for slot in slots { if let url = slot.url { try? FileManager.default.removeItem(at: url) } }
            set(id) { $0.assembled = true }
        }
        return audioURL
    }

    /// True when it should run again after a wait.
    private func writeNote(_ id: String) async -> Bool {
        guard let recording = recording(id: id), let lines = recording.lines else { return false }
        guard !lines.isEmpty else {
            fail(id, RecordingFailure.noSpeech, retryable: false)
            return false
        }
        set(id) { $0.stage = .writing }
        // Launched in the background by the watch: the note waits for the app to be opened.
        guard let session, let bots else { return false }
        guard !bots.bots.isEmpty else {
            // No bot list yet (offline): a wait, not a missing choice.
            set(id) { $0.waitingGateway = true }
            return true
        }
        guard let bot = NoteBotChoice.pick(bots: bots.bots, chosenId: noteBotId) else {
            fail(id, RecordingFailure.noNoteBot, retryable: false)
            return false
        }
        let prompt = RecordingNotePrompt.build(
            title: recording.title, startedAt: recording.startedAt, duration: recording.duration, lines: lines, markers: recording.markers,
            template: recording.template, userName: session.userName, names: recording.speakerNames)
        do {
            let client = try client()
            let answer = try await Self.ask(bot: bot, prompt: prompt, existing: recording.noteConversationId, client: client) { conversationId in
                self.set(id) { $0.noteConversationId = conversationId }
            }
            let note = NotePrompt.stripFence(answer)
            let heading = note.components(separatedBy: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) }
            set(id) {
                $0.note = note
                $0.waitingGateway = false
                if let heading, !heading.isEmpty { $0.title = heading }
            }
            await save(id)
            set(id) { $0.stage = .ready }
            return false
        } catch RecordingFailure.botNoAnswer {
            set(id) { $0.noteAttempts += 1 }
            let attempts = self.recording(id: id)?.noteAttempts ?? 1
            // One more try on its own at most, in a new turn; then only by hand.
            if attempts < 2 { set(id) { $0.noteConversationId = nil } }
            fail(id, RecordingFailure.botNoAnswer, retryable: attempts < 2)
            return false
        } catch {
            return handle(error, id: id)
        }
    }

    func regenerate(_ id: String, template: MeetingTemplate) {
        guard recording(id: id)?.lines?.isEmpty == false else { return }
        set(id) {
            $0.template = template
            $0.note = nil
            $0.noteConversationId = nil
            $0.noteAttempts = 0
            $0.error = nil
            $0.stage = .writing
        }
        process(id)
    }

    /// The name goes into the transcript, the note and the saved document.
    func rename(_ id: String, voice: String, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        set(id) {
            let previous = $0.speakerNames[voice]
            $0.speakerNames[voice] = clean
            if let note = $0.note {
                var renamed = RecordingNotePrompt.renaming(note, voice: voice, to: clean)
                if let previous { renamed = RecordingNotePrompt.replacingName(renamed, from: previous, to: clean) }
                $0.note = renamed
            }
        }
        Task { await save(id) }
    }

    /// `reunions/YYYY-MM-DD-<slug>.md`, next to the Mac's meeting notes.
    private func save(_ id: String) async {
        guard let session, let recording = recording(id: id), let note = recording.note else { return }
        let content = RecordingNotePrompt.document(note: note, lines: recording.lines ?? [], markers: recording.markers, names: recording.speakerNames)
        if let path = recording.savedPath {
            do {
                _ = try await session.api.saveDoc(path: path, content: content, baseSha: nil)
                set(id) { $0.saveError = nil }
            } catch {
                set(id) { $0.saveError = String(localized: "The document \(path) could not be updated: \(error.localizedDescription)") }
            }
            return
        }
        let base = RecordingNotePrompt.documentBase(note: note, fallbackTitle: recording.title, startedAt: recording.startedAt)
        for attempt in 1...5 {
            let path = attempt == 1 ? "\(base).md" : "\(base)-\(attempt).md"
            do {
                let result = try await session.api.createDoc(path: path, content: content)
                set(id) {
                    $0.savedPath = result.path
                    $0.saveError = nil
                }
                return
            } catch NuoError.server(status: 409, _) {
                continue
            } catch {
                set(id) { $0.saveError = String(localized: "The summary could not be saved in Docs: \(error.localizedDescription)") }
                return
            }
        }
        set(id) { $0.saveError = String(localized: "A document with the same name already exists in Docs › reunions.") }
    }

    /// Stops what runs for it (an upload included), drops its jobs on the gateway, and forgets it for good.
    func delete(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        if let recording = recording(id: id), recording.lines == nil {
            let jobs = recording.jobIds
            if case let .ready(client) = AppAccess.state() {
                Task { await stopJobs(jobs, client: client) }
            } else {
                var pending = Self.pendingStops
                pending.add(jobs)
                Self.pendingStops = pending
            }
        }
        try? FileManager.default.removeItem(at: RecordingInbox.folder(recording: id))
        recordings.removeAll { $0.id == id }
        deleted.append(id)
        deleted = Array(deleted.suffix(200))
        UserDefaults.standard.set(deleted, forKey: "nuo.recordings.deleted")
        persist()
    }

    func deleteAudio(_ id: String) {
        try? FileManager.default.removeItem(at: audioURL(id))
        set(id) { $0.hasAudio = false }
    }

    func audioURL(_ id: String) -> URL { RecordingInbox.folder(recording: id).appending(path: RecordingAudio.fileName) }

    // MARK: - Disk

    private func load() {
        guard let data = try? Data(contentsOf: Self.indexURL) else { return }
        let read = PhoneRecordingIndex.decode(data, decoder: NuoJSON.decoder())
        if read == nil || (read?.dropped ?? 0) > 0 {
            // Kept aside once (named after its content) rather than overwritten by the next save.
            let aside = RecordingInbox.root.appending(path: "recordings-unreadable-\(data.hashValue & 0xFFFFFF).json")
            if !FileManager.default.fileExists(atPath: aside.path) { try? data.write(to: aside) }
        }
        recordings = (read?.recordings ?? []).map { recording in
            var recording = recording
            let url = RecordingInbox.folder(recording: recording.id).appending(path: "transcript.json")
            if let data = try? Data(contentsOf: url), let transcript = try? JSONDecoder().decode(Transcript.self, from: data) {
                if recording.lines == nil { recording.lines = transcript.lines }
                if recording.doneParts.isEmpty { recording.doneParts = transcript.doneParts }
            }
            return recording
        }
        lastIndex = data
    }

    /// Pieces on disk the index does not know: a quit between storing one and saving the index, or a recording
    /// whose manifest has not come yet.
    private func rescanDisk() {
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: RecordingInbox.root.path)) ?? []
        for name in folders where UUID(uuidString: name) != nil && !deleted.contains(name) {
            let folder = RecordingInbox.root.appending(path: name)
            let found = Self.segments(in: folder)
            guard !found.isEmpty else { continue }
            // The newest piece on disk dates the last arrival, so a stalled transfer is recognised after a relaunch.
            let newest = found.compactMap { index in
                (try? folder.appending(path: RecordingJournal.fileName(index: index)).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            }.max()
            if let recording = recording(id: name) {
                guard recording.stage == .recording || recording.stage == .transferring else { continue }
                let unknown = found.filter { !recording.arrival.received.contains($0) }
                guard !unknown.isEmpty || recording.lastArrivalAt == nil else { continue }
                set(name) {
                    for index in unknown { $0.arrival.receive(index: index) }
                    $0.lastArrivalAt = max($0.lastArrivalAt ?? .distantPast, newest ?? .distantPast)
                }
            } else {
                update(name, creating: nil) { recording in
                    for index in found { recording.arrival.receive(index: index) }
                    recording.lastArrivalAt = newest
                }
            }
        }
    }

    private static func segments(in folder: URL) -> [Int] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).compactMap { name -> Int? in
            guard name.hasPrefix("segment-"), name.hasSuffix(".m4a") else { return nil }
            return Int(name.dropFirst("segment-".count).dropLast(".m4a".count))
        }
    }

    private func fail(_ id: String, _ error: Error, retryable: Bool) {
        set(id) {
            $0.stage = .failed
            $0.error = Self.describe(error)
            $0.retryable = retryable
            $0.waitingGateway = false
        }
    }

    /// One turn of the bot over plain requests, with no chat screen behind it: nothing of the app's live state (the
    /// visible chat, a bot's preview, the live activity, haptics) moves for a note written in the background. A
    /// conversation asked before is read first: a turn that went through is never paid twice.
    private static func ask(bot: Bot, prompt: String, existing: String?, client: NuoClient,
                            started: @escaping @MainActor (String) -> Void) async throws -> String {
        let conversationId: String
        var known: Set<String> = []
        var mustSend = true
        if let existing {
            let messages = try await client.messages(conversationId: existing)
            if let last = messages.last, last.role == .assistant, last.stopReason == .endTurn, !last.text.isEmpty { return last.text }
            conversationId = existing
            known = Set(messages.map(\.id))
            // The question went and no answer came yet: the turn may still be running, it is waited for, not asked again.
            mustSend = messages.last?.role != .user
        } else {
            conversationId = try await client.createConversation(botId: bot.id, useDraft: false).id
            started(conversationId)
        }
        if mustSend {
            struct Started: Decodable { let messageId: String? }
            let _: Started = try await client.request("POST", "/api/conversations/\(conversationId)/prompt", body: ["text": prompt])
        }
        let deadline = Date().addingTimeInterval(mustSend ? 20 * 60 : 5 * 60)
        while Date() < deadline {
            try await Task.sleep(for: .seconds(3))
            let messages = try await client.messages(conversationId: conversationId)
            guard let answer = messages.last(where: { $0.role == .assistant && !known.contains($0.id) }), let reason = answer.stopReason else { continue }
            guard reason == .endTurn, !answer.text.isEmpty else { throw RecordingFailure.botNoAnswer }
            return answer.text
        }
        throw RecordingFailure.botNoAnswer
    }

    private static func describe(_ error: Error) -> String {
        if let failure = error as? RecordingFailure { return failure.errorDescription ?? String(localized: "Failed") }
        if let failed = error as? TranscriptionJob.Failed { return RecordingFailure.providerFailed(failed.message).errorDescription ?? String(localized: "Failed") }
        if case NuoError.unauthorized? = error as? NuoError { return String(localized: "The iPhone is no longer authorized on your gateway: pair it again.") }
        if case NuoError.reauthRequired? = error as? NuoError { return String(localized: "The iPhone is no longer authorized on your gateway: pair it again.") }
        if GatewayWait.isTransient(error) { return String(localized: "Gateway unreachable: trying again next time you open the app. The audio is kept.") }
        return error.localizedDescription
    }

    private func update(_ id: String, creating manifest: RecordingManifest?, _ change: (inout PhoneRecording) -> Void) {
        if recording(id: id) == nil {
            let startedAt = manifest?.startedAt ?? Date()
            recordings.insert(PhoneRecording(
                id: id, title: Self.defaultTitle(startedAt), startedAt: startedAt, duration: manifest?.duration ?? 0, markers: manifest?.markers ?? [],
                template: template, stage: manifest?.isFinished == false ? .recording : .transferring), at: 0)
        }
        set(id, change)
    }

    private static func defaultTitle(_ startedAt: Date) -> String {
        String(localized: "Recording of \(startedAt.formatted(.dateTime.day().month(.wide).hour().minute().locale(.current)))")
    }

    private func set(_ id: String, _ change: (inout PhoneRecording) -> Void) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        let before = recordings[index]
        change(&recordings[index])
        guard recordings[index] != before else { return }
        recordings.sort { $0.startedAt > $1.startedAt }
        persist()
    }

    /// The index without the transcripts, written only when it changed; each transcript in its recording's folder.
    private func persist() {
        guard !isDemo else { return }
        let light = recordings.map { recording -> PhoneRecording in
            var copy = recording
            copy.lines = nil
            copy.doneParts = [:]
            return copy
        }
        if let data = try? NuoJSON.encoder().encode(light), data != lastIndex {
            try? data.write(to: Self.indexURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            lastIndex = data
        }
        for recording in recordings where recording.lines != nil || !recording.doneParts.isEmpty {
            let transcript = Transcript(lines: recording.lines, doneParts: recording.doneParts)
            guard let data = try? JSONEncoder().encode(transcript), lastTranscripts[recording.id] != data.hashValue else { continue }
            try? data.write(to: RecordingInbox.folder(recording: recording.id).appending(path: "transcript.json"),
                            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            lastTranscripts[recording.id] = data.hashValue
        }
    }
}
