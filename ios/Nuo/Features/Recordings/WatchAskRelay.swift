import Foundation
import UIKit
import WatchConnectivity

/// Spoken requests from the watch: transcribed once on the gateway with the app's access, sent to the bot they name
/// (the general one by default), and kept on the iPhone until the gateway takes them when it is away.
@MainActor
enum WatchAskRelay {
    struct Envelope: Codable, Equatable {
        var askId: String
        var botId: String?
        var conversationId: String?
        var preferredBotId: String?
        var seconds: Double
        /// Typed on the watch, or transcribed already: never transcribed (nor paid) twice.
        var text: String?
        /// The recording in the inbox folder, for a spoken request.
        var audioFile: String?
        var createdAt: Date
        /// The watch was told the iPhone keeps it (and why), once.
        var queuedReason: String?
        /// Its conversation was opened by the relay (the app's conversations are out of the relay's reach).
        var viaRelay: Bool?
        /// The relay could not do all of it (it can only add): the rest goes through the app at the unlock.
        var waitsForUnlock: Bool?

        init(askId: String, botId: String?, conversationId: String?, preferredBotId: String?, seconds: Double, text: String?,
             audioFile: String?, createdAt: Date) {
            self.askId = askId
            self.botId = botId
            self.conversationId = conversationId
            self.preferredBotId = preferredBotId
            self.seconds = seconds
            self.text = text
            self.audioFile = audioFile
            self.createdAt = createdAt
        }

        /// Nil unless the id is a UUID: it names a file.
        init?(_ payload: [String: Any], audioFile: String?) {
            guard let askId = Self.validId(payload[RecordingLink.askId]) else { return nil }
            self.init(askId: askId, botId: payload[RecordingLink.botId] as? String,
                      conversationId: payload[RecordingLink.conversationId] as? String,
                      preferredBotId: payload[RecordingLink.preferredBotId] as? String,
                      seconds: payload[RecordingLink.seconds] as? Double ?? 0, text: payload[RecordingLink.text] as? String,
                      audioFile: audioFile,
                      createdAt: (payload[RecordingLink.createdAt] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date())
        }

        nonisolated static func validId(_ value: Any?) -> String? {
            guard let id = value as? String, UUID(uuidString: id) != nil else { return nil }
            return id.lowercased()
        }
    }

    struct Outcome: Codable, Equatable {
        var conversationId: String
        var botId: String
        var text: String
    }

    enum Failure: Error, Equatable {
        /// The gateway does not answer: kept and sent later.
        case unreachable
        /// Nothing to send (no speech, no bot, a request the gateway refuses): the watch is told, it is not sent again.
        case refused(String)
        /// The iPhone is locked: its key cannot sign. Kept until the unlock, never refused for it.
        case locked
        /// Locked, and beyond what the relay may do (it only adds): kept until the unlock.
        case outOfScope
        /// Locked, and the relay's hourly limit is reached: kept until the unlock.
        case relayLimit
    }

    static var folder: URL { RecordingInbox.asksFolder }

    private static var inboxURL: URL { folder.appending(path: "inbox.json") }
    private static let doneKey = AppIdentity.local(.watchAskRecent)
    private static var running: Set<String> = []
    private static var retrying = false
    /// A request came during a pass: one more pass when it ends.
    private static var retryAgain = false

    /// Why the iPhone keeps a request, as the watch words it.
    enum KeptReason: String {
        case locked, gatewayDown
        case outOfScope = "scope"
        case relayLimit

        init(_ failure: Failure?) {
            switch failure {
            case .locked: self = .locked
            case .outOfScope: self = .outOfScope
            case .relayLimit: self = .relayLimit
            default: self = .gatewayDown
            }
        }
    }

    // MARK: - Entry points

