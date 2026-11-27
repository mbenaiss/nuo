import Foundation
import UIKit
import WatchConnectivity

/// Hands the gateway address and token to the watch app, and relays prompts the watch cannot send itself
/// (watchOS only allows WebSockets in narrow cases, so the watch falls back to the iPhone's socket).
final class WatchSync: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchSync()

    private let lock = NSLock()
    private var lastSent: [String: String] = [:]
    private var observers: [NSObjectProtocol] = []
    private var unlockObserver: NSObjectProtocol?
    private var lastMuscuRest: MuscuRestLink.Rest?
    /// The first stop is sent too: a watch left counting by a killed app hears that the rest is over.
    private var muscuRestSent = false

    private static var isDemo: Bool { ProcessInfo.processInfo.arguments.contains("-demo") }

    func start() {
        guard WCSession.isSupported(), !Self.isDemo else { return }
        // Here rather than with a screen: a launch in the background by the watch has none, and the requests it
        // brought must go as soon as the iPhone is unlocked.
        Task { @MainActor in
            self.unlockObserver = AppAccess.onUnlock {
                RecordingsStore.shared.resumeAll()
                Task { await WatchAskRelay.retry() }
            }
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        let center = NotificationCenter.default
        let push: @Sendable (Notification) -> Void = { [weak self] _ in self?.pushCredentials() }
        observers = [
            center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil, using: push),
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil, using: push),
        ]
    }

    /// The watch only gets its scoped token (bots, conversations, reminders, prompts), never the app's.
    private func credentials() -> [String: String] {
        guard let token = SharedCredentials.extensionToken(.watch) else { return [:] }
        let gateway = UserDefaults.standard.string(forKey: AppIdentity.local(.gatewayURL)) ?? AppIdentity.defaultGateway
        var payload = [WatchLink.gatewayURL: gateway, WatchLink.token: token]
        if let publicURL = SharedCredentials.publicURL, let cf = SharedCredentials.cfAccess {
            payload[WatchLink.publicURL] = publicURL.absoluteString
            payload[WatchLink.cfAccessClientId] = cf.clientId
            payload[WatchLink.cfAccessClientSecret] = cf.clientSecret
        }
        return payload
    }

    func pushCredentials(force: Bool = false) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        let current = credentials()
        lock.lock()
        let changed = force || current != lastSent
        if changed { lastSent = current }
        lock.unlock()
        guard changed else { return }
        try? session.updateApplicationContext(current)
    }

    /// The Muscu screen's rest on the wrist; nil stops it. Queued when the watch app is asleep, so it still learns of it.
    func sendMuscuRest(_ rest: MuscuRestLink.Rest?) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        lock.lock()
        let changed = !muscuRestSent || rest != lastMuscuRest
        lastMuscuRest = rest
        muscuRestSent = true
        lock.unlock()
        guard changed else { return }
        nonisolated(unsafe) let payload = MuscuRestLink.payload(rest)
        guard session.isReachable else {
            session.transferUserInfo(payload)
            return
        }
        session.sendMessage(payload, replyHandler: nil) { _ in WCSession.default.transferUserInfo(payload) }
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        pushCredentials(force: true)
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        pushCredentials(force: true)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        switch message[WatchLink.request] as? String {
        case WatchLink.requestCredentials:
            pushCredentials(force: true)
            replyHandler(credentials())
        case WatchLink.requestPrompt:
            guard let conversationId = message[WatchLink.conversationId] as? String,
                  let text = message[WatchLink.text] as? String
            else {
                replyHandler([WatchLink.ok: false])
                return
            }
            nonisolated(unsafe) let reply = replyHandler
            Task { @MainActor in
                let error = await WatchPromptRelay.send(conversationId: conversationId, text: text)
                reply(error.map { [WatchLink.ok: false, WatchLink.error: $0] } ?? [WatchLink.ok: true])
            }
        case RecordingLink.ask:
            nonisolated(unsafe) let reply = replyHandler
            nonisolated(unsafe) let message = message
            Task { @MainActor in reply(await WatchAskRelay.handleLive(message)) }
        case RecordingLink.permissionAnswer:
            guard let requestId = message[RecordingLink.requestId] as? String, let optionId = message[RecordingLink.optionId] as? String else {
                replyHandler([WatchLink.ok: false])
                return
            }
            nonisolated(unsafe) let reply = replyHandler
            Task { @MainActor in
                let error = await WatchPromptRelay.answer(requestId: requestId, optionId: optionId)
                reply(error.map { [WatchLink.ok: false, WatchLink.error: $0] } ?? [WatchLink.ok: true])
            }
        default:
            replyHandler([WatchLink.ok: false])
        }
    }

    /// A recording segment or a spoken request sent through the system's queue. The file is gone once this returns.
    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let metadata = file.metadata ?? [:]
        switch metadata[RecordingLink.kind] as? String {
        case RecordingLink.segment:
            guard let id = metadata[RecordingLink.recordingId] as? String, let index = metadata[RecordingLink.index] as? Int else { return }
            let stored = RecordingInbox.store(segment: file.fileURL, recordingId: id, index: index)
            guard stored != .rejected else { return }
            // Acknowledged once the index knows the piece (a copy too, so the watch stops sending it).
            Task { @MainActor in
                RecordingsStore.shared.segmentArrived(recordingId: id, index: index, stored: stored)
                WCSession.default.transferUserInfo([RecordingLink.kind: RecordingLink.segmentAck, RecordingLink.recordingId: id, RecordingLink.indices: [index]])
            }
        case RecordingLink.ask:
            guard let id = WatchAskRelay.Envelope.validId(metadata[RecordingLink.askId]) else { return }
            let name = "\(id).m4a"
            let target = RecordingInbox.asksFolder.appending(path: name)
            // A copy never replaces the audio already here: it may be being sent for transcription.
            if !FileManager.default.fileExists(atPath: target.path) {
                guard (try? FileManager.default.moveItem(at: file.fileURL, to: target)) != nil else { return }
            }
            nonisolated(unsafe) let metadata = metadata
            Task { @MainActor in
                if let envelope = WatchAskRelay.Envelope(metadata, audioFile: name) { WatchAskRelay.handleQueued(envelope) }
            }
        default:
            break
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        switch userInfo[RecordingLink.kind] as? String {
        case RecordingLink.manifest:
            guard let data = userInfo[RecordingLink.payload] as? Data,
                  let manifest = try? JSONDecoder().decode(RecordingManifest.self, from: data),
                  UUID(uuidString: manifest.id) != nil
            else { return }
            Task { @MainActor in
                RecordingsStore.shared.manifestArrived(manifest)
                if manifest.isFinished {
                    WCSession.default.transferUserInfo([RecordingLink.kind: RecordingLink.manifestAck, RecordingLink.recordingId: manifest.id])
                }
            }
        case RecordingLink.ask:
            nonisolated(unsafe) let info = userInfo
            Task { @MainActor in
                if let envelope = WatchAskRelay.Envelope(info, audioFile: nil) { WatchAskRelay.handleQueued(envelope) }
            }
        case RecordingLink.segmentLost:
            guard let id = userInfo[RecordingLink.recordingId] as? String, UUID(uuidString: id) != nil,
                  let index = userInfo[RecordingLink.index] as? Int
            else { return }
            Task { @MainActor in RecordingsStore.shared.segmentLost(recordingId: id, index: index) }
        default:
            break
        }
    }
}

