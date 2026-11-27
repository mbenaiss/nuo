import Foundation

enum WatchError: LocalizedError, Equatable {
    case invalidURL
    case offline
    case unauthorized
    case notFound
    case server(String)
    case decoding

    var errorDescription: String? {
        switch self {
        case .invalidURL: String(localized: "Invalid gateway address.")
        case .offline: String(localized: "Gateway unreachable.")
        case .unauthorized: String(localized: "Access denied. Pair the iPhone again.")
        case .notFound: String(localized: "Not found.")
        case let .server(message): message.isEmpty ? String(localized: "Gateway error.") : message
        case .decoding: String(localized: "Unexpected response.")
        }
    }
}

/// The slice of the gateway REST API the watch needs.
protocol WatchAPI: Sendable {
    func bots() async throws -> [Bot]
    func conversations(botId: String?) async throws -> [Conversation]
    func createConversation(botId: String) async throws -> Conversation
    func messages(conversationId: String) async throws -> [Message]
}

struct WatchClient: WatchAPI {
    let baseURL: URL
    let token: String

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    func bots() async throws -> [Bot] { try await get("/api/bots") }

    func conversations(botId: String?) async throws -> [Conversation] {
        var path = "/api/conversations"
        if let botId, let encoded = botId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "?botId=\(encoded)"
        }
        return try await get(path)
    }

    func createConversation(botId: String) async throws -> Conversation {
        struct Body: Encodable { let botId: String; let useDraft: Bool }
        let body = try NuoJSON.encoder().encode(Body(botId: botId, useDraft: false))
        return try await decode(perform("POST", "/api/conversations", body: body))
    }

    func messages(conversationId: String) async throws -> [Message] {
        try await get("/api/conversations/\(conversationId)/messages")
    }

    private func get<Reply: Decodable>(_ path: String) async throws -> Reply {
        try await decode(perform("GET", path, body: nil))
    }

    private func decode<Reply: Decodable>(_ data: Data) throws -> Reply {
        do {
            return try NuoJSON.decoder().decode(Reply.self, from: data)
        } catch {
            throw WatchError.decoding
        }
    }

    private func perform(_ method: String, _ path: String, body: Data?) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { throw WatchError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw WatchError.offline
        }
        guard let http = response as? HTTPURLResponse else { throw WatchError.offline }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw WatchError.unauthorized
        case 404: throw WatchError.notFound
        default:
            struct Failure: Decodable { let error: String }
            throw WatchError.server((try? JSONDecoder().decode(Failure.self, from: data))?.error ?? "")
        }
    }
}