    /// A request the watch sends live: the reply tells it where the answer lands, that the iPhone keeps it, or why
    /// it cannot be sent.
    static func handleLive(_ message: [String: Any]) async -> [String: Any] {
        guard let id = Envelope.validId(message[RecordingLink.askId]) else { return [RecordingLink.ok: false] }
        var audioFile: String?
        if let audio = message[RecordingLink.audio] as? Data {
            audioFile = "\(id).m4a"
            try? audio.write(to: folder.appending(path: "\(id).m4a"))
        }
        guard let envelope = Envelope(message, audioFile: audioFile) else { return [RecordingLink.ok: false] }
        let window = backgroundWindow()
        defer { window() }
        do {
            let outcome = try await process(envelope)
            // Also through the system's queue: the live reply can be lost, and the watch would wait ten minutes.
            acknowledge(envelope.askId, outcome: outcome)
            return [RecordingLink.ok: true, RecordingLink.conversationId: outcome.conversationId, RecordingLink.botId: outcome.botId,
                    RecordingLink.text: outcome.text]
        } catch Failure.refused(let reason) {
            drop(envelope)
            return [RecordingLink.ok: false, RecordingLink.error: reason]
        } catch let failure as Failure where [.locked, .outOfScope, .relayLimit].contains(failure) {
            keep(envelope)
            return [RecordingLink.ok: false, RecordingLink.queued: true, RecordingLink.locked: true, RecordingLink.reason: KeptReason(failure).rawValue]
        } catch {
            keep(envelope)
            return [RecordingLink.ok: false, RecordingLink.queued: true, RecordingLink.reason: KeptReason.gatewayDown.rawValue]
        }
    }

    /// A request that came through the system's queue (the watch was out of reach): processed now or kept. A copy
    /// of one already sent or already turned into text only loses its audio, and the watch hears again where it went.
    static func handleQueued(_ envelope: Envelope) {
        if let outcome = recent().value(for: envelope.askId) {
            cleanUp(envelope)
            acknowledge(envelope.askId, outcome: outcome)
            return
        }
        if let kept = inbox().first(where: { $0.askId == envelope.askId }), kept.text != nil {
            if envelope.audioFile != kept.audioFile { cleanUp(envelope) }
        } else {
            keep(envelope)
        }
        Task { await retry() }
    }

    /// Sends what the gateway could not take earlier: at launch, back in front, at the unlock, when a request
    /// arrives; one pass at a time, each request read again from disk before it goes. A request older than six
    /// hours is not sent to the bot any more: it is turned into text first, and the watch gets that text with the
    /// reason, so nothing said is ever lost.
    static func retry(now: Date = Date()) async {
        guard !retrying else {
            retryAgain = true
            return
        }
        retrying = true
        defer { retrying = false }
        let window = backgroundWindow()
        defer { window() }
        repeat {
            retryAgain = false
            await pass(now: now)
        } while retryAgain
    }

    private static func pass(now: Date) async {
        for id in inbox().map(\.askId) where !running.contains(id) {
            guard let envelope = inbox().first(where: { $0.askId == id }) else { continue }
            if AskExpiry.isExpired(createdAt: envelope.createdAt, now: now), recent().value(for: id) == nil {
                await expire(envelope)
                continue
            }
            do {
                let outcome = try await process(envelope)
                acknowledge(id, outcome: outcome)
            } catch Failure.refused(let reason) {
                drop(envelope)
                acknowledgeFailure(id, reason: reason, text: inbox().first { $0.askId == id }?.text ?? envelope.text)
            } catch {
                notifyKept(id, reason: KeptReason(error as? Failure))
                continue
            }
        }
    }

    /// The watch hears that the iPhone keeps its request and why, once per reason: it stops saying « en route ».
    private static func notifyKept(_ id: String, reason: KeptReason) {
        guard var envelope = inbox().first(where: { $0.askId == id }), envelope.queuedReason != reason.rawValue else { return }
        envelope.queuedReason = reason.rawValue
        upsert(envelope)
        transfer([RecordingLink.kind: RecordingLink.askAck, RecordingLink.askId: id, RecordingLink.queued: true, RecordingLink.reason: reason.rawValue])
    }

    /// Too old to send: its text goes back to the watch; without text yet, it waits until it can be transcribed.
    private static func expire(_ envelope: Envelope) async {
        var text = envelope.text
        if text == nil, case let .ready(client) = AppAccess.state() {
            do {
                text = try await transcribe(envelope, client: client, bots: (try? await client.bots()) ?? [])
            } catch Failure.refused(let reason) {
                // Nothing can turn it into text any more: the watch is told why and it goes.
                drop(envelope)
                acknowledgeFailure(envelope.askId, reason: reason, text: nil)
                return
            } catch {
                return
            }
        }
        guard let text else { return }
        drop(envelope)
        acknowledgeFailure(envelope.askId, reason: AskExpiry.message, text: text)
    }

    // MARK: - Processing

