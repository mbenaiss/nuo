import Foundation

/// Gateway calls the share extension needs, authenticated with the share-scoped token the app saved in the
/// shared keychain (list bots and conversations, create a conversation, send a prompt).
struct ShareGateway: Sendable {
    let routes: [GatewayRoute]
    let token: String

    enum Failure: Error {
        case offline, unauthorized, tooLarge
        case rejected(status: Int, message: String?)
    }

    static func current() -> ShareGateway? {
        guard let token = SharedCredentials.extensionToken(.share) else { return nil }
        let routes = SharedCredentials.routes()
        return routes.isEmpty ? nil : ShareGateway(routes: routes, token: token)
    }

    func bots() async throws -> [Bot] {
        try await decode(send { request("/api/bots", route: $0) })
    }

    /// Newest conversation with the bot (the list comes newest first), if any.
    func latestConversation(botId: String) async throws -> Conversation? {
        let conversations: [Conversation] = try await decode(send { request("/api/conversations", route: $0, query: [URLQueryItem(name: "botId", value: botId)]) })
        return conversations.first
    }

    func createConversation(botId: String) async throws -> Conversation {
        let body = try JSONSerialization.data(withJSONObject: ["botId": botId])
        return try await decode(send { route in
            var request = request("/api/conversations", route: route, method: "POST")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            return request
        })
    }

    /// Uploads the prompt body from disk so base64 attachments never sit in memory as a whole.
    func prompt(conversationId: String, bodyFile: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let delegate = UploadProgressDelegate(handler: progress)
        for (index, route) in routes.enumerated() {
            var request = request("/api/conversations/\(conversationId)/prompt", route: route, method: "POST", timeout: 300)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let data: Data, response: URLResponse
            do {
                // Probe the home address cheaply before uploading a large body to it.
                if !route.isInternet, index < routes.count - 1 { _ = try await URLSession.shared.data(for: self.request("/api/health", route: route, timeout: 3)) }
                (data, response) = try await URLSession.shared.upload(for: request, fromFile: bodyFile, delegate: delegate)
            } catch {
                continue
            }
            try check(data: data, response: response)
            return
        }
        throw Failure.offline
    }

    private func request(_ path: String, route: GatewayRoute, method: String = "GET", query: [URLQueryItem] = [], timeout: TimeInterval = 20) -> URLRequest {
        let baseURL = route.baseURL
        var components = URLComponents(url: URL(string: path, relativeTo: baseURL)?.absoluteURL ?? baseURL, resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        var request = URLRequest(url: components?.url ?? baseURL, timeoutInterval: route.isInternet || timeout > 20 ? timeout : min(timeout, 5))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in route.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Home address first, then the internet one when the first is unreachable.
    private func send(_ make: (GatewayRoute) throws -> URLRequest) async throws -> Data {
        for route in routes {
            let data: Data, response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: make(route))
            } catch {
                continue
            }
            try check(data: data, response: response)
            return data
        }
        throw Failure.offline
    }

    private func check(data: Data, response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return
        case 401, 403: throw Failure.unauthorized
        case 413: throw Failure.tooLarge
        default:
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw Failure.rejected(status: status, message: message)
        }
    }

    private func decode<Reply: Decodable>(_ data: Data) throws -> Reply {
        try Self.decoder.decode(Reply.self, from: data)
    }

    static var decoder: JSONDecoder {
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

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let handler: @Sendable (Double) -> Void

    init(handler: @escaping @Sendable (Double) -> Void) { self.handler = handler }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        handler(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}

struct OutgoingAttachment: Sendable {
    let kind: String // image | file
    let mime: String
    let name: String?
    let byteCount: Int
    let fileURL: URL
}

/// Writes `{text, attachments}` as JSON, base64-encoding each file in chunks straight to disk.
enum PromptBodyWriter {
    static func write(text: String, attachments: [OutgoingAttachment], to destination: URL) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        func put(_ string: String) throws { try output.write(contentsOf: Data(string.utf8)) }

        try put("{\"text\":\(try json(text))")
        if !attachments.isEmpty {
            try put(",\"attachments\":[")
            for (index, attachment) in attachments.enumerated() {
                if index > 0 { try put(",") }
                var head = "{\"kind\":\(try json(attachment.kind)),\"mime\":\(try json(attachment.mime)),\"size\":\(attachment.byteCount)"
                if let name = attachment.name { head += ",\"name\":\(try json(name))" }
                try put(head + ",\"dataBase64\":\"")
                let input = try FileHandle(forReadingFrom: attachment.fileURL)
                defer { try? input.close() }
                // A multiple of 3 bytes, so chunk encodings concatenate into one valid base64 string.
                while let chunk = try autoreleasepool(invoking: { try input.read(upToCount: 3 * 256 * 1024) }), !chunk.isEmpty {
                    try output.write(contentsOf: chunk.base64EncodedData())
                }
                try put("\"}")
            }
            try put("]")
        }
        try put("}")
    }

    private static func json(_ string: String) throws -> String {
        String(decoding: try JSONEncoder().encode(string), as: UTF8.self)
    }
}
