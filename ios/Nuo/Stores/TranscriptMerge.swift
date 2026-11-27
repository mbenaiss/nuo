import Foundation

/// Turns a chat saw end. A server answer requested before one of them ended still describes it as running:
/// taken as is, it would bring the turn back for good (Stop button shown, queue never sent) and drop its answer.
struct EndedTurns {
    /// Grows with every end: a reload notes it when its request leaves and compares once the answer is back.
    private(set) var count = 0
    private var recent: [String] = []

    mutating func record(_ messageId: String?) {
        count += 1
        guard let messageId, !recent.contains(messageId) else { return }
        recent.append(messageId)
        if recent.count > 16 { recent.removeFirst() }
    }

    func endedSince(_ mark: Int) -> Bool { count != mark }

    /// The tracker hears the same `messageEnd` on its own stream and may not have dropped the turn yet.
    func isOver(_ turn: TurnSnapshot) -> Bool { recent.contains(turn.messageId) }
}

enum TranscriptMerge {
    /// `next`, where every message equal to one already shown is that shown value: its text keeps its buffer,
    /// so comparing the old and new lists stops at identity and an unchanged reload changes nothing on screen.
    static func reusing(_ shown: [Message], in next: [Message]) -> [Message] {
        guard !shown.isEmpty else { return next }
        var byId: [String: Message] = [:]
        for message in shown { byId[message.id] = message }
        return next.map { message in
            if let old = byId[message.id], old == message { return old }
            return message
        }
    }

    /// A prompt that did not go out comes back ahead of what was typed since, on its own line.
    static func draft(returning text: String, before draft: String) -> String {
        guard draft.contains(where: { !$0.isWhitespace }) else { return text }
        guard !text.isEmpty else { return draft }
        return text + "\n" + draft
    }
}