    static func process(_ envelope: Envelope) async throws -> Outcome {
        // A request the relay could not finish was answered once already: it goes again, through the app.
        let waits = (inbox().first { $0.askId == envelope.askId } ?? envelope).waitsForUnlock == true
        if !waits, let done = recent().value(for: envelope.askId) { return done }
        running.insert(envelope.askId)
        defer { running.remove(envelope.askId) }
        let client: NuoClient
        switch AppAccess.state() {
        case let .ready(ready): client = ready
        case .locked:
            if waits { throw Failure.outOfScope }
            // The app's own access cannot sign: the relay, when this iPhone has one, passes the request on.
            guard RelayClient.isAvailable else { throw Failure.locked }
            return try await processViaRelay(envelope)
        case .unpaired: throw Failure.refused(String(localized: "iPhone not paired with the gateway."))
        }
        do {
            return try await processWithApp(envelope, client: client)
        } catch Failure.locked where RelayClient.isAvailable && !waits {
            // Signed out by the lock halfway (a token that expired): the relay takes over from where it stopped.
            return try await processViaRelay(envelope)
        }
    }

    /// The relay ended a request with a tool it may not use: kept, and sent again through the app at the unlock, in
    /// the same conversation (the bot has what it already did); the watch hears why it waits.
    static func waitForUnlock(askId: String, conversationId: String, botId: String, text: String) {
        var envelope = inbox().first { $0.askId == askId }
            ?? Envelope(askId: askId, botId: botId, conversationId: conversationId, preferredBotId: nil, seconds: 0, text: text, audioFile: nil, createdAt: Date())
        envelope.conversationId = conversationId
        envelope.botId = botId
        envelope.text = text
        envelope.viaRelay = true
        envelope.waitsForUnlock = true
        envelope.queuedReason = nil
        upsert(envelope)
        notifyKept(askId, reason: .outOfScope)
    }

    private static func processWithApp(_ envelope: Envelope, client: NuoClient) async throws -> Outcome {
        let bots: [Bot]
        do {
            bots = try await client.bots().filter { $0.published != nil }
        } catch {
            if AppAccess.isLockFailure(error) { throw Failure.locked }
            throw (error as? NuoError).map(classify) ?? Failure.unreachable
        }
        var current = inbox().first { $0.askId == envelope.askId } ?? envelope
        if current.waitsForUnlock == true, let conversationId = current.conversationId, let botId = current.botId {
            if let failure = await WatchPromptRelay.send(conversationId: conversationId, text: RelayScope.unlockFollowUp) {
                NSLog("Nuo watch ask: follow-up not sent: %@", failure)
                throw Failure.unreachable
            }
            let outcome = Outcome(conversationId: conversationId, botId: botId, text: current.text ?? RelayScope.unlockFollowUp)
            var done = recent()
            done.insert(envelope.askId, outcome)
            UserDefaults.standard.set(try? JSONEncoder().encode(done), forKey: doneKey)
            drop(envelope)
            return outcome
        }
        let spoken: String
        if let text = current.text {
            spoken = text
        } else {
            spoken = try await transcribe(current, client: client, bots: bots)
            // Kept with the request: a later attempt sends it without paying the transcription again.
            let audio = current
            current.text = spoken
            current.audioFile = nil
            upsert(current)
            cleanUp(audio)
        }
        guard !spoken.isEmpty else { throw Failure.refused(String(localized: "I didn't hear anything.")) }
        guard let choice = AskTarget.resolve(text: spoken, bots: bots, explicitBotId: envelope.botId, preferredBotId: envelope.preferredBotId)
        else { throw Failure.refused(String(localized: "No published bot to answer.")) }
        let conversationId: String
        if let existing = current.conversationId {
            conversationId = existing
        } else {
            do {
                conversationId = try await client.createConversation(botId: choice.botId, useDraft: false).id
            } catch {
                if AppAccess.isLockFailure(error) { throw Failure.locked }
                throw (error as? NuoError).map(classify) ?? Failure.unreachable
            }
            // Kept too: a later attempt goes to this conversation instead of opening an empty one each time.
            current.conversationId = conversationId
            current.botId = choice.botId
            current.text = choice.text
            upsert(current)
        }
        if let failure = await WatchPromptRelay.send(conversationId: conversationId, text: choice.text) {
            NSLog("Nuo watch ask: prompt not sent: %@", failure)
            throw Failure.unreachable
        }
        let outcome = Outcome(conversationId: conversationId, botId: choice.botId, text: choice.text)
        var done = recent()
        done.insert(envelope.askId, outcome)
        UserDefaults.standard.set(try? JSONEncoder().encode(done), forKey: doneKey)
        drop(envelope)
        return outcome
    }

