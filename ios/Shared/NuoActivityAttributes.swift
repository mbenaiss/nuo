#if canImport(ActivityKit)
import ActivityKit
import Foundation

/// Live Activity of a bot turn in progress (lock screen + Dynamic Island). Shared by the app and the widget extension.
struct NuoActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: Phase
        var steps: Int
        var currentTool: String?
        var preview: String?
        /// Opening of the final answer, shown once the turn is done.
        var answer: String?
        var startedAt: Date
        var endedAt: Date?

        enum Phase: String, Codable, Hashable {
            case thinking, working, answering, done, failed, cancelled

            var isRunning: Bool { self == .thinking || self == .working || self == .answering }
        }
    }

    var botId: String
    var botName: String
    var botEmoji: String
    var botColor: String
    var conversationId: String
}
#endif
