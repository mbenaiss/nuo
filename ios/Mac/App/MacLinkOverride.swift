import Foundation

/// `nuo://` links the Mac resolves itself: the shared routers map them onto the iPhone's tabs, where they land
/// on the wrong screen of the sidebar.
enum MacLinkOverride: Equatable {
    /// `nuo://data` without a collection: the iPhone shows its Fichiers home, the Mac has a Collections screen.
    case collections

    init?(url: URL) {
        guard url.scheme == "nuo", let host = url.host() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch host {
        case "data" where parts.isEmpty: self = .collections
        default: return nil
        }
    }
}