    /// The same steps through the relay token: transcription, the bot, the conversation (kept with the request),
    /// the prompt; then the turn is followed by polling and relayed to the watch, confirmations included.
    private static func processViaRelay(_ envelope: Envelope) async throws -> Outcome {
        let relay = RelayClient.shared
        do {
            let bots = try await relay.bots().map(Self.bot)
            var current = inbox().first { $0.askId == envelope.askId } ?? envelope
            // Too long or a command: the gateway would refuse it to the relay; it waits for the unlock as it is.
            if let text = current.text, RelayScope.waitsForUnlock(text) { throw Failure.outOfScope }
            let spoken: String
            if let text = current.text {
                spoken = text
            } else {
                guard let file = current.audioFile, let audio = try? Data(contentsOf: folder.appending(path: file)) else {
                    throw Failure.refused(String(localized: "The request audio could not be found."))
                }
                let languages = TranscriptionForm.languages(nil)
                let names = bots.compactMap { $0.config?.name } + [SessionDefaults.userName].compactMap { $0 }
                let form = TranscriptionForm(audio: audio, filename: "watch-ask.m4a", language: languages.language, otherLanguages: languages.others,
                                             keyterms: DictationTerms.unique(names, limit: 50), seconds: max(current.seconds, 1))
                let transcript = try await relay.transcribe(form, timeout: TranscriptionDeadline.seconds(forAudio: current.seconds, bytes: audio.count))
                spoken = Disfluency.strip(transcript.text, language: transcript.language ?? "fr").trimmingCharacters(in: .whitespacesAndNewlines)
                let withAudio = current
                current.text = spoken
                current.audioFile = nil
                upsert(current)
                cleanUp(withAudio)
            }
            guard !spoken.isEmpty else { throw Failure.refused(String(localized: "I didn't hear anything.")) }
            guard let choice = AskTarget.resolve(text: spoken, bots: bots, explicitBotId: current.botId, preferredBotId: current.preferredBotId)
            else { throw Failure.refused(String(localized: "No published bot to answer.")) }
            if RelayScope.waitsForUnlock(choice.text) { throw Failure.outOfScope }
            let conversationId: String
            var opened = false
            if let existing = current.conversationId, current.viaRelay == true {
                conversationId = existing
            } else {
                // A conversation of the app is out of the relay's reach: the request starts one of its own.
                opened = current.conversationId != nil
                conversationId = try await relay.createConversation(botId: choice.botId)
                current.conversationId = conversationId
                current.botId = choice.botId
                current.text = choice.text
                current.viaRelay = true
                upsert(current)
            }
            let messageId = try await relay.prompt(conversationId: conversationId, text: choice.text)
            // The watch was in another conversation: it is told why the answer lands in a new one.
            if opened { WatchPromptRelay.notice(RelayScope.newConversationText, conversationId: conversationId) }
            WatchPromptRelay.followRelay(conversationId: conversationId, messageId: messageId, askId: envelope.askId, botId: choice.botId, text: choice.text)
            let outcome = Outcome(conversationId: conversationId, botId: choice.botId, text: choice.text)
            var done = recent()
            done.insert(envelope.askId, outcome)
            UserDefaults.standard.set(try? JSONEncoder().encode(done), forKey: doneKey)
            drop(envelope)
            return outcome
        } catch let failure as RelayClient.Failure {
            switch failure {
            case .unavailable: throw Failure.locked
            case .unreachable: throw Failure.unreachable
            case .outOfScope: throw Failure.outOfScope
            case .limited: throw Failure.relayLimit
            case let .refused(status, message):
                throw classify(.server(status: status, message: message))
            }
        }
    }

    /// The relay's short list of bots, as the target picker reads them.
    private static func bot(_ summary: RelayClient.BotSummary) -> Bot {
        var config = BotConfig(name: summary.name, emoji: summary.emoji, color: "#EFECE6", description: "", agent: .claude, model: "", effort: nil,
                               instructions: "", toolServers: [], workdir: nil, permissionPolicy: .ask, voice: nil, commands: nil)
        config.overview = summary.overview
        let now = Date()
        return Bot(id: summary.id, published: BotVersion(version: 1, config: config, publishedAt: now), draft: nil, createdAt: now, updatedAt: now)
    }