/// Opens a short-lived socket to send one prompt for the watch and keeps it until the turn ends,
/// since the gateway may tie a running turn to the socket that started it. The turn's events go on to the watch,
/// confirmations included, which the watch answers through `answer`.
@MainActor
enum WatchPromptRelay {
    private static var sockets: [UUID: NuoSocket] = [:]
    /// The socket and conversation of each confirmation this relay saw: the watch may answer those, nothing else.
    private static var permissions: [String: (socket: UUID, conversationId: String, options: [PermissionOption])] = [:]

    static func send(conversationId: String, text: String) async -> String? {
        let gateway = AppIdentity.gatewayURL
        let auth: AuthSession
        switch AuthSession.restoreState(fallbackLAN: gateway) {
        case let .paired(session): auth = session
        case .waitForUnlock: return String(localized: "Unlock the iPhone, then try again.")
        case .unpaired: return String(localized: "iPhone not paired.")
        }
        let socket = NuoSocket(auth: auth)
        let id = UUID()
        sockets[id] = socket
        socket.start()
        for _ in 0..<40 where socket.connectionState != .connected {
            try? await Task.sleep(for: .milliseconds(250))
        }
        let events = socket.events()
        do {
            try await socket.send(.prompt(conversationId: conversationId, text: text))
        } catch {
            close(id)
            return String(localized: "Gateway unreachable from the iPhone.")
        }
        Task {
            for await event in events {
                forward(event, conversationId: conversationId, socket: id)
                if case let .messageEnd(conv, _, _, _, _, _, _, _) = event, conv == conversationId { break }
            }
            close(id)
        }
        Task {
            try? await Task.sleep(for: .seconds(300))
            close(id)
        }
        return nil
    }

