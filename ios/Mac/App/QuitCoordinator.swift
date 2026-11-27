import AppKit

/// Work that must not be lost on ⌘Q (a meeting being recorded, a document not saved yet): each feature registers what
/// it holds, and the app delegate asks before quitting, then lets every one of them flush.
@MainActor
final class QuitCoordinator {
    static let shared = QuitCoordinator()

    struct Guard {
        /// A sentence for the confirmation alert when quitting now would lose something the user would miss; nil otherwise.
        let pending: @MainActor () -> String?
        /// Saves what can be saved; quitting waits for it (at most a few seconds).
        let flush: @MainActor () async -> Void
    }

    private var guards: [String: Guard] = [:]

    private init() {}

    func register(_ name: String, pending: @escaping @MainActor () -> String? = { nil }, flush: @escaping @MainActor () async -> Void) {
        guards[name] = Guard(pending: pending, flush: flush)
    }

    var pendingReasons: [String] { guards.keys.sorted().compactMap { guards[$0]?.pending() } }

    /// Returns once every flush is done or at `timeout`, whichever comes first: a flush may wait on work that ignores
    /// cancellation (a save in flight), and a late reply would make macOS give up a logout or a restart.
    func flushAll(timeout: Duration = .seconds(8)) async {
        let all = Array(guards.values)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let finish = Once { continuation.resume() }
            Task { @MainActor in
                for g in all { await g.flush() }
                finish()
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                finish()
            }
        }
    }

    @MainActor
    private final class Once {
        private var action: (() -> Void)?

        init(_ action: @escaping () -> Void) { self.action = action }

        func callAsFunction() {
            let run = action
            action = nil
            run?()
        }
    }
}