    private static func transcribe(_ envelope: Envelope, client: NuoClient, bots: [Bot]) async throws -> String {
        guard let file = envelope.audioFile, let audio = try? Data(contentsOf: folder.appending(path: file)) else {
            throw Failure.refused(String(localized: "The request audio could not be found."))
        }
        let names = bots.compactMap { $0.config?.name } + [SessionDefaults.userName].compactMap { $0 }
        let languages = TranscriptionForm.languages(nil)
        let form = TranscriptionForm(audio: audio, filename: "watch-ask.m4a", language: languages.language, otherLanguages: languages.others,
                                     keyterms: DictationTerms.unique(names, limit: 50), seconds: max(envelope.seconds, 1))
        let started = Date()
        do {
            let transcript = try await client.transcribe(form, timeout: TranscriptionDeadline.seconds(forAudio: envelope.seconds, bytes: audio.count))
            NSLog("Nuo watch ask: %.1f s of audio transcribed in %.2f s", envelope.seconds, Date().timeIntervalSince(started))
            return Disfluency.strip(transcript.text, language: transcript.language ?? "fr").trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            if AppAccess.isLockFailure(error) { throw Failure.locked }
            if case NuoError.notFound = error { throw Failure.refused(String(localized: "Transcription is not set up on your gateway.")) }
            throw (error as? NuoError).map(classify) ?? Failure.unreachable
        }
    }

    /// A request the gateway refuses (bad audio, unknown bot) fails for good; the network or a busy gateway, not.
    nonisolated static func classify(_ error: NuoError) -> Failure {
        switch error {
        // A proxy's 403 has no gateway message: not the gateway's no.
        case let .server(status, message) where (400..<500).contains(status) && ![408, 429].contains(status) && !(status == 403 && message.isEmpty):
            .refused(message.isEmpty ? String(localized: "The gateway refused the request.") : message)
        case .notFound:
            .refused(String(localized: "Bot or conversation not found."))
        case .unauthorized, .reauthRequired:
            .refused(String(localized: "The iPhone is no longer authorized on your gateway: open Nuo to pair it again."))
        default:
            .unreachable
        }
    }


    // MARK: - Storage

    private static func inbox() -> [Envelope] {
        (try? Data(contentsOf: inboxURL)).flatMap { try? JSONDecoder().decode([Envelope].self, from: $0) } ?? []
    }

    private static func write(_ list: [Envelope]) {
        try? JSONEncoder().encode(list).write(to: inboxURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func keep(_ envelope: Envelope) {
        var list = inbox()
        guard !list.contains(where: { $0.askId == envelope.askId }) else { return }
        list.append(envelope)
        write(list)
    }

    private static func upsert(_ envelope: Envelope) {
        var list = inbox()
        if let index = list.firstIndex(where: { $0.askId == envelope.askId }) {
            list[index] = envelope
        } else {
            list.append(envelope)
        }
        write(list)
    }

    private static func drop(_ envelope: Envelope) {
        write(inbox().filter { $0.askId != envelope.askId })
        cleanUp(envelope)
    }

    private static func cleanUp(_ envelope: Envelope) {
        if let file = envelope.audioFile { try? FileManager.default.removeItem(at: folder.appending(path: file)) }
    }

    /// Requests already sent, oldest first, so one delivered twice (live, then by the queue) reaches the bot once.
    private static func recent() -> RecentlyDone<Outcome> {
        UserDefaults.standard.data(forKey: doneKey).flatMap { try? JSONDecoder().decode(RecentlyDone<Outcome>.self, from: $0) } ?? RecentlyDone()
    }

    private static func acknowledge(_ id: String, outcome: Outcome) {
        transfer([
            RecordingLink.kind: RecordingLink.askAck, RecordingLink.askId: id, RecordingLink.conversationId: outcome.conversationId,
            RecordingLink.botId: outcome.botId, RecordingLink.text: outcome.text,
        ])
    }

    private static func acknowledgeFailure(_ id: String, reason: String, text: String?) {
        var info: [String: Any] = [RecordingLink.kind: RecordingLink.askAck, RecordingLink.askId: id, RecordingLink.error: reason]
        if let text { info[RecordingLink.text] = text }
        transfer(info)
    }

    private static func transfer(_ info: [String: Any]) {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated else { return }
        session.transferUserInfo(info)
        // The queued copy can take minutes to reach the watch: a request kept until the unlock would look lost.
        if session.isReachable { session.sendMessage(info, replyHandler: nil, errorHandler: nil) }
    }

    private static func backgroundWindow() -> () -> Void {
        AppAccess.backgroundWindow(AppIdentity.local(.watchAskTask))
    }
}

/// The user's first name, readable outside the session store.
enum SessionDefaults {
    static var userName: String? {
        Optional(UserNamePreference.standard.load()).flatMap { $0.isEmpty ? nil : $0 }
    }
}
