import Foundation

/// The Stop button takes the Send button's place as soon as a message leaves: a second tap meant for Send, or a double
/// tap, must not stop the answer it just asked for.
enum StopGuard {
    static let grace: TimeInterval = 2.5

    static func ignores(tapAt now: Date, turnStartedAt: Date?) -> Bool {
        guard let started = turnStartedAt else { return false }
        return now.timeIntervalSince(started) < grace
    }
}