    private static func close(_ id: UUID) {
        sockets[id]?.stop()
        sockets[id] = nil
        permissions = permissions.filter { $0.value.socket != id }
    }

    /// Confirmations of turns passed on through the relay token (iPhone locked), and their options.
    private static var relayPermissions: [String: (conversationId: String, options: [PermissionOption])] = [:]
    /// Confirmations the watch has been shown; one whose message did not reach it is shown again on the next poll.
    private static var relayAnnounced: Set<String> = []
    /// Requests followed, by the watch's ask id: two requests in one conversation each get their own answer.
    private static var followed: Set<String> = []

    /// A request passed on through the relay: no socket, its turn is read every second and relayed to the watch, until
    /// the answer to that very prompt (the assistant message after `messageId`) is stored. When the relay had to refuse
    /// a tool, the request waits for the unlock (`WatchAskRelay.waitForUnlock`) and the watch is told.
    static func followRelay(conversationId: String, messageId: String, askId: String, botId: String, text: String) {
        guard followed.insert(askId).inserted else { return }
        Task {
            defer { followed.remove(askId) }
            var lastText = ""
            let deadline = Date().addingTimeInterval(10 * 60)
            while Date() < deadline {
                try? await Task.sleep(for: .seconds(1))
                guard let view = try? await RelayClient.shared.turn(conversationId: conversationId) else { continue }
                if let turn = view.turn {
                    if let text = turn.text, text != lastText, push(["event": "replace", RecordingLink.text: text], conversationId: conversationId) {
                        lastText = text
                    }
                    if let permission = turn.permission, !relayAnnounced.contains(permission.requestId) {
                        relayPermissions[permission.requestId] = (conversationId, permission.options)
                        let sent = push([RecordingLink.event: "permission", RecordingLink.requestId: permission.requestId, RecordingLink.title: permission.title,
                                         RecordingLink.options: (try? JSONEncoder().encode(permission.options)) ?? Data()],
                                        conversationId: conversationId, failed: { relayAnnounced.remove(permission.requestId) })
                        if sent { relayAnnounced.insert(permission.requestId) }
                    }
                    continue
                }
                guard let messages = try? await RelayClient.shared.messages(conversationId: conversationId),
                      let answer = RelayScope.answer(to: messageId, in: messages), let reason = answer.stopReason
                else { continue }
                push([RecordingLink.event: "end", "durationMs": answer.durationMs ?? 0, "steps": answer.steps?.count ?? 0, "stopReason": reason.rawValue],
                     conversationId: conversationId)
                if view.waitsForUnlock == true {
                    notice(RelayScope.waitingText, conversationId: conversationId)
                    WatchAskRelay.waitForUnlock(askId: askId, conversationId: conversationId, botId: botId, text: text)
                }
                break
            }
            for (id, pending) in relayPermissions where pending.conversationId == conversationId {
                relayPermissions[id] = nil
                relayAnnounced.remove(id)
            }
        }
    }

