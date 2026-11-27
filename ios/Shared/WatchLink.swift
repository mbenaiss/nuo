import Foundation

/// Keys of the WatchConnectivity payloads exchanged between the iPhone app and the watch app.
enum WatchLink {
    static let gatewayURL = "gatewayURL"
    /// The watch-scoped extension token (docs/protocol.md, "Extension tokens").
    static let token = "token"
    /// Internet address and Cloudflare Access service token, for when the watch is away from home.
    static let publicURL = "publicURL"
    static let cfAccessClientId = "cfAccessClientId"
    static let cfAccessClientSecret = "cfAccessClientSecret"
    static let request = "request"
    static let requestCredentials = "credentials"
    static let requestPrompt = "prompt"
    static let conversationId = "conversationId"
    static let text = "text"
    static let ok = "ok"
    static let error = "error"
}
