import Foundation

/// Whether to offer the relay access by itself, decided only from what is known for sure: a Keychain that cannot be
/// read now, or a gateway that cannot be asked, decide nothing (and never replace a working key).
enum RelayPlan {
    enum LocalKey: Equatable {
        case key(deviceId: String, thumbprint: String)
        case absent
        case unreadable
    }

    struct Server: Equatable, Decodable {
        let registered: Bool
        let thumbprint: String?
    }

    /// True when the owner should be asked (consent screen) to set the access up or to make its key again.
    static func shouldOffer(local: LocalKey, server: Server?, deviceId: String, isOwner: Bool, atHome: Bool, declined: Bool) -> Bool {
        guard isOwner, atHome, !declined, let server else { return false }
        switch local {
        case .unreadable:
            return false
        case .absent:
            return true
        case let .key(keyDevice, thumbprint):
            return !(server.registered && keyDevice == deviceId && server.thumbprint == thumbprint)
        }
    }
}
