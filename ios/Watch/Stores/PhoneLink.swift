import Foundation
import WatchConnectivity

/// WatchConnectivity side of the watch: receives the gateway credentials and relays prompts through the iPhone.
final class PhoneLink: NSObject, WCSessionDelegate, @unchecked Sendable {
    private let onCredentials: @MainActor @Sendable (WatchCredentials?) -> Void

    /// A WatchConnectivity payload, carried across to the main actor as it came.
    private struct Payload: @unchecked Sendable {
        let values: [String: Any]
    }

    /// The iPhone's live turn events, in the order they came: one reader, not a task per message.
    private let turnEvents: AsyncStream<Payload>.Continuation

    init(onCredentials: @escaping @MainActor @Sendable (WatchCredentials?) -> Void) {
        self.onCredentials = onCredentials
        let (stream, continuation) = AsyncStream<Payload>.makeStream()
        turnEvents = continuation
        super.init()
        Task { @MainActor in
            for await payload in stream { PhoneTurnFeed.shared.receive(payload.values) }
        }
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    var isReachable: Bool { WCSession.default.activationState == .activated && WCSession.default.isReachable }

    func requestCredentials() {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        handle(session.receivedApplicationContext)
        guard session.isReachable else { return }
        session.sendMessage([WatchLink.request: WatchLink.requestCredentials], replyHandler: { [weak self] reply in
            self?.handle(reply)
        }, errorHandler: nil)
    }

    func relayPrompt(conversationId: String, text: String) async throws {
        guard isReachable else {
            throw WatchError.server(String(localized: "Gateway unreachable and iPhone out of range."))
        }
        let message: [String: Any] = [
            WatchLink.request: WatchLink.requestPrompt,
            WatchLink.conversationId: conversationId,
            WatchLink.text: text,
        ]
        let failure: String? = try await withCheckedThrowingContinuation { continuation in
            WCSession.default.sendMessage(message, replyHandler: { reply in
                if reply[WatchLink.ok] as? Bool == true {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: reply[WatchLink.error] as? String ?? String(localized: "The iPhone couldn't send the message."))
                }
            }, errorHandler: { _ in
                continuation.resume(throwing: WatchError.server(String(localized: "iPhone unreachable.")))
            })
        }
        if let failure { throw WatchError.server(failure) }
    }

    /// "Confirm" or "Cancel" tapped on the watch, sent by the iPhone with the app's access.
    func answerPermission(requestId: String, optionId: String) async throws {
        guard isReachable else {
            throw WatchError.server(String(localized: "iPhone out of range: confirm on the iPhone."))
        }
        let message: [String: Any] = [
            WatchLink.request: RecordingLink.permissionAnswer,
            RecordingLink.requestId: requestId,
            RecordingLink.optionId: optionId,
        ]
        let failure: String? = try await withCheckedThrowingContinuation { continuation in
            WCSession.default.sendMessage(message, replyHandler: { reply in
                continuation.resume(returning: reply[WatchLink.ok] as? Bool == true ? nil : (reply[WatchLink.error] as? String ?? String(localized: "The iPhone couldn't pass on your answer.")))
            }, errorHandler: { _ in
                continuation.resume(throwing: WatchError.server(String(localized: "iPhone unreachable.")))
            })
        }
        if let failure { throw WatchError.server(failure) }
    }

    private func handle(_ payload: [String: Any]) {
        guard !payload.isEmpty else { return }
        let credentials: WatchCredentials?
        if let token = payload[WatchLink.token] as? String, !token.isEmpty,
           let raw = payload[WatchLink.gatewayURL] as? String, let url = URL(string: raw) {
            credentials = WatchCredentials(gatewayURL: url, token: token)
        } else {
            credentials = nil
        }
        let callback = onCredentials
        Task { @MainActor in callback(credentials) }
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        guard activationState == .activated else { return }
        requestCredentials()
        Task { @MainActor in
            RecordingUplink.shared.pump()
            AskCenter.shared.pump()
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if message[RecordingLink.kind] as? String == RecordingLink.askAck {
            // The live copy of an acknowledgement also queued by the iPhone: whichever comes first counts.
            let payload = Payload(values: message)
            Task { @MainActor in AskCenter.shared.receive(payload.values) }
            return
        }
        guard message[WatchLink.request] as? String == RecordingLink.turn else { return }
        turnEvents.yield(Payload(values: message))
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        nonisolated(unsafe) let info = userInfo
        Task { @MainActor in
            RecordingUplink.shared.receive(info)
            AskCenter.shared.receive(info)
        }
    }

    func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: (any Error)?) {
        nonisolated(unsafe) let info = userInfoTransfer.userInfo
        let failed = error != nil
        Task { @MainActor in AskCenter.shared.transferFinished(metadata: info, failed: failed) }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: (any Error)?) {
        nonisolated(unsafe) let metadata = fileTransfer.file.metadata
        let failed = error != nil
        Task { @MainActor in
            RecordingUplink.shared.transferFinished(metadata: metadata, failed: failed)
            AskCenter.shared.transferFinished(metadata: metadata, failed: failed)
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        handle(applicationContext)
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        if session.isReachable { requestCredentials() }
        let reachable = session.isReachable
        Task { @MainActor in
            RecordingUplink.shared.reachabilityChanged(reachable)
            AskCenter.shared.reachabilityChanged(reachable)
        }
    }
}
