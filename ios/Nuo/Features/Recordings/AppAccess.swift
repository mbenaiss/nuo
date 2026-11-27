import Foundation
import UIKit

/// The app's own access to the gateway, for work the watch hands over (its token may neither transcribe nor reach
/// the general bot). A locked iPhone cannot sign with its device key: that is a wait for the unlock, never a refusal.
@MainActor
enum AppAccess {
    enum State {
        case ready(NuoClient)
        /// The key is unreadable until the iPhone is unlocked.
        case locked
        case unpaired
    }

    static var isLocked: Bool { !UIApplication.shared.isProtectedDataAvailable }

    /// Decided from the stored pairing, not from a client kept in memory (it outlives an unpairing). A client in
    /// memory is still used while the iPhone is locked: its access token stays good until it expires.
    static func state() -> State {
        let gateway = AppIdentity.gatewayURL
        let cached = PushManager.shared.api as? NuoClient
        switch AuthSession.restoreState(fallbackLAN: gateway) {
        case let .paired(auth): return .ready(cached ?? NuoClient(baseURL: gateway, auth: auth))
        case .waitForUnlock:
            if let cached { return .ready(cached) }
            return .locked
        case .unpaired: return .unpaired
        }
    }

    /// A failure while the iPhone is locked that is not the gateway's answer (a token refresh the key could not
    /// sign, mostly) waits for the unlock: nothing is refused or deleted for it.
    static func isLockFailure(_ error: Error) -> Bool {
        guard isLocked, !(error is CancellationError) else { return false }
        return !(error is NuoError) && !(error is TranscriptionJob.Failed) && !(error is TranscriptionJob.Unreachable)
            && !(error is TranscriptionJob.Unreadable)
    }

    /// The gateway no longer accepts this iPhone: told plainly, never waited for.
    static func isRevoked(_ error: Error) -> Bool {
        switch error as? NuoError {
        case .unauthorized?, .reauthRequired?: true
        default: false
        }
    }

    /// Runs `work` whenever the iPhone gets unlocked.
    static func onUnlock(_ work: @escaping @MainActor () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { work() }
        }
    }

    static func backgroundWindow(_ name: String) -> () -> Void {
        var id = UIBackgroundTaskIdentifier.invalid
        id = UIApplication.shared.beginBackgroundTask(withName: name) {
            UIApplication.shared.endBackgroundTask(id)
        }
        return { if id != .invalid { UIApplication.shared.endBackgroundTask(id) } }
    }
}

/// Whether a failure only means « not now »: the gateway away or silent, a proxy answering for it, a busy gateway.
enum GatewayWait {
    static func isTransient(_ error: Error) -> Bool {
        if error is TranscriptionJob.Unreachable || error is TranscriptionJob.Unreadable { return true }
        switch error as? NuoError {
        case .offline?, .transport?: return true
        // A proxy's 403 has no gateway message; the gateway always says why it refuses.
        case let .server(status, message)?: return (status >= 500 && message.isEmpty) || status == 429 || status == 408 || (status == 403 && message.isEmpty)
        default: return false
        }
    }
}
