import Foundation
import Observation

/// One editing session per document for the whole app. The views showing a document share it (the main pane and a
/// separate window no longer race each other), and a session with edits not saved yet outlives its views: its retries
/// keep running after the document is closed, until the edits are saved, and quitting flushes it.
@MainActor
@Observable
final class DocSessions {
    static let shared = DocSessions()

    private(set) var sessions: [String: DocEditSession] = [:]
    @ObservationIgnored private var holders: [ObjectIdentifier: Int] = [:]

    private init() {}

    /// The session of `path`, created on first use (with `store` when given, so a screen keeps the store it shows).
    func session(for path: String, store: DocStore? = nil) -> DocEditSession {
        if let session = sessions[path] { return session }
        let session = DocEditSession(store: store ?? DocStore(path: path))
        session.onSettled = { [weak self, weak session] in
            if let session { self?.evictIfIdle(session) }
        }
        sessions[path] = session
        return session
    }

    /// A view shows the session; balanced by `release`.
    func acquire(_ session: DocEditSession) {
        holders[ObjectIdentifier(session), default: 0] += 1
        if sessions[session.path] == nil { sessions[session.path] = session }
    }

    func release(_ session: DocEditSession) {
        let id = ObjectIdentifier(session)
        holders[id] = max(0, (holders[id] ?? 0) - 1)
        evictIfIdle(session)
    }

    private func evictIfIdle(_ session: DocEditSession) {
        let id = ObjectIdentifier(session)
        guard (holders[id] ?? 0) == 0, session.isSettled, sessions[session.path] === session else { return }
        sessions[session.path] = nil
        holders[id] = nil
    }

    /// Sessions whose edits are not saved because a save failed or conflicts, open or not.
    var needingAttention: [DocEditSession] {
        sessions.values.filter(\.needsAttention).sorted { $0.path < $1.path }
    }

    // MARK: Moves and deletions

    private func sessions(under roots: [String]) -> [DocEditSession] {
        sessions.values.filter { session in roots.contains { session.path == $0 || session.path.hasPrefix($0 + "/") } }
    }

    /// Saves the sessions of `roots` (and of the documents inside them), then keeps them from saving until `resume`:
    /// a save landing on the old path during a move would bring the document back there.
    func hold(under roots: [String]) async -> [DocEditSession] {
        let affected = sessions(under: roots)
        await withTaskGroup(of: Void.self) { group in
            for session in affected { group.addTask { await session.save(explicit: false) } }
        }
        for session in affected { session.hold() }
        // A save that started before the hold must land before the move.
        for session in affected { await session.idle() }
        return affected
    }

    /// Points the held sessions at their new path (old path → new path, folders included) and lets them save again.
    func resume(_ held: [DocEditSession], after moves: [String: String]) {
        for session in held {
            if let moved = FilesHomeStore.path(session.path, after: moves) {
                let old = session.path
                if sessions[old] === session { sessions[old] = nil }
                session.store.moved(to: moved)
                if let existing = sessions[moved], existing !== session { existing.discard() }
                sessions[moved] = session
            }
            session.resume()
        }
    }

    /// The documents were deleted: their sessions stop saving.
    func discard(_ held: [DocEditSession]) {
        for session in held {
            session.discard()
            if sessions[session.path] === session { sessions[session.path] = nil }
            holders[ObjectIdentifier(session)] = nil
        }
    }

    // MARK: Quitting

    /// Saves every session, including the last keystrokes still in the editors.
    func flushAll() async {
        let all = Array(sessions.values)
        await withTaskGroup(of: Void.self) { group in
            for session in all { group.addTask { await session.save() } }
        }
    }

    /// A sentence for the quit confirmation when edits could not be saved; nil when everything can be flushed.
    var pendingReason: String? {
        let unsaved = needingAttention
        guard let first = unsaved.first else { return nil }
        let name = "“\(DocNames.display(name: (first.path as NSString).lastPathComponent))”"
        if unsaved.count > 1 {
            return String(localized: "\(unsaved.count) documents have unsaved changes (\(name) and others): they would be lost.")
        }
        if first.status == .conflict {
            return String(localized: "The document \(name) has unsaved changes that conflict with a version edited elsewhere: they would be lost.")
        }
        return String(localized: "The document \(name) has unsaved changes (saving failed): they would be lost.")
    }
}
