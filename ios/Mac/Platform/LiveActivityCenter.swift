import Foundation

/// The Mac has no Live Activities: the running turn shows in the window and the menu bar instead.
@MainActor
final class LiveActivityCenter {
    static let shared = LiveActivityCenter()

    private init() {}

    func attach(transport: any LiveTransport, api: any NuoAPI) {}
    func begin(bot: Bot, conversationId: String) {}
    func abort(conversationId: String, message: String) {}
    func hasActivity(conversationId: String) -> Bool { false }
}
