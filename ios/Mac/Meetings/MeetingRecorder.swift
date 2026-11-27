@preconcurrency import AVFoundation
import AppKit
import Foundation
import Observation

/// One meeting: the mic (« Moi ») and the system audio (« Eux ») recorded to temporary files in the app's caches, then
/// transcribed once it is over, in one pass: by the gateway's service (which tells the other participants apart), or
/// on the Mac by Whisper or Apple's recognizer when the cloud is off or fails. The files are deleted as soon as the
/// transcription is done or the meeting is discarded; the transcript and the notes stay until the next meeting.
@MainActor
@Observable
final class MeetingRecorder {
    static let shared = MeetingRecorder()

    enum Phase: Equatable { case idle, starting, recording, stopped }
    enum NoteState: Equatable { case none, generating, ready, failed(String) }
    enum Transcription: Equatable {
        case none
        case downloading(Double)
        /// Loading the model; the first time it is compiled for the Neural Engine, which takes a few minutes.
        case preparing
        /// The meeting is over and being transcribed.
        case finishing(progress: Double, remaining: TimeInterval?)
        case done
        case failed(String)
    }
    enum Issue: Equatable {
        case microphone, microphoneSilent, systemAudio, recording(String)

        var message: String {
            switch self {
            case .microphone:
                String(localized: "Nuo can't access the microphone. Allow it in System Settings › Privacy & Security › Microphone, then start recording again.")
            case .microphoneSilent:
                String(localized: "The microphone isn't picking up any sound. Check that it isn't muted and the input chosen in System Settings › Sound.")
            case .systemAudio:
                String(localized: "No sound from the other participants yet. If they are speaking, allow Nuo in System Settings › Privacy & Security › System Audio Recording Only.")
            case let .recording(text): text
            }
        }

        var settingsURL: URL? {
            switch self {
            case .microphone: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            case .microphoneSilent: URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")
            case .systemAudio: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
            case .recording: nil
            }
        }
    }

    static let minimumDuration: TimeInterval = 60

    private(set) var phase: Phase = .idle
    private(set) var startedAt: Date?
    private(set) var endedAt: Date?
    private(set) var transcript = MeetingTranscript()
    private(set) var transcription: Transcription = .none
    private(set) var issue: Issue?
    private(set) var micLevel: Float = 0
    private(set) var systemLevel: Float = 0
    private(set) var hasSystemAudio = false
    /// Whisper code of the language the meeting was transcribed in, once known.
    private(set) var detectedLanguage: String?
    /// The engine of the meeting under way or just finished; `engine` is the choice for the next one.
    private(set) var activeEngine: MeetingEngine = .whisper
    /// Whisper is redoing a transcript made by Apple; the old one stays shown until the new one is complete.
    private(set) var isRetranscribing = false
    /// The transcript came from the gateway's service rather than the Mac.
    private(set) var transcribedInCloud = false
    /// The recording of the finished meeting is still on disk (kept after Apple, for a Whisper retranscription).
    private(set) var hasRecording = false
    var title = ""
    var participants = ""
    var notes = ""
    private(set) var eventId: String?
    /// The calendar event a notification pointed at, offered by the idle window until a meeting starts.
    private(set) var proposedEventId: String?
    /// Asks the meeting window to confirm before the previous meeting is wiped.
    var confirmsStart = false

