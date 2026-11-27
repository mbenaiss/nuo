#if canImport(ActivityKit)
import ActivityKit
import Foundation

/// Live Activity of a gym session on the Muscu screen: the set to do, or the rest counting down. Shared by the app
/// and the widget extension.
struct MuscuActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// "Block B · set 2/3", or what comes after the rest.
        var step: String
        /// Set while resting: the countdown runs to it without the app.
        var restUntil: Date?
        var restTotal: Int?
        var setsDone: Int
        var setsTotal: Int
    }

    var sessionName: String
    var startedAt: Date
}

extension MuscuActivityAttributes {
    static let link = URL(string: "nuo://muscu")!
}
#endif
