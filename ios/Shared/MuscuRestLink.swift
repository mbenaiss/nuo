import Foundation

/// The Muscu screen's rest, sent by the iPhone to the watch so the countdown and the tap at its end are on the wrist.
enum MuscuRestLink {
    static let key = "muscu.rest"
    private static let until = "until"
    private static let total = "total"
    private static let title = "title"
    private static let next = "next"
    private static let sentAt = "sentAt"

    struct Rest: Equatable, Sendable {
        var until: Date
        /// Length of the whole rest, in seconds, for the ring.
        var total: Int
        /// "Rest" or "Block change", already localized by the iPhone.
        var title: String
        /// What comes after: "Block B · set 2/3".
        var next: String
    }

    enum Message: Equatable, Sendable {
        case start(Rest, sentAt: Date)
        case stop(sentAt: Date)

        var sentAt: Date {
            switch self {
            case let .start(_, at), let .stop(at): at
            }
        }
    }

    /// `rest` nil ends the rest on the watch (skipped, or the session is over).
    static func payload(_ rest: Rest?, sentAt: Date = .now) -> [String: Any] {
        guard let rest else { return [key: "stop", Self.sentAt: sentAt.timeIntervalSince1970] }
        return [
            key: "start",
            until: rest.until.timeIntervalSince1970,
            total: rest.total,
            title: rest.title,
            next: rest.next,
            Self.sentAt: sentAt.timeIntervalSince1970,
        ]
    }

    /// Nil for any other WatchConnectivity payload.
    static func decode(_ payload: [String: Any]) -> Message? {
        guard let kind = payload[key] as? String, let sent = payload[sentAt] as? Double else { return nil }
        let at = Date(timeIntervalSince1970: sent)
        switch kind {
        case "stop":
            return .stop(sentAt: at)
        case "start":
            guard let end = payload[until] as? Double, let length = payload[total] as? Int else { return nil }
            return .start(Rest(until: Date(timeIntervalSince1970: end), total: length, title: payload[title] as? String ?? String(localized: "Rest"),
                               next: payload[next] as? String ?? ""), sentAt: at)
        default:
            return nil
        }
    }
}
