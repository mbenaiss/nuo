import Foundation

/// The iPhone's answer to a request sent live from the watch.
struct AskReply: Sendable, Equatable {
    var ok: Bool
    var queued: Bool
    var locked = false
    var reason: String?
    var error: String?
    var conversationId: String?
    var botId: String?
    var text: String?

    init(ok: Bool, queued: Bool, locked: Bool = false, reason: String? = nil, error: String? = nil,
         conversationId: String? = nil, botId: String? = nil, text: String? = nil) {
        self.ok = ok
        self.queued = queued
        self.locked = locked
        self.reason = reason
        self.error = error
        self.conversationId = conversationId
        self.botId = botId
        self.text = text
    }

    init(_ reply: [String: Any]) {
        self.init(
            ok: reply[RecordingLink.ok] as? Bool == true, queued: reply[RecordingLink.queued] as? Bool == true,
            locked: reply[RecordingLink.locked] as? Bool == true, reason: reply[RecordingLink.reason] as? String,
            error: reply[RecordingLink.error] as? String,
            conversationId: reply[RecordingLink.conversationId] as? String, botId: reply[RecordingLink.botId] as? String,
            text: reply[RecordingLink.text] as? String)
    }

    /// WatchConnectivity calls it on its own queue: it must not belong to the main actor, or Swift's isolation check
    /// stops the watch app the moment the iPhone answers.
    static func resuming(_ continuation: CheckedContinuation<AskReply?, Never>) -> @Sendable ([String: Any]) -> Void {
        { reply in continuation.resume(returning: AskReply(reply)) }
    }
}

enum AskFollow {
    /// A request answered later than this is read from the notification, not opened over what the user does now.
    static let window: TimeInterval = 15 * 60

    static func opensAnswer(askedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(askedAt) < window
    }

    static func handlesAck(liveReplyPending: Bool) -> Bool { !liveReplyPending }
}