    var template: MeetingTemplate = MeetingTemplate(rawValue: UserDefaults.standard.string(forKey: AppIdentity.local(.meetingTemplate)) ?? "") ?? .general {
        didSet { UserDefaults.standard.set(template.rawValue, forKey: AppIdentity.local(.meetingTemplate)) }
    }
    var engine: MeetingEngine = MeetingEngine(rawValue: UserDefaults.standard.string(forKey: AppIdentity.local(.meetingEngine)) ?? "") ?? .whisper {
        didSet { UserDefaults.standard.set(engine.rawValue, forKey: AppIdentity.local(.meetingEngine)) }
    }
    var language: MeetingLanguage = MeetingLanguage(rawValue: UserDefaults.standard.string(forKey: AppIdentity.local(.meetingLanguage)) ?? "") ?? .auto {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: AppIdentity.local(.meetingLanguage)) }
    }
    /// The gateway's service transcribes the meeting; off, the audio never leaves the Mac and `engine` does it.
    var useCloud: Bool = UserDefaults.standard.object(forKey: AppIdentity.local(.meetingCloud)) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(useCloud, forKey: AppIdentity.local(.meetingCloud))
            // Off means off: the gateway is no longer asked, and its transcript will not replace the Mac's.
            if !useCloud, follower != nil {
                follower?.cancel()
                follower = nil
                // The jobs the follower waited on are of no use any more.
                stopCloudJobs()
                cloudJobs = [:]
                archiveProgress()
            }
        }
    }
    var botId: String? = UserDefaults.standard.string(forKey: AppIdentity.local(.meetingBotId)) {
        didSet { UserDefaults.standard.set(botId, forKey: AppIdentity.local(.meetingBotId)) }
    }
    private(set) var noteState: NoteState = .none
    private(set) var note = ""
    private(set) var savedPath: String?
    private(set) var saveError: String?
    var actions: [MeetingAction] = []
    private(set) var remindersCreated = 0

    /// Bumped to ask a live view to open (or bring forward) the meeting window.
    private(set) var windowRequest = 0
    /// Recording starts without any window unless the user opened the notepad during the last one.
    var opensWindowOnStart: Bool {
        get { UserDefaults.standard.bool(forKey: AppIdentity.local(.meetingShowWindow)) }
        set { UserDefaults.standard.set(newValue, forKey: AppIdentity.local(.meetingShowWindow)) }
    }

    @ObservationIgnored private var mic: MeetingMicCapture?
    @ObservationIgnored private var tap: SystemAudioTap?
    @ObservationIgnored private var writers: [(speaker: MeetingSpeaker, writer: MeetingStreamWriter)] = []
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private weak var session: SessionStore?
    @ObservationIgnored private weak var bots: BotsStore?
    @ObservationIgnored private var generation: Task<Void, Never>?
    @ObservationIgnored private var transcribing: Task<Void, Never>?
    @ObservationIgnored private var transcriber: MeetingTranscriber?
    @ObservationIgnored private var appleReady = false
    @ObservationIgnored private var restored = false
    @ObservationIgnored private var demoApplied = false
    /// Bumped by every start, stop of a start and discard: work of an earlier meeting checks it before touching this one.
    @ObservationIgnored private var run = 0
    /// Samples of each stream whose lines are in `transcript`, saved with it so an interrupted meeting can resume.
    @ObservationIgnored private var resumeCursors: [Int] = []
    /// The gateway job of each stream, named at the end of the recording.
    @ObservationIgnored private var cloudJobs: [MeetingSpeaker: String] = [:]
    /// The wait for the gateway's transcript; « Transcrire sur le Mac maintenant » cancels it.
    @ObservationIgnored private var cloudWait: Task<MeetingCloud.Result, Error>?
    @ObservationIgnored private var macRequested = false
    /// Asks the gateway again while the Mac transcribes after it went silent.
    @ObservationIgnored private var follower: Task<Void, Never>?
    /// The transcript is awaited from the gateway: the Mac can be asked to do it now.
    private(set) var isWaitingForCloud = false
    @ObservationIgnored private var lastProgressArchive = Date.distantPast
    @ObservationIgnored private var pendingStartEvent: AgendaItem?

    private init() {
        QuitCoordinator.shared.register("meeting", pending: { [weak self] in self?.quitReason }, flush: { [weak self] in
            await self?.flushForQuit()
        })
    }

    /// Idempotent: called again whenever the session or bots change.
    func attach(session: SessionStore, bots: BotsStore) {
        self.session = session
        self.bots = bots
        guard !restored, !session.isDemo else { return }
        restored = true
        sendPendingDeletes()
        if phase == .idle {
            let archive = MeetingFiles.readArchive()
            // Audio of a meeting left unfinished by a quit or a crash is kept to finish its transcription; any other is not.
            MeetingFiles.removeAudio(keeping: archive?.resume)
            restore(archive)
        }
    }

    var isRecording: Bool { phase == .recording || phase == .starting }

    /// The meeting is over but its transcription is still running.
    var isFinalizing: Bool {
        guard phase == .stopped else { return false }
        if isRetranscribing { return true }
        switch transcription {
        case .finishing, .downloading, .preparing: return true
        case .none, .done, .failed: return false
        }
    }

    var quitReason: String? { MeetingQuitReason.reason(recording: isRecording, finalizing: isFinalizing) }
    var elapsed: TimeInterval { elapsed(at: Date()) }

    func elapsed(at now: Date) -> TimeInterval {
        guard let startedAt else { return 0 }
        return (endedAt ?? now).timeIntervalSince(startedAt)
    }

    var canGenerate: Bool {
        phase == .stopped && transcription == .done && elapsed >= Self.minimumDuration
            && !transcript.segments.isEmpty && noteState != .generating
    }

    /// Something worth keeping would be lost by starting over: a transcription still running or left to finish, or a
    /// transcript or notes not saved.
    var hasUnsavedWork: Bool {
        guard phase == .stopped else { return false }
        if isFinalizing || (transcriber != nil && transcription != .done) { return true }
        return savedPath == nil && (!transcript.segments.isEmpty || !notes.isEmpty)
    }

    func showWindow() { windowRequest += 1 }

    /// A notification about `eventId` was tapped: the meeting window, ready to transcribe that event.
    func showEvent(id eventId: String) {
        if phase == .idle { proposedEventId = eventId }
        showWindow()
    }

    var proposedEvent: AgendaItem? { proposedEventId.flatMap { CalendarStore.shared.item(id: $0) } }

    func toggle() {
        if isRecording { Task { await stop() } } else { requestStart(event: nil) }
    }

    /// Starts at once, or first asks in the meeting window when the previous meeting would be lost.
    func requestStart(event: AgendaItem?) {
        guard !isRecording else { return }
        guard hasUnsavedWork else {
            Task { await start(event: event) }
            return
        }
        pendingStartEvent = event
        confirmsStart = true
        showWindow()
    }

    func confirmStart() {
        let event = pendingStartEvent
        pendingStartEvent = nil
        Task { await start(event: event, confirmed: true) }
    }

    // MARK: - Recording

    /// Starts quietly: no window, no sound; the menu bar shows a small indicator. A previous meeting still being
    /// transcribed is only dropped once `confirmed`; otherwise the window asks first.
    func start(event: AgendaItem?, confirmed: Bool = false) async {
        guard !isRecording else { return }
        if isFinalizing, !confirmed {
            requestStart(event: event)
            return
        }
        run += 1
        let run = run
        generation?.cancel()
        transcribing?.cancel()
        stopCloudJobs()
        discardAudio()
        let proposed = proposedEvent
        reset()
        MeetingFiles.removeArchive()
        let current = event ?? proposed ?? Self.currentEvent()
        if let current {
            eventId = current.id
            title = current.displayTitle
            participants = Self.participants(of: current)
        }
        phase = .starting
        activeEngine = engine
        if opensWindowOnStart { showWindow() }

        if session?.isDemo == true {
            playDemo()
            return
        }

        let allowed = await Self.microphoneAllowed()
        // Stopped, or another meeting started, while the permission was asked.
        guard run == self.run, phase == .starting else { return }
        guard allowed else {
            issue = .microphone
            phase = .idle
            showWindow()
            return
        }
        let started = Date()
        let id = UUID().uuidString
        let mic = MeetingMicCapture()
        mic.onFailure = { _ in
            Task { @MainActor in MeetingRecorder.shared.captureLost(run: run, String(localized: "The microphone stopped after a device change. Check the input chosen in System Settings › Sound.")) }
        }
        do {
            let writer = try MeetingStreamWriter(url: MeetingFiles.audioDirectory.appending(path: "\(id)-moi.caf"), startedAt: started)
            try mic.start { buffer in writer.append(buffer) }
            writers = [(.me, writer)]
        } catch {
            NSLog("Nuo meeting: mic failed — %@", String(describing: error))
            discardAudio()
            issue = .recording(String(localized: "The microphone isn't available."))
            phase = .idle
            showWindow()
            return
        }
        self.mic = mic
        startedAt = started
        phase = .recording
        startSystemAudio(id: id, startedAt: started, run: run)
        tasks.append(Task { [weak self] in await self?.meterLoop() })
        let transcriber = makeTranscriber(engine: engine)
        self.transcriber = transcriber
        resumeCursors = writers.map { _ in 0 }
        lastProgressArchive = Date()
        archiveProgress()
    }

    private func makeTranscriber(engine: MeetingEngine, cursors: [Int] = []) -> MeetingTranscriber {
        let fallback = DictationModelStore.shared.language.whisperCode ?? "fr"
        let streams = writers.enumerated().map { index, entry in
            MeetingTranscriber.Stream(speaker: entry.speaker, writer: entry.writer, cursor: index < cursors.count ? cursors[index] : 0)
        }
        return MeetingTranscriber(
            streams: streams, engine: engine == .apple ? .apple(language.appleLocale(fallback: fallback)) : .whisper,
            language: language.code, fallbackLanguage: fallback, vocabulary: vocabulary())
    }

    /// A device change the capture could not follow: say so, the recording so far is kept.
    private func captureLost(run: Int, _ message: String) {
        guard run == self.run, phase == .recording else { return }
        issue = .recording(message)
    }

    private func startSystemAudio(id: String, startedAt: Date, run: Int) {
        let tap = SystemAudioTap()
        tap.onFailure = { _ in
            Task { @MainActor in MeetingRecorder.shared.captureLost(run: run, String(localized: "The other participants' sound is no longer captured since the audio output changed.")) }
        }
        do {
            _ = try tap.prepare()
            let writer = try MeetingStreamWriter(url: MeetingFiles.audioDirectory.appending(path: "\(id)-eux.caf"), startedAt: startedAt)
            try tap.start { buffer in writer.append(buffer) }
            self.tap = tap
            writers.append((.them, writer))
            hasSystemAudio = true
        } catch {
            NSLog("Nuo meeting: system audio unavailable — %@", String(describing: error))
            tap.stop()
            issue = .systemAudio
        }
    }

    private func meterLoop() async {
        var ticks = 0
        while phase == .recording, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
            let me = writers.first { $0.speaker == .me }?.writer
            let them = writers.first { $0.speaker == .them }?.writer
            micLevel = me?.level ?? 0
            systemLevel = them?.level ?? 0
            ticks += 1
            if let failure = writers.lazy.compactMap(\.writer.failure).first {
                issue = .recording(String(localized: "Recording stopped: the disk refuses writes (\(failure.localizedDescription)). What was recorded is kept."))
                showWindow()
                await stop()
                return
            }
            // Also after a device switch: a working mic never delivers exact zeros for long.
            let silent = (me?.silentFor ?? 0) >= 15
            if silent, issue == nil { issue = .microphoneSilent }
            if issue == .microphoneSilent, !silent { issue = nil }
            // A denied permission gives a running tap that only delivers zeros.
            if ticks == 300, let them, !them.heardSignal, issue == nil { issue = .systemAudio }
            if issue == .systemAudio, them?.heardSignal == true { issue = nil }
            // A crash keeps the length, the notes and the title of the meeting as of the last save.
            if MeetingArchive.saveIsDue(last: lastProgressArchive, now: Date()) { archiveProgress() }
        }
    }

    func stop() async {
        guard isRecording else { return }
        if phase == .starting, session?.isDemo != true {
            // Still asking for the mic: nothing is recorded yet, and `start` must not go on.
            run += 1
            reset()
            return
        }
        let run = run
        endedAt = Date()
        tasks.forEach { $0.cancel() }
        tasks = []
        micLevel = 0
        systemLevel = 0
        if session?.isDemo == true {
            phase = .stopped
            playDemoTranscription()
            return
        }
        mic?.stop()
        tap?.stop()
        mic = nil
        tap = nil
        for (_, writer) in writers { writer.close() }
        phase = .stopped
        if issue == .microphoneSilent || issue == .systemAudio { issue = nil }
        archiveProgress()
        guard let transcriber else { return }
        transcribing = Task {
            guard run == self.run else { return }
            await finish(transcriber)
        }
    }

    /// Back to an empty meeting, ready for the next one.
    func discard() {
        guard !isRecording else { return }
        run += 1
        generation?.cancel()
        transcribing?.cancel()
        stopCloudJobs()
        discardAudio()
        MeetingFiles.removeArchive()
        reset()
    }

    private func discardAudio() {
        transcriber = nil
        hasRecording = false
        for (_, writer) in writers { writer.delete() }
        writers = []
        resumeCursors = []
        cloudJobs = [:]
        follower?.cancel()
        follower = nil
    }

    /// The gateway stops transcribing and deletes the audio it holds for this meeting.
    /// A stop the gateway could not hear (offline) is kept on disk and sent again when it answers.
    private func stopCloudJobs(only speaker: MeetingSpeaker? = nil) {
        let ids = speaker.map { cloudJobs[$0].map { [$0] } ?? [] } ?? Array(cloudJobs.values)
        guard !ids.isEmpty else { return }
        MeetingFiles.updatePendingDeletes { $0.add(ids) }
        sendPendingDeletes()
    }

    /// Sends the stops still owed to the gateway; those it heard leave the queue.
    func sendPendingDeletes() {
        guard let client = session?.api as? NuoClient, session?.isDemo != true else { return }
        let ids = MeetingFiles.readPendingDeletes().ids
        guard !ids.isEmpty else { return }
        Task.detached {
            for id in ids where await client.cancelTranscription(id) {
                MeetingFiles.updatePendingDeletes { $0.done(id) }
            }
        }
    }

    private func reset() {
        phase = .idle
        startedAt = nil
        endedAt = nil
        transcript = MeetingTranscript()
        transcription = .none
        issue = nil
        hasSystemAudio = false
        detectedLanguage = nil
        appleReady = false
        isRetranscribing = false
        transcribedInCloud = false
        title = ""
        participants = ""
        notes = ""
        eventId = nil
        proposedEventId = nil
        noteState = .none
        note = ""
        savedPath = nil
        saveError = nil
        actions = []
        remindersCreated = 0
    }

    // MARK: - Transcription

    /// The meeting was transcribed by Apple and its recording is still there.
    var canRetranscribe: Bool { recordingRules.canRetranscribe }
    var canDeleteRecording: Bool { recordingRules.canDelete }

    private var recordingRules: MeetingRecordingRules {
        MeetingRecordingRules(kept: hasRecording, engine: activeEngine, transcribed: phase == .stopped && transcription == .done,
                              noteReady: noteState == .ready, retranscribing: isRetranscribing)
    }

    func deleteRecording() {
        guard canDeleteRecording else { return }
        discardAudio()
    }

    /// Transcribes the whole recording again with Whisper, then deletes it.
    func retranscribeWithWhisper() {
        guard canRetranscribe else { return }
        transcribing?.cancel()
        activeEngine = .whisper
        isRetranscribing = true
        transcribedInCloud = false
        if session?.isDemo == true {
            playDemoTranscription()
            return
        }
        let transcriber = makeTranscriber(engine: .whisper)
        self.transcriber = transcriber
        transcribing = Task { await finish(transcriber) }
    }

    func retryTranscription() {
        guard phase == .stopped, let transcriber else { return }
        // The retry asks the gateway itself: a follower still asking would race it for the same jobs.
        follower?.cancel()
        follower = nil
        transcribing?.cancel()
        transcribing = Task { await finish(transcriber) }
    }

    /// Transcribes the whole meeting once it is over: the gateway's service first, the Mac's engine when it fails.
    /// Does nothing once `transcriber` is no longer this meeting's (a new one started, or it was discarded).
    private func finish(_ transcriber: MeetingTranscriber) async {
        if useCloud, !isRetranscribing, await finishInCloud(transcriber) { return }
        await finishOnMac(transcriber)
    }

    /// True once the transcript is in. False when the cloud cannot do it, and the Mac takes over.
    private func finishInCloud(_ transcriber: MeetingTranscriber) async -> Bool {
        var current: Bool { self.transcriber === transcriber && !Task.isCancelled }
        guard let client = session?.api as? NuoClient else { return false }
        follower?.cancel()
        follower = nil
        sendPendingDeletes()
        // Named only when the cloud is used, and saved at once (below): a retry or a restart asks for these jobs first. An
        // id still waiting to be stopped on the gateway is never reused.
        let stopping = Set(MeetingFiles.readPendingDeletes().ids)
        for (speaker, id) in cloudJobs where stopping.contains(id) { cloudJobs[speaker] = nil }
        for (speaker, _) in writers where cloudJobs[speaker] == nil { cloudJobs[speaker] = UUID().uuidString.lowercased() }
        // Saved at once: a quit or a crash from here on finds these jobs again instead of paying for them twice.
        archiveProgress()
        let streams = writers.map {
            MeetingCloud.Stream(speaker: $0.speaker, url: $0.writer.url, startOffset: $0.writer.startOffset ?? 0, jobID: cloudJobs[$0.speaker]!)
        }
        let request = cloudRequest()
        transcription = .finishing(progress: 0, remaining: nil)
        macRequested = false
        let work = Task { [weak self] in
            try await MeetingCloud.transcribe(streams, request: request, client: client) { progress in
                guard let self, self.transcriber === transcriber, case .finishing = self.transcription else { return }
                self.transcription = .finishing(progress: progress, remaining: nil)
            }
        }
        cloudWait = work
        isWaitingForCloud = true
        defer {
            // A newer wait may have started meanwhile (a retry): it keeps its own state.
            if cloudWait == work {
                isWaitingForCloud = false
                cloudWait = nil
            }
        }
        do {
            let result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            guard current else { return true }
            // Switched off while the gateway worked: the Mac does it, and the gateway's transcript is not used.
            guard useCloud else {
                stopCloudJobs()
                cloudJobs = [:]
                archiveProgress()
                return false
            }
            adopt(result)
            return true
        } catch {
            // A quit or a new meeting: the jobs stay on the gateway, to be found again.
            guard current else { return true }
            if macRequested || error is TranscriptionJob.Unreachable {
                // The gateway may still answer: its jobs go on while the Mac transcribes too, and the first to finish wins.
                NSLog("Nuo meeting: no answer from the gateway, transcribing on the Mac meanwhile")
                follow(streams, request: request, client: client, while: transcriber)
                return false
            }
            NSLog("Nuo meeting: cloud transcription failed, transcribing on the Mac — %@", String(describing: error))
            follower?.cancel()
            follower = nil
            forget(MeetingCloudLoss.of(error))
            return false
        }
    }

    /// Stops what an error cost on the gateway, and names it anew for the next try; a job that may still be good (one
    /// finished, a cancel, a file the Mac could not read) is kept to be found again, never paid twice.
    private func forget(_ loss: MeetingCloudLoss) {
        switch loss {
        case .none:
            return
        case let .stream(speaker):
            stopCloudJobs(only: speaker)
            cloudJobs[speaker] = nil
        case .all:
            stopCloudJobs()
            cloudJobs = [:]
        }
        // The archive must not keep ids a next try would only find failed.
        archiveProgress()
    }

    private func cloudRequest() -> MeetingCloud.Request {
        MeetingCloud.Request(
            language: language.code,
            terms: DictationTerms.unique(MeetingVoices.terms(title: title, participants: participants) + DictationVocabulary.terms(extra: []), limit: 100),
            voices: MeetingVoices.plan(participants: participants))
    }

    /// The cloud's transcript, with the voices told apart, replaces whatever the Mac had begun.
    private func adopt(_ result: MeetingCloud.Result) {
        transcript = result.transcript
        detectedLanguage = result.language
        transcribedInCloud = true
        NSLog("Nuo meeting: transcribed in the cloud, %d words for %.0f min", transcript.wordCount, elapsed(at: Date()) / 60)
        transcription = .done
        // Saved before the audio goes: a crash in between still has the transcript.
        archive()
        discardAudio()
        if canGenerate, let bots, defaultBot(in: bots.bots) != nil, noteState == .none { generate() }
    }

    /// « Transcrire sur le Mac maintenant »: stops waiting for the gateway, which keeps its jobs.
    func transcribeOnMacNow() {
        guard isWaitingForCloud else { return }
        macRequested = true
        cloudWait?.cancel()
    }

    /// Asks the gateway again every half minute while the Mac transcribes. If the cloud's transcript comes first, it
    /// replaces the Mac's work; if the Mac finishes first, its transcript stays and the gateway's jobs are stopped.
    private func follow(_ streams: [MeetingCloud.Stream], request: MeetingCloud.Request, client: NuoClient, while transcriber: MeetingTranscriber) {
        let run = self.run
        follower?.cancel()
        follower = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, run == self.run, !Task.isCancelled, self.useCloud, self.transcriber === transcriber, self.transcription != .done else { return }
                do {
                    // Asked first: the audio is prepared again only once the gateway has finished (or lost) the jobs.
                    guard try await MeetingCloud.settled(streams, client: client) else { continue }
                    guard run == self.run, self.useCloud, self.transcriber === transcriber, self.transcription != .done else { return }
                    let result = try await MeetingCloud.transcribe(streams, request: request, client: client) { _ in }
                    guard run == self.run, self.useCloud, self.transcriber === transcriber, self.transcription != .done else { return }
                    // The Mac's pass is stopped before the cloud's transcript lands: it no longer owns the meeting.
                    self.transcribing?.cancel()
                    self.transcriber = nil
                    self.adopt(result)
                    return
                } catch is TranscriptionJob.Unreachable {
                    // The network or the gateway is still away: ask again later.
                    continue
                } catch let error where TranscriptionPolling.keepsRacing(error) {
                    continue
                } catch is CancellationError {
                    // « Réessayer » or a new meeting took over: the jobs are theirs now.
                    return
                } catch {
                    // A job failed there, or the gateway has no provider: the Mac's transcript will be the one, and the
                    // next try names those jobs anew. Anything else (a file the Mac could not read) leaves the jobs.
                    guard run == self.run, !Task.isCancelled, self.transcriber === transcriber else { return }
                    self.forget(MeetingCloudLoss.of(error))
                    return
                }
            }
        }
    }

    private func finishOnMac(_ transcriber: MeetingTranscriber) async {
        var current: Bool { self.transcriber === transcriber && !Task.isCancelled }
        let usesWhisper = activeEngine == .whisper
        if usesWhisper { await WhisperEngine.shared.hold() }
        defer { if usesWhisper { Task { await WhisperEngine.shared.release() } } }
        // Every await may hand the meeting over (the cloud answered first, a new meeting): nothing is written then.
        guard current, await prepareEngine(transcriber, owns: { current }), current else { return }
        let total = await transcriber.backlog
        guard current else { return }
        let began = Date()
        var fresh = MeetingTranscript()
        transcription = .finishing(progress: 0, remaining: nil)
        do {
            while let chunk = try await transcriber.next() {
                try Task.checkCancellation()
                let language = await transcriber.language
                guard current else { return }
                if isRetranscribing {
                    for line in chunk.lines { fresh.insert(line.text, speaker: line.speaker, start: line.start, end: line.end, language: language) }
                } else {
                    add(chunk.lines, language: language)
                    resumeCursors = chunk.cursors
                    if Date().timeIntervalSince(lastProgressArchive) >= 30 { archiveProgress() }
                }
                let left = await transcriber.backlog
                guard current else { return }
                let progress = total > 0 ? 1 - Double(left) / Double(total) : 1
                let spent = Date().timeIntervalSince(began)
                transcription = .finishing(progress: progress, remaining: progress > 0.05 ? spent / progress * (1 - progress) : nil)
            }
        } catch is CancellationError {
            return
        } catch {
            guard current else { return }
            NSLog("Nuo meeting: transcription failed — %@", String(describing: error))
            transcription = .failed(error is MeetingDeadline.TimedOut
                ? String(localized: "Transcription isn't responding. Try again; what is already transcribed is kept.")
                : String(localized: "Transcription failed. Try again."))
            archiveProgress()
            return
        }
        let heard = await transcriber.language
        guard current else { return }
        detectedLanguage = heard
        if isRetranscribing {
            transcript = fresh
            isRetranscribing = false
        }
        if follower != nil {
            // The Mac finished first: the gateway's jobs are no longer needed.
            follower?.cancel()
            follower = nil
            stopCloudJobs()
            cloudJobs = [:]
        }
        if activeEngine.keepsAudio { hasRecording = true } else { discardAudio() }
        transcription = .done
        archive()
        if canGenerate, let bots, defaultBot(in: bots.bots) != nil, noteState == .none { generate() }
    }

    private func add(_ lines: [MeetingTranscriber.Line], language: String?) {
        for line in lines { transcript.insert(line.text, speaker: line.speaker, start: line.start, end: line.end, language: language) }
    }

    /// Readies the meeting's engine; false (and the reason shown) when it cannot be. `owns` says whether this pass still
    /// speaks for the meeting: it says nothing once it no longer does.
    private func prepareEngine(_ transcriber: MeetingTranscriber, owns: () -> Bool) async -> Bool {
        guard activeEngine == .apple else { return await loadModel(owns: owns) }
        if appleReady { return true }
        transcription = .preparing
        do {
            let fallback = DictationModelStore.shared.language.whisperCode ?? "fr"
            await transcriber.useApple(try await AppleFileTranscriber.prepare(language.appleLocale(fallback: fallback)))
            guard owns() else { return false }
            appleReady = true
            return true
        } catch {
            guard owns() else { return false }
            NSLog("Nuo meeting: Apple recognizer unavailable — %@", String(describing: error))
            transcription = .failed((error as? LocalizedError)?.errorDescription ?? String(localized: "Apple speech recognition isn't available."))
            return false
        }
    }

    /// The accurate model when it is there, the fast one if only it is, otherwise the accurate one is downloaded;
    /// then loaded. False (and the reason shown) when it cannot be.
    private func loadModel(owns: () -> Bool) async -> Bool {
        guard let model = await readyModel(owns: owns), owns(), let folder = DictationModelStore.shared.readyFolder(model) else { return false }
        let ready = await WhisperEngine.shared.isReady(model)
        guard owns() else { return false }
        if ready { return true }
        transcription = .preparing
        do {
            try await WhisperEngine.shared.load(model, folder: folder, holding: true)
            return owns()
        } catch {
            guard owns() else { return false }
            transcription = .failed(String(localized: "The Whisper model couldn't be loaded."))
            return false
        }
    }

    private func readyModel(owns: () -> Bool) async -> WhisperModel? {
        let store = DictationModelStore.shared
        if store.readyFolder(.turbo) != nil { return .turbo }
        if store.readyFolder(.small) != nil { return .small }
        if store.state(.turbo) != .preparing, !store.state(.turbo).isDownloading { store.download(.turbo) }
        while !Task.isCancelled, owns() {
            switch store.state(.turbo) {
            case let .downloading(progress): transcription = .downloading(progress)
            case .preparing: transcription = .preparing
            case .ready: return .turbo
            case let .failed(message):
                transcription = .failed(message)
                return nil
            case .absent:
                transcription = .failed(String(localized: "The transcription model couldn't be downloaded."))
                return nil
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
        return nil
    }

    /// Spelling of the names Whisper would otherwise write phonetically.
    private func vocabulary() -> String {
        let names = [title, participants].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let known = DictationVocabulary.prompt(extra: [])
        return (names.map { $0.hasSuffix(".") ? $0 : $0 + "." } + (known.isEmpty ? [] : [known])).joined(separator: " ")
    }

    // MARK: - Note

    func defaultBot(in bots: [Bot]) -> Bot? {
        if let botId, let bot = bots.first(where: { $0.id == botId }) { return bot }
        return NoteBotChoice.defaultBot(in: bots)
    }

    func generate() {
        guard canGenerate, let startedAt else { return }
        guard let session, let bots else {
            noteState = .failed(String(localized: "Nuo isn't connected to your gateway yet. Try again in a moment."))
            return
        }
        guard let bot = defaultBot(in: bots.bots) else {
            noteState = .failed(String(localized: "No bot available to write the summary."))
            return
        }
        noteState = .generating
        note = ""
        savedPath = nil
        saveError = nil
        actions = []
        archive()
        let prompt = MeetingPrompt.build(
            title: title, participants: participants, startedAt: startedAt, duration: elapsed, notes: notes,
            transcript: transcript, template: template, userName: session.userName)
        generation = Task {
            let text: String
            if session.isDemo {
                try? await Task.sleep(for: .seconds(2))
                text = MeetingDemo.note
            } else {
                do {
                    text = try await Self.ask(bot: bot, prompt: prompt, session: session, bots: bots) { partial in
                        self.note = partial
                    }
                } catch is CancellationError {
                    return
                } catch {
                    noteState = .failed(Self.describe(error))
                    return
                }
            }
            guard !Task.isCancelled else { return }
            note = Self.stripFence(text)
            actions = MeetingAction.parse(note)
            noteState = .ready
            await save()
            archive()
        }
    }

    /// The transcript and the notes are kept: the note can be generated again once the gateway answers.
    private static func describe(_ error: Error) -> String {
        if case NuoError.offline = error {
            return String(localized: "Gateway unreachable. The transcript and your notes are kept: try “Regenerate” again once the gateway answers.")
        }
        if case let MeetingError.bot(message) = error, message == NuoError.offline.errorDescription {
            return describe(NuoError.offline)
        }
        return error.localizedDescription
    }

    /// Runs one turn in a new conversation of the bot, through the same client and socket as the chat (home or
    /// internet route, with the Cloudflare Access headers).
    private static func ask(bot: Bot, prompt: String, session: SessionStore, bots: BotsStore,
                            progress: @escaping @MainActor (String) -> Void) async throws -> String {
        let store = ConversationStore(bot: bot, conversationId: nil, useDraft: false, session: session, bots: bots)
        store.start()
        defer { store.stop() }
        store.send(prompt: prompt)
        var sawRun = false
        let deadline = Date().addingTimeInterval(20 * 60)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(300))
            let answer = store.messages.last { $0.role == .assistant }
            if let answer { progress(answer.text) }
            if store.isRunning { sawRun = true; continue }
            if let error = store.errorMessage { throw MeetingError.bot(error) }
            if sawRun || answer != nil {
                // The live text can miss the last deltas: the persisted message has the whole note.
                await store.reload()
                guard let final = store.messages.last(where: { $0.role == .assistant })?.text, !final.isEmpty else {
                    throw MeetingError.bot(String(localized: "The bot didn't answer."))
                }
                return final
            }
        }
        throw MeetingError.bot(String(localized: "The bot is taking too long to answer."))
    }

    private static func stripFence(_ text: String) -> String {
        var lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        if lines.first?.hasPrefix("```") == true, lines.last?.hasPrefix("```") == true, lines.count > 2 {
            lines.removeFirst()
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    /// `reunions/YYYY-MM-DD-<slug>.md` in the profile's docs; a suffix avoids overwriting a namesake.
    func save() async {
        guard let session, !note.isEmpty, let startedAt else { return }
        saveError = nil
        let heading = note.components(separatedBy: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) }
        let base = "reunions/\(MeetingFormat.day(startedAt))-\(MeetingFormat.slug(heading ?? (title.isEmpty ? "reunion" : title)))"
        for attempt in 1...5 {
            let path = attempt == 1 ? "\(base).md" : "\(base)-\(attempt).md"
            do {
                let result = try await session.api.createDoc(path: path, content: note + "\n")
                savedPath = result.path
                await FilesHomeStore.shared.load()
                archive()
                return
            } catch NuoError.server(status: 409, _) {
                continue
            } catch {
                saveError = Self.describe(error)
                return
            }
        }
        saveError = String(localized: "A document with the same name already exists.")
    }

    func createReminders() async {
        let chosen = actions.filter(\.selected)
        var created = 0
        for action in chosen {
            var notes = String(localized: "Meeting: \(title.isEmpty ? String(localized: "untitled") : title)")
            if let owner = action.owner { notes += "\n" + String(localized: "Owner: \(owner)") }
            if let savedPath { notes += "\nnuo://docs/\(savedPath)" }
            if await RemindersStore.shared.create(ReminderDraft(title: action.title, notes: notes, dueAt: action.due)) != nil { created += 1 }
        }
        remindersCreated += created
        actions.removeAll { $0.selected }
    }

    // MARK: - Last meeting

    /// Keeps the finished meeting (text only) across launches, so the note can still be generated later.
    func archive() {
        guard phase == .stopped, transcription == .done, let startedAt, let endedAt else { return }
        MeetingFiles.writeArchive(MeetingArchive(
            title: title, participants: participants, notes: notes, eventId: eventId, startedAt: startedAt, endedAt: endedAt,
            transcript: transcript, note: noteState == .ready ? note : nil, savedPath: savedPath, transcribedInCloud: transcribedInCloud))
    }

    /// Keeps the meeting under way or not fully transcribed: its transcript so far, and where its audio is to finish it
    /// after a quit or a crash.
    private func archiveProgress() {
        guard let startedAt, !writers.isEmpty, !isRetranscribing, transcription != .done else { return }
        lastProgressArchive = Date()
        let streams = writers.enumerated().map { index, entry in
            MeetingResume.Stream(speaker: entry.speaker, file: entry.writer.url.lastPathComponent, startOffset: entry.writer.startOffset,
                                 cursor: index < resumeCursors.count ? resumeCursors[index] : 0, jobID: cloudJobs[entry.speaker])
        }
        MeetingFiles.writeArchive(MeetingArchive.inProgress(
            title: title, participants: participants, notes: notes, eventId: eventId, startedAt: startedAt, endedAt: endedAt, now: Date(),
            transcript: transcript, resume: MeetingResume(engine: activeEngine, streams: streams)))
    }

    /// ⌘Q: the recording is stopped and closed, and what is not transcribed yet is kept to finish at the next launch.
    func flushForQuit() async {
        if phase == .starting {
            await stop()
            return
        }
        if phase == .recording { await stop() }
        guard phase == .stopped, transcription != .done, !isRetranscribing, session?.isDemo != true else { return }
        run += 1
        transcribing?.cancel()
        archiveProgress()
    }

    private func restore(_ archive: MeetingArchive?) {
        guard let archive else { return }
        title = archive.title
        participants = archive.participants
        notes = archive.notes
        eventId = archive.eventId
        startedAt = archive.startedAt
        endedAt = archive.endedAt
        transcript = archive.transcript
        transcribedInCloud = archive.transcribedInCloud ?? false
        transcription = .done
        if let note = archive.note {
            self.note = note
            noteState = .ready
            actions = MeetingAction.parse(note)
        }
        savedPath = archive.savedPath
        phase = .stopped
        guard let resume = archive.resume else { return }
        let streams = resume.available(in: MeetingFiles.audioDirectory)
        // The audio is gone: the transcript so far is all there is.
        guard !streams.isEmpty else { return }
        activeEngine = resume.engine
        writers = streams.map {
            ($0.speaker, MeetingStreamWriter(recorded: MeetingFiles.audioDirectory.appending(path: $0.file), startedAt: archive.startedAt,
                                             startOffset: $0.startOffset))
        }
        hasSystemAudio = streams.contains { $0.speaker == .them }
        resumeCursors = streams.map(\.cursor)
        cloudJobs = Dictionary(streams.compactMap { stream in stream.jobID.map { (stream.speaker, $0) } }, uniquingKeysWith: { first, _ in first })
        transcriber = makeTranscriber(engine: resume.engine, cursors: resumeCursors)
        transcription = .failed(String(localized: "Nuo closed before the transcription finished. Try again to complete it: the audio was kept."))
    }

    // MARK: - Helpers

    private static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVAudioApplication.requestRecordPermission()
        default: return false
        }
    }

    /// The timed event under way (or starting within 5 min), video calls first.
    static func currentEvent(now: Date = Date()) -> AgendaItem? {
        let candidates = CalendarStore.shared.items.filter {
            $0.kind == .event && !$0.allDay && !$0.isCancelled && !$0.isBusyOnly
                && $0.start <= now.addingTimeInterval(5 * 60) && $0.end > now
        }
        return candidates.first { $0.conference != nil } ?? candidates.min { abs($0.start.timeIntervalSince(now)) < abs($1.start.timeIntervalSince(now)) }
    }

    static func participants(of item: AgendaItem) -> String {
        var names = (item.attendees ?? []).filter { $0.status != "declined" }.map(\.display)
        if let organizer = item.organizer?.display, !names.contains(organizer) { names.insert(organizer, at: 0) }
        return names.joined(separator: ", ")
    }

    // MARK: - Demo

    private func playDemo() {
        startedAt = Date().addingTimeInterval(-14 * 60 - 32)
        if title.isEmpty { title = String(localized: "Nuo weekly sync") }
        if participants.isEmpty { participants = "Léa Martin, Hugo Bernard" }
        notes = MeetingDemo.notes
        hasSystemAudio = true
        phase = .recording
        tasks.append(Task { [weak self] in
            var tick = 0
            while let self, self.phase == .recording, !Task.isCancelled {
                tick += 1
                self.micLevel = Float(0.3 + 0.25 * sin(Double(tick) * 0.9))
                self.systemLevel = Float(0.45 + 0.3 * sin(Double(tick) * 0.6 + 1))
                try? await Task.sleep(for: .milliseconds(120))
            }
        })
    }

    private func playDemoTranscription(holdAt progress: Double? = nil) {
        transcribing = Task {
            for step in 1...10 {
                transcription = .finishing(progress: Double(step) / 10, remaining: Double(10 - step) * 3)
                if let progress, Double(step) / 10 >= progress { return }
                try? await Task.sleep(for: .milliseconds(150))
            }
            if transcript.isEmpty || isRetranscribing {
                var demo = MeetingTranscript()
                for line in MeetingDemo.transcript {
                    demo.insert(line.text, speaker: line.speaker, start: line.start, end: line.start + 6, voice: line.voice)
                }
                transcript = demo
            }
            detectedLanguage = "fr"
            transcribedInCloud = activeEngine == .whisper && useCloud
            isRetranscribing = false
            hasRecording = !transcribedInCloud && activeEngine.keepsAudio
            transcription = .done
            if noteState == .none { generate() }
        }
    }

    /// `-demoScreen meeting` (recording), `meetingfinishing`, `meetingnote` (finished, with its note), `meetingapple`
    /// (the same, transcribed by Apple) or `meetingidle`.
    func applyDemo() {
        guard !demoApplied, let screen = DemoDirector.screen, screen.hasPrefix("meeting") else { return }
        demoApplied = true
        Task {
            if screen == "meetingidle" {
                showWindow()
                return
            }
            await start(event: nil)
            showWindow()
            guard screen != "meeting" else { return }
            endedAt = Date()
            tasks.forEach { $0.cancel() }
            tasks = []
            micLevel = 0
            systemLevel = 0
            phase = .stopped
            if screen == "meetingapple" { activeEngine = .apple }
            playDemoTranscription(holdAt: screen == "meetingfinishing" ? 0.6 : nil)
        }
    }
}