    /// A line under the answer on the watch: where the request stands.
    static func notice(_ text: String, conversationId: String) {
        push([RecordingLink.event: "notice", RecordingLink.text: text], conversationId: conversationId)
    }

    /// False when the watch cannot be reached now; `failed` runs if the message is lost on its way.
    @discardableResult
    private static func push(_ fields: [String: Any], conversationId: String, failed: (@MainActor () -> Void)? = nil) -> Bool {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return false }
        var message = fields
        message[WatchLink.request] = RecordingLink.turn
        message[RecordingLink.conversationId] = conversationId
        session.sendMessage(message, replyHandler: nil, errorHandler: failed.map { failed in { _ in Task { @MainActor in failed() } } })
        return true
    }

    /// « Confirmer » or « Annuler » from the watch, only for a confirmation of a turn this relay runs, on its socket
    /// or through the relay token.
    static func answer(requestId: String, optionId: String) async -> String? {
        if let pending = relayPermissions[requestId] {
            guard let option = pending.options.first(where: { $0.id == optionId }), ConfirmationChoice.isRelayable(option) else {
                return String(localized: "Make this choice on the iPhone.")
            }
            do {
                try await RelayClient.shared.answer(conversationId: pending.conversationId, requestId: requestId, optionId: optionId)
                relayPermissions[requestId] = nil
                return nil
            } catch RelayClient.Failure.refused(status: 403, _) {
                return String(localized: "Make this choice on the unlocked iPhone.")
            } catch RelayClient.Failure.refused(status: 404, _) {
                return String(localized: "This confirmation no longer needs an answer.")
            } catch {
                return String(localized: "Gateway unreachable from the iPhone.")
            }
        }
        guard let pending = permissions[requestId], let socket = sockets[pending.socket] else {
            return String(localized: "This confirmation didn't come from an Apple Watch request: answer on the iPhone.")
        }
        // Once, either way: « always » is never given from the watch, whatever it sends.
        guard let option = pending.options.first(where: { $0.id == optionId }), ConfirmationChoice.isRelayable(option) else {
            return String(localized: "Make this choice on the iPhone.")
        }
        do {
            try await socket.send(.permission(requestId: requestId, optionId: optionId))
            permissions[requestId] = nil
            return nil
        } catch {
            return String(localized: "Gateway unreachable from the iPhone.")
        }
    }

    /// What the watch shows of the turn: text, steps, a confirmation, the end.
    private static func forward(_ event: ServerEvent, conversationId: String, socket: UUID) {
        var message: [String: Any]
        switch event {
        case let .messageDelta(conv, _, text) where conv == conversationId:
            message = [RecordingLink.event: "delta", RecordingLink.text: text]
        case let .toolStart(conv, _, toolCallId, title, _) where conv == conversationId:
            message = [RecordingLink.event: "tool", RecordingLink.requestId: toolCallId, RecordingLink.text: title]
        case let .toolEnd(conv, _, _, _, _) where conv == conversationId:
            message = [RecordingLink.event: "toolEnd"]
        case let .permissionRequest(conv, requestId, title, options, _) where conv == conversationId:
            permissions[requestId] = (socket, conversationId, options)
            message = [RecordingLink.event: "permission", RecordingLink.requestId: requestId, RecordingLink.title: title,
                       RecordingLink.options: (try? JSONEncoder().encode(options)) ?? Data()]
        case let .messageEnd(conv, _, durationMs, steps, stopReason, _, _, _) where conv == conversationId:
            message = [RecordingLink.event: "end", "durationMs": durationMs, "steps": steps, "stopReason": stopReason.rawValue]
        case let .error(conv, text) where conv == conversationId:
            message = [RecordingLink.event: "error", RecordingLink.text: text]
        default:
            return
        }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        message[WatchLink.request] = RecordingLink.turn
        message[RecordingLink.conversationId] = conversationId
        session.sendMessage(message, replyHandler: nil, errorHandler: nil)
    }
}
