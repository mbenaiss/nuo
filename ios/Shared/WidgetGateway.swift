import Foundation

/// Minimal gateway client for extensions (widgets, App Intents), with the scoped token the app saved in the
/// shared keychain: `.widgets` is read-only, `.watch` may also prompt and cancel.
struct WidgetGateway: Sendable {
    let routes: [GatewayRoute]
    let token: String

    enum Failure: Error { case signedOut, offline, unauthorized, status(Int) }

    static func current(scope: SharedCredentials.Scope = .widgets) -> WidgetGateway? {
        guard let token = SharedCredentials.extensionToken(scope) else { return nil }
        let routes = SharedCredentials.routes()
        return routes.isEmpty ? nil : WidgetGateway(routes: routes, token: token)
    }

    /// Home address first, then the internet one when the first is unreachable.
    private func firstReachable<T>(_ body: (GatewayRoute) async throws -> T) async throws -> T {
        var lastError: Error = Failure.offline
        for route in routes {
            do { return try await body(route) } catch Failure.offline { lastError = Failure.offline }
        }
        throw lastError
    }

    func bots() async throws -> [Bot] { try await get("/api/bots") }
    func conversations() async throws -> [Conversation] { try await get("/api/conversations") }

    /// Merged agenda (`GET /api/calendar/events`, allowed to the `widgets` and `watch` tokens).
    func agenda(from: Date, to: Date) async throws -> [AgendaWireItem] {
        let format: (Date) -> String = { $0.formatted(.iso8601) }
        let query = "from=\(format(from))&to=\(format(to))".replacingOccurrences(of: "+", with: "%2B")
        struct Page: Decodable { let items: [AgendaWireItem] }
        let page: Page = try await get("/api/calendar/events?\(query)")
        return page.items
    }

    /// Open reminders, soonest first (`GET /api/reminders?scope=all`).
    func reminders() async throws -> [ReminderWireItem] { try await get("/api/reminders?scope=all") }

    /// Checks a reminder off, or back on; a repeating one moves to its next date instead.
    func setReminderDone(id: String, done: Bool) async throws {
        let path = "/api/reminders/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)/\(done ? "done" : "undone")"
        let _: ReminderWireItem = try await firstReachable { try await send("POST", path, route: $0) }
    }

    /// Cancels a running turn over a one-shot WebSocket; the gateway cancels by conversation id, whatever the socket.
    func cancel(conversationId: String) async throws {
        try await sendOnce(["type": "cancel", "conversationId": conversationId])
    }

    /// Sends a prompt over a one-shot WebSocket (reply from a notification while the app's socket is closed).
    /// The gateway runs the turn whatever the socket and pushes the answer to devices that are offline.
    func prompt(conversationId: String, text: String) async throws {
        try await sendOnce(["type": "prompt", "conversationId": conversationId, "text": text])
    }

    private func sendOnce(_ event: [String: String]) async throws {
        try await firstReachable { try await sendOnce(event, route: $0) }
    }

    private func sendOnce(_ event: [String: String], route: GatewayRoute) async throws {
        guard var components = URLComponents(url: route.baseURL, resolvingAgainstBaseURL: false) else { throw Failure.offline }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = "/api/ws"
        guard let url = components.url else { throw Failure.offline }
        var request = URLRequest(url: url, timeoutInterval: 10)
        for (name, value) in route.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        let payload = try JSONSerialization.data(withJSONObject: event)
        do {
            try await task.send(.string(String(decoding: payload, as: UTF8.self)))
        } catch {
            throw Failure.offline
        }
    }

    private func get<Reply: Decodable>(_ path: String) async throws -> Reply {
        try await firstReachable { try await get(path, route: $0) }
    }

    private func get<Reply: Decodable>(_ path: String, route: GatewayRoute) async throws -> Reply {
        try await send("GET", path, route: route)
    }

    private func send<Reply: Decodable>(_ method: String, _ path: String, route: GatewayRoute) async throws -> Reply {
        guard let url = URL(string: path, relativeTo: route.baseURL)?.absoluteURL else { throw Failure.offline }
        var request = URLRequest(url: url, timeoutInterval: route.isInternet ? 15 : 4)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in route.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: break
        case 401, 403: throw Failure.unauthorized
        default: throw Failure.status(status)
        }
        return try Self.decoder.decode(Reply.self, from: data)
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) { return date }
            if let date = try? Date(text, strategy: .iso8601) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date")
        }
        return decoder
    }
}

/// The fields of an agenda item the extensions show.
struct AgendaWireItem: Codable, Hashable, Sendable {
    var kind: String
    var id: String
    var title: String?
    var location: String?
    var conferenceUrl: String?
    var start: Date
    var end: Date
    var allDay: Bool
    var color: String?
    var busyOnly: Bool?
    var done: Bool?
    var status: String?
    var travelTimeSec: Int?
}

/// `nuo://` links opened by widgets, the Live Activity and notifications.
enum NuoLink: Hashable, Sendable {
    case conversation(id: String, botId: String?)
    case newConversation(botId: String)
    case voice(botId: String)

    init?(url: URL) {
        guard url.scheme == "nuo", let host = url.host() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch (host, parts.count) {
        case ("conversation", 1):
            let bot = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "bot" }?.value
            self = .conversation(id: parts[0], botId: bot)
        case ("bot", 2) where parts[1] == "new":
            self = .newConversation(botId: parts[0])
        case ("bot", 2) where parts[1] == "voice":
            self = .voice(botId: parts[0])
        default:
            return nil
        }
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = "nuo"
        switch self {
        case let .conversation(id, botId):
            components.host = "conversation"
            components.path = "/\(id)"
            if let botId { components.queryItems = [URLQueryItem(name: "bot", value: botId)] }
        case let .newConversation(botId):
            components.host = "bot"
            components.path = "/\(botId)/new"
        case let .voice(botId):
            components.host = "bot"
            components.path = "/\(botId)/voice"
        }
        return components.url!
    }
}
