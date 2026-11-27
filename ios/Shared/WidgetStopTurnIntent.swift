#if canImport(ActivityKit) && os(iOS)
import ActivityKit
import AppIntents
import Foundation

/// Lets the running app cancel a turn through its live socket instead of opening a second one.
@MainActor
enum WidgetIntentBridge {
    static var cancelTurn: (@MainActor (String) async -> Bool)?

    static func cancel(_ conversationId: String) async -> Bool {
        await cancelTurn?(conversationId) ?? false
    }
}

/// "Stop" button of the Live Activity. Compiled in the app and the extension so `perform` runs in the app process.
struct WidgetStopTurnIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop reply"
    static let isDiscoverable = false

    @Parameter(title: "Conversation")
    var conversationId: String

    init() {}

    init(conversationId: String) {
        self.conversationId = conversationId
    }

    func perform() async throws -> some IntentResult {
        let id = conversationId
        let handledByApp = await WidgetIntentBridge.cancel(id)
        if !handledByApp {
            try? await WidgetGateway.current(scope: .watch)?.cancel(conversationId: id)
            for activity in Activity<NuoActivityAttributes>.activities where activity.attributes.conversationId == id {
                var state = activity.content.state
                state.phase = .cancelled
                state.endedAt = .now
                await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(.now.addingTimeInterval(60)))
            }
        }
        return .result()
    }
}
#endif
