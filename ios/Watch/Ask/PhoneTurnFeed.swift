import Foundation

/// Live events of turns the iPhone runs for the watch (text, steps, a confirmation to give, the end), as it relays
/// them over WatchConnectivity. The stored messages remain the reference: these only make the answer appear sooner.
@MainActor
final class PhoneTurnFeed {
    static let shared = PhoneTurnFeed()

    private var listeners: [String: [UUID: AsyncStream<TurnUpdate>.Continuation]] = [:]
    /// A turn's events, confirmations included, replayed to every screen that starts listening: the iPhone often
    /// relays the whole turn before the watch opens its screen, and a second screen must not wait for an end already gone.
    private var waiting: [String: (since: Date, updates: [TurnUpdate])] = [:]
    private static let keep: TimeInterval = 5 * 60
    private static let most = 400

    func updates(conversationId: String) -> AsyncStream<TurnUpdate> {
        let (stream, continuation) = AsyncStream<TurnUpdate>.makeStream()
        let id = UUID()
        if let buffered = waiting[conversationId], Date().timeIntervalSince(buffered.since) < Self.keep {
            for update in buffered.updates { continuation.yield(update) }
        }
        listeners[conversationId, default: [:]][id] = continuation
        continuation.onTermination = { _ in
            Task { @MainActor in PhoneTurnFeed.shared.listeners[conversationId]?[id] = nil }
        }
        return stream
    }

    /// Before a new request in a conversation: what is left of an earlier turn must not be replayed as its answer.
    func reset(conversationId: String) {
        waiting[conversationId] = nil
    }

    func receive(_ message: [String: Any]) {
        guard let conversationId = message[RecordingLink.conversationId] as? String,
              let update = Self.update(from: message)
        else { return }
        waiting = waiting.filter { Date().timeIntervalSince($0.value.since) < Self.keep }
        var buffered = waiting[conversationId] ?? (Date(), [])
        buffered.updates.append(update)
        if buffered.updates.count > Self.most { buffered.updates.removeFirst(buffered.updates.count - Self.most) }
        waiting[conversationId] = buffered
        for continuation in listeners[conversationId]?.values.map({ $0 }) ?? [] { continuation.yield(update) }
    }

    /// The iPhone's dictionary back into an update; nil for an event the watch does not show.
    static func update(from message: [String: Any]) -> TurnUpdate? {
        let text = message[RecordingLink.text] as? String ?? ""
        switch message[RecordingLink.event] as? String {
        case "delta": return .delta(text)
        case "replace": return .replace(text)
        case "tool": return .toolStarted(id: message[RecordingLink.requestId] as? String ?? UUID().uuidString, title: text)
        case "toolEnd": return .toolEnded
        case "permission":
            guard let requestId = message[RecordingLink.requestId] as? String,
                  let data = message[RecordingLink.options] as? Data,
                  let options = try? JSONDecoder().decode([PermissionOption].self, from: data)
            else { return nil }
            return .permission(requestId: requestId, title: message[RecordingLink.title] as? String ?? "", options: options, answerable: true)
        case "end":
            let reason = (message["stopReason"] as? String).flatMap(StopReason.init(rawValue:)) ?? .endTurn
            return .finished(durationMs: message["durationMs"] as? Int ?? 0, steps: message["steps"] as? Int ?? 0, stopReason: reason)
        case "error": return .failed(text)
        case "notice": return text.isEmpty ? nil : .notice(text)
        default: return nil
        }
    }
}
