import Foundation

extension DocSessions {
    /// ⌘Q saves every open or unsaved document first, and asks before quitting when one could not be saved.
    static func registerForQuit() {
        QuitCoordinator.shared.register("docs", pending: { DocSessions.shared.pendingReason }, flush: { await DocSessions.shared.flushAll() })
    }
}
