import Foundation

enum TurnUpdate: Sendable {
    case delta(String)
    case replace(String)
    case toolStarted(id: String, title: String)
    /// What a started tool does, in words: shown instead of its title.
    case toolDetail(id: String, detail: String)
    case toolEnded
    case finished(durationMs: Int, steps: Int, stopReason: StopReason)
    case failed(String)
    /// The agent asks before acting (send, pay, delete): answered on the watch, sent by the iPhone.
    /// `answerable`: relayed by the iPhone, which can pass the answer on; seen on the watch's own socket, it is
    /// answered on the iPhone.
    case permission(requestId: String, title: String, options: [PermissionOption], answerable: Bool)
    case permissionResolved
    /// The iPhone's word on where the request stands (a new conversation opened while locked, a request waiting for
    /// the unlock): shown under the answer.
    case notice(String)

    var endsTurn: Bool {
        switch self {
        case .finished, .failed: true
        default: false
        }
    }
}