enum MeetingError: LocalizedError {
    case bot(String)

    var errorDescription: String? {
        switch self {
        case let .bot(message): message
        }
    }
}

enum MeetingFiles {
    /// Temporary recordings, never backed up; deleted after transcription, or at the next meeting or launch when kept
    /// for a Whisper retranscription. A meeting whose transcription a quit interrupted keeps them until it is finished.
    static var audioDirectory: URL { URL.cachesDirectory.appending(path: "Meetings", directoryHint: .isDirectory) }
    private static var archiveURL: URL { URL.applicationSupportDirectory.appending(path: "Meetings/last-meeting.json") }

    static func writeArchive(_ archive: MeetingArchive) {
        do {
            try FileManager.default.createDirectory(at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try NuoJSON.encoder().encode(archive).write(to: archiveURL, options: [.atomic, .completeFileProtection])
        } catch {
            NSLog("Nuo meeting: archive not written — %@", String(describing: error))
        }
    }

    static func readArchive() -> MeetingArchive? {
        guard let data = try? Data(contentsOf: archiveURL) else { return nil }
        return try? NuoJSON.decoder().decode(MeetingArchive.self, from: data)
    }

    static func removeArchive() {
        try? FileManager.default.removeItem(at: archiveURL)
    }

    private static var pendingDeletesURL: URL { URL.applicationSupportDirectory.appending(path: "Meetings/pending-deletes.json") }
    private static let pendingLock = NSLock()

    static func readPendingDeletes() -> MeetingPendingDeletes {
        pendingLock.withLock {
            (try? Data(contentsOf: pendingDeletesURL)).flatMap { try? JSONDecoder().decode(MeetingPendingDeletes.self, from: $0) } ?? MeetingPendingDeletes()
        }
    }

    static func updatePendingDeletes(_ change: (inout MeetingPendingDeletes) -> Void) {
        pendingLock.withLock {
            var queue = (try? Data(contentsOf: pendingDeletesURL)).flatMap { try? JSONDecoder().decode(MeetingPendingDeletes.self, from: $0) } ?? MeetingPendingDeletes()
            change(&queue)
            do {
                try FileManager.default.createDirectory(at: pendingDeletesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(queue).write(to: pendingDeletesURL, options: [.atomic, .completeFileProtection])
            } catch {
                NSLog("Nuo meeting: pending deletes not written — %@", String(describing: error))
            }
        }
    }

    static func removeAudio(keeping resume: MeetingResume?) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: audioDirectory.path)) ?? []
        for file in MeetingResume.orphans(files, keeping: resume) {
            try? FileManager.default.removeItem(at: audioDirectory.appending(path: file))
        }
    }
}
