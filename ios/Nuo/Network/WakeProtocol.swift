import Foundation

/// A webhook that wakes a bot (`GET /api/bots/:id/wake`); its token is never listed.
struct WakeHook: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var notify: Bool
    var calls: Int
    var lastCalledAt: Date?
    var createdAt: Date

    var activity: String {
        calls == 0 ? String(localized: "Never called") : String(localized: "\(calls) calls")
    }
}

/// What wakes a bot from outside: its mail address and its webhooks (docs/protocol.md, “Wake-ups from outside”).
struct BotWake: Codable, Equatable, Sendable {
    /// Nil until the gateway has a mail domain.
    var email: String?
    var mailAlias: String?
    /// False until the gateway has a hooks host: no webhook can be created.
    var hooksEnabled: Bool
    var hooks: [WakeHook]
}

/// `POST /api/bots/:id/hooks`: the only answer that carries the token, inside `url`.
struct CreatedWakeHook: Codable, Sendable {
    var hook: WakeHook
    var token: String
    var url: URL
}

enum WakeHookName {
    static let maxLength = 60

    /// The name the gateway accepts, or nil.
    static func normalized(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name.count > maxLength ? nil : name
    }
}

/// What the bot settings show for wake-ups, from what the last load left behind.
enum BotWakeDisplay: Equatable {
    /// Not loaded yet, or a gateway that predates wake-ups.
    case hidden
    case loadFailed(String)
    case loaded(BotWake, error: String?)

    static func of(wake: BotWake?, error: String?) -> Self {
        if let wake { return .loaded(wake, error: error) }
        if let error { return .loadFailed(error) }
        return .hidden
    }
}
