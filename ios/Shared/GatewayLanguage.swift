import Foundation

/// The `Accept-Language` of every request to the gateway: the user's languages, the most preferred first. The gateway
/// writes its own texts in the first one it has a catalog for and has the bots answer in the first one
/// (docs/protocol.md, "Language"). Set explicitly because URLSession's own value only lists the app's localizations,
/// and a WebSocket upgrade may carry none.
enum GatewayLanguage {
    static let header = "Accept-Language"

    static func acceptLanguage(_ preferred: [String] = Locale.preferredLanguages) -> String? {
        let tags = preferred.filter { !$0.isEmpty }.prefix(5)
        guard !tags.isEmpty else { return nil }
        return tags.enumerated()
            .map { index, tag in index == 0 ? tag : "\(tag);q=0.\(10 - index)" }
            .joined(separator: ", ")
    }
}
