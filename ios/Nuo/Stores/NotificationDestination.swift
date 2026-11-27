import Foundation

/// The screen a notification tap opens, read from the notification's `userInfo`.
///
/// Gateway pushes carry `destination: {kind, id, …}`. Local notifications (answers, reminders, event alerts, meeting
/// prompts) and pushes from older gateways only have flat keys, read in the same order as before `destination`
/// existed; anything else opens the app's home.
enum NotificationDestination: Equatable, Sendable {
    case conversation(id: String, botId: String?)
    case bot(id: String)
    /// `runId`: the run that notified (a command's failure), opened with its output.
    case task(id: String, botId: String?, runId: String? = nil)
    case reminder(id: String)
    case event(id: String)
    /// A Mac meeting prompt: the calendar event it is about, or the Réunions screen.
    case meeting(eventId: String?)
    case bookings
    case browser
    case settings
    case link(URL)
    case home

    static let meetingCategory = "nuo.meeting"
    static let securityCategory = "nuo.security"

    init(userInfo: [AnyHashable: Any], category: String) {
        if let typed = (userInfo["destination"] as? [String: Any]).flatMap(Self.typed) {
            self = typed
        } else {
            self = Self.legacy(userInfo, category: category)
        }
    }

    init(_ alert: AlertDestination) {
        var d: [String: Any] = ["kind": alert.kind]
        if let id = alert.id { d["id"] = id }
        if let botId = alert.botId { d["botId"] = botId }
        if let runId = alert.runId { d["runId"] = runId }
        if let url = alert.url { d["url"] = url }
        self = Self.typed(d) ?? .home
    }

    private static func typed(_ d: [String: Any]) -> NotificationDestination? {
        let id = (d["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let botId = d["botId"] as? String
        switch d["kind"] as? String {
        case "conversation": return id.map { .conversation(id: $0, botId: botId) }
        case "bot": return id.map { .bot(id: $0) }
        case "task": return id.map { .task(id: $0, botId: botId, runId: d["runId"] as? String) }
        case "reminder": return id.map { .reminder(id: $0) }
        case "event": return id.map { .event(id: $0) }
        case "booking": return .bookings
        case "browser": return .browser
        case "settings": return .settings
        case "link": return (d["url"] as? String).flatMap(nuoURL).map { .link($0) }
        case "home": return .home
        default: return nil
        }
    }

    private static func legacy(_ info: [AnyHashable: Any], category: String) -> NotificationDestination {
        let string = { (key: String) -> String? in (info[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        if let id = string("reminderId") { return .reminder(id: id) }
        if category == meetingCategory { return .meeting(eventId: string("eventId")) }
        if let id = string("eventId") { return .event(id: id) }
        if let url = string("url").flatMap(nuoURL) { return .link(url) }
        if string("bookingId") != nil { return .bookings }
        if category == securityCategory { return .settings }
        if let id = string("conversationId") { return .conversation(id: id, botId: string("botId")) }
        if let id = string("taskId") { return .task(id: id, botId: string("botId"), runId: string("runId")) }
        if let id = string("botId") { return .bot(id: id) }
        return .home
    }

    private static func nuoURL(_ link: String) -> URL? {
        guard let url = URL(string: link), url.scheme == "nuo" else { return nil }
        return url
    }
}
