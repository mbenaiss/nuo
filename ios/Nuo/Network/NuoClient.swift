import Foundation

struct HealthInfo: Codable, Sendable {
    var ok: Bool
    var version: String?
    var agents: [AgentInfo]
}

enum NuoError: LocalizedError, Equatable {
    case invalidURL
    case offline
    case unauthorized
    /// The gateway no longer knows this device (revoked, or paired before device keys).
    case reauthRequired
    /// Face ID / Touch ID was cancelled for a sensitive action.
    case stepUpCancelled
    case notFound
    case server(status: Int, message: String)
    case decoding(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: String(localized: "The gateway address is invalid.")
        case .offline: String(localized: "Gateway unreachable. Check your connection or the address.")
        case .unauthorized: String(localized: "Access denied. The iPhone needs to be paired again.")
        case .reauthRequired: String(localized: "This device needs to be paired again (pairing code + 2FA code).")
        case .stepUpCancelled: String(localized: "Action canceled: the Face ID / passcode confirmation didn't go through.")
        case .notFound: String(localized: "Item not found.")
        case let .server(status, message): message.isEmpty ? String(localized: "Gateway error (\(status)).") : message
        case let .decoding(detail): String(localized: "Unexpected response from the gateway (\(detail)).")
        case let .transport(detail): detail
        }
    }
}

/// Everything the UI needs from the gateway's REST API; `NuoClient` talks HTTP, `DemoBackend` fakes it.
protocol NuoAPI: NuoDataAPI, NuoCalendarAPI {
    func health() async throws -> HealthInfo
    func agents() async throws -> [AgentInfo]
    func tools() async throws -> [ToolServer]
    func machineTools() async throws -> [MachineTool]
    func bots() async throws -> [Bot]
    func bot(id: String) async throws -> Bot
    func createBot(name: String, fromBotId: String?) async throws -> Bot
    func saveDraft(botId: String, config: BotConfig) async throws -> Bot
    func discardDraft(botId: String) async throws -> Bot
    func publish(botId: String, note: String?) async throws -> Bot
    func setPermissions(botId: String, policy: PermissionPolicy) async throws -> Bot
    func versions(botId: String) async throws -> [BotVersion]
    func rollback(botId: String, version: Int) async throws -> Bot
    func deleteBot(id: String) async throws
    func conversations(botId: String?) async throws -> [Conversation]
    /// Across every bot, or this one only.
    func searchConversations(_ text: String, botId: String?) async throws -> [ConversationSearchHit]
    /// With the running turn in full (`turn`); older gateways answer 404/405.
    func conversation(id: String) async throws -> Conversation
    func createConversation(botId: String, useDraft: Bool) async throws -> Conversation
    func messages(conversationId: String) async throws -> [Message]
    func deleteConversation(id: String) async throws
    func registerDevice(apnsToken: String, environment: String) async throws
    func registerLiveActivity(conversationId: String, pushToken: String, environment: String) async throws
    func media(path: String) async throws -> Data
    func schedules(botId: String?) async throws -> [ScheduledTask]
    func createSchedule(_ draft: ScheduledTaskDraft) async throws -> ScheduledTask
    func updateSchedule(id: String, patch: ScheduledTaskPatch) async throws -> ScheduledTask
    func deleteSchedule(id: String) async throws
    func runSchedule(id: String) async throws -> TaskRun
    func scheduleRuns(id: String) async throws -> [TaskRun]
    func alerts() async throws -> [AlertItem]
    /// Marks these alerts read, or all of them when `ids` is nil.
    func markAlertsRead(ids: [String]?) async throws
    func deleteAlert(id: String) async throws
    /// Deletes the alerts already read, or all of them when `readOnly` is false.
    func deleteAlerts(readOnly: Bool) async throws
    func memory(botId: String) async throws -> BotMemory
    /// Replaces the whole memory (64 KB max).
    func writeMemory(botId: String, content: String) async throws -> BotMemory
    /// Appends one dated line (500 characters max).
    func addMemory(botId: String, fact: String) async throws -> BotMemory
    /// How fast each bot answered over the last `days` days; `scheduled` counts scheduled tasks too.
    func latency(days: Int, scheduled: Bool) async throws -> LatencyReport
}

/// Body of `POST /api/schedules`.
struct ScheduledTaskDraft: Codable, Sendable {
    var botId: String
    var title: String
    var prompt: String
    var schedule: TaskSchedule
    var conversation: String?
    var notify: Bool?
    var enabled: Bool?
    var action: TaskAction?
}

/// Body of `PATCH /api/schedules/:id`; nil fields are left untouched.
struct ScheduledTaskPatch: Codable, Sendable {
    var title: String?
    var prompt: String?
    var schedule: TaskSchedule?
    var enabled: Bool?
    var notify: Bool?
    var conversation: String?
    /// Replaces the whole action.
    var action: TaskAction?
}

struct NuoClient: NuoAPI {
    let baseURL: URL
    /// Supplies access tokens and the route (home or internet address); nil before pairing.
    let auth: AuthSession?
    private let session: URLSession

    init(baseURL: URL, auth: AuthSession?, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.auth = auth
        self.session = session
    }

    func health() async throws -> HealthInfo { try await request("GET", "/api/health") }
    func agents() async throws -> [AgentInfo] { try await request("GET", "/api/agents") }
    func tools() async throws -> [ToolServer] { try await request("GET", "/api/tools") }
    func machineTools() async throws -> [MachineTool] { try await request("GET", "/api/machine/tools") }
    func bots() async throws -> [Bot] { try await request("GET", "/api/bots") }
    func bot(id: String) async throws -> Bot { try await request("GET", "/api/bots/\(id)") }

    func createBot(name: String, fromBotId: String?) async throws -> Bot {
        struct Body: Encodable { let name: String; let fromBotId: String? }
        return try await request("POST", "/api/bots", body: Body(name: name, fromBotId: fromBotId))
    }

    func saveDraft(botId: String, config: BotConfig) async throws -> Bot {
        try await request("PUT", "/api/bots/\(botId)/draft", body: config)
    }

    func discardDraft(botId: String) async throws -> Bot { try await request("DELETE", "/api/bots/\(botId)/draft") }

    func publish(botId: String, note: String?) async throws -> Bot {
        struct Body: Encodable { let note: String? }
        return try await request("POST", "/api/bots/\(botId)/publish", body: Body(note: note))
    }

    func setPermissions(botId: String, policy: PermissionPolicy) async throws -> Bot {
        struct Body: Encodable { let permissionPolicy: PermissionPolicy }
        return try await request("PUT", "/api/bots/\(botId)/permissions", body: Body(permissionPolicy: policy))
    }

    func versions(botId: String) async throws -> [BotVersion] { try await request("GET", "/api/bots/\(botId)/versions") }

    func rollback(botId: String, version: Int) async throws -> Bot {
        struct Body: Encodable { let version: Int }
        return try await request("POST", "/api/bots/\(botId)/rollback", body: Body(version: version))
    }

    func deleteBot(id: String) async throws { try await send("DELETE", "/api/bots/\(id)") }

    func conversations(botId: String?) async throws -> [Conversation] {
        var path = "/api/conversations"
        if let botId, let encoded = botId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "?botId=\(encoded)"
        }
        return try await request("GET", path)
    }

    func conversation(id: String) async throws -> Conversation { try await request("GET", "/api/conversations/\(id)") }

    func searchConversations(_ text: String, botId: String?) async throws -> [ConversationSearchHit] {
        var items = URLComponents()
        items.queryItems = [URLQueryItem(name: "q", value: text)] + (botId.map { [URLQueryItem(name: "botId", value: $0)] } ?? [])
        return try await request("GET", "/api/conversations/search?\(items.percentEncodedQuery ?? "")")
    }

    func createConversation(botId: String, useDraft: Bool) async throws -> Conversation {
        struct Body: Encodable { let botId: String; let useDraft: Bool }
        return try await request("POST", "/api/conversations", body: Body(botId: botId, useDraft: useDraft))
    }

    func messages(conversationId: String) async throws -> [Message] {
        try await request("GET", "/api/conversations/\(conversationId)/messages")
    }

    func deleteConversation(id: String) async throws { try await send("DELETE", "/api/conversations/\(id)") }

    func registerDevice(apnsToken: String, environment: String) async throws {
        struct Body: Encodable { let apnsToken: String; let environment: String }
        try await send("POST", "/api/devices", body: Body(apnsToken: apnsToken, environment: environment))
    }

    func registerLiveActivity(conversationId: String, pushToken: String, environment: String) async throws {
        struct Body: Encodable { let conversationId: String; let pushToken: String; let environment: String }
        try await send("POST", "/api/live-activities", body: Body(conversationId: conversationId, pushToken: pushToken, environment: environment))
    }

    func media(path: String) async throws -> Data {
        let (data, _) = try await perform(makeRequest("GET", path, body: Optional<String>.none))
        return data
    }

    func schedules(botId: String?) async throws -> [ScheduledTask] {
        var path = "/api/schedules"
        if let botId, let encoded = botId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "?botId=\(encoded)"
        }
        return try await request("GET", path)
    }

    func createSchedule(_ draft: ScheduledTaskDraft) async throws -> ScheduledTask {
        try await request("POST", "/api/schedules", body: draft)
    }

    func updateSchedule(id: String, patch: ScheduledTaskPatch) async throws -> ScheduledTask {
        try await request("PATCH", "/api/schedules/\(id)", body: patch)
    }

    func deleteSchedule(id: String) async throws { try await send("DELETE", "/api/schedules/\(id)") }

    func runSchedule(id: String) async throws -> TaskRun {
        try await request("POST", "/api/schedules/\(id)/run", body: Optional<String>.none)
    }

    func scheduleRuns(id: String) async throws -> [TaskRun] { try await request("GET", "/api/schedules/\(id)/runs") }

    func alerts() async throws -> [AlertItem] { try await request("GET", "/api/alerts") }

    func markAlertsRead(ids: [String]?) async throws {
        struct Body: Encodable { let ids: [String]? }
        try await send("POST", "/api/alerts/read", body: Body(ids: ids))
    }

    func deleteAlert(id: String) async throws { try await send("DELETE", "/api/alerts/\(id)") }

    func deleteAlerts(readOnly: Bool) async throws { try await send("DELETE", readOnly ? "/api/alerts?read=1" : "/api/alerts") }

    func memory(botId: String) async throws -> BotMemory { try await request("GET", "/api/bots/\(botId)/memory") }

    func writeMemory(botId: String, content: String) async throws -> BotMemory {
        try await request("PUT", "/api/bots/\(botId)/memory", body: ["content": content])
    }

    func addMemory(botId: String, fact: String) async throws -> BotMemory {
        try await request("POST", "/api/bots/\(botId)/memory", body: ["fact": fact])
    }

    func latency(days: Int, scheduled: Bool) async throws -> LatencyReport {
        try await request("GET", "/api/metrics/latency?days=\(days)\(scheduled ? "&scheduled=1" : "")")
    }

    // MARK: - Plumbing

    func request<Reply: Decodable>(_ method: String, _ path: String) async throws -> Reply {
        try await request(method, path, body: Optional<String>.none)
    }

    func request<Reply: Decodable, Body: Encodable>(_ method: String, _ path: String, body: Body?) async throws -> Reply {
        let (data, _) = try await perform(makeRequest(method, path, body: body))
        do {
            return try NuoJSON.decoder().decode(Reply.self, from: data)
        } catch {
            throw NuoError.decoding(String(describing: error).prefix(160).description)
        }
    }

    func send(_ method: String, _ path: String) async throws {
        _ = try await perform(makeRequest(method, path, body: Optional<String>.none))
    }

    func send<Body: Encodable>(_ method: String, _ path: String, body: Body) async throws {
        _ = try await perform(makeRequest(method, path, body: body))
    }

    func makeRequest<Body: Encodable>(_ method: String, _ path: String, body: Body?) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { throw NuoError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try NuoJSON.encoder().encode(body)
        }
        return request
    }

    /// Sends with a fresh access token on the current route. Retries once on the other address when the
    /// gateway is unreachable, once after a refresh when the token was refused, and once after a Face ID
    /// step-up when the route is sensitive (403 `stepUp`). A request that is not `replayable` (a billed
    /// transcription) goes to the other address only when it never left the device: after a timeout or a dropped
    /// connection the gateway may already be working on it.
    func perform(_ request: URLRequest, replayable: Bool = true) async throws -> (Data, HTTPURLResponse) {
        guard let auth else {
            do {
                return try check(await execute(request))
            } catch is Unreached {
                throw NuoError.offline
            }
        }
        var route = await auth.router.route()
        var switched = false, refreshed = false, steppedUp = false
        while true {
            let token = try await auth.token()
            var routed = request.routed(to: route)
            routed.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let data: Data, http: HTTPURLResponse
            do {
                (data, http) = try await execute(routed)
            } catch let unreached as Unreached {
                guard !switched, replayable || !unreached.mayHaveArrived,
                      let other = await auth.router.alternative(to: route) else { throw NuoError.offline }
                route = other
                switched = true
                continue
            }
            // Only refusals carry these flags; parsing every reply here was a second full parse of large ones.
            let reply = [401, 403].contains(http.statusCode) ? (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] : nil
            if http.statusCode == 403, !route.isInternet, !switched, reply?["error"] == nil {
                await auth.router.homeRefused()
                if let other = await auth.router.alternative(to: route) {
                    route = other
                    switched = true
                    continue
                }
            }
            if http.statusCode == 401 {
                if reply?["reauth"] as? Bool == true {
                    auth.reportReauth(message: reply?["error"] as? String ?? "")
                    throw NuoError.reauthRequired
                }
                if !refreshed {
                    await auth.invalidate(token)
                    refreshed = true
                    continue
                }
            }
            if http.statusCode == 403, reply?["stepUp"] as? Bool == true, !steppedUp {
                let reason = reply?["reason"] as? String
                try await auth.stepUp(reason: StepUpReason.prompt(for: reason), force: StepUpReason.isSingleUse(reason),
                                      boundTo: StepUpReason.isBound(reason) ? reason : nil)
                steppedUp = true
                continue
            }
            return try check((data, http))
        }
    }

    private func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                throw Unreached(mayHaveArrived: false)
            case .timedOut, .networkConnectionLost:
                throw Unreached(mayHaveArrived: true)
            default:
                throw NuoError.transport(error.localizedDescription)
            }
        }
        guard let http = response as? HTTPURLResponse else { throw NuoError.transport(String(localized: "Invalid response")) }
        return (data, http)
    }

    /// The gateway did not answer; `mayHaveArrived` once the request may have been sent before the failure.
    private struct Unreached: Error {
        let mayHaveArrived: Bool
    }

    private func check(_ result: (Data, HTTPURLResponse)) throws -> (Data, HTTPURLResponse) {
        let (data, http) = result
        switch http.statusCode {
        case 200..<300:
            return (data, http)
        case 403:
            // The secrets' refusals say why (home only, Face ID key to set up): the screens need the reason.
            struct Refusal: Decodable { let error: String?; let lanOnly: Bool?; let actionKey: Bool?; let action: Bool? }
            if let r = try? JSONDecoder().decode(Refusal.self, from: data), let error = r.error, r.lanOnly == true || r.actionKey == true || r.action == true {
                throw NuoError.server(status: 403, message: error)
            }
            throw NuoError.unauthorized
        case 401:
            throw NuoError.unauthorized
        case 404:
            throw NuoError.notFound
        default:
            struct Failure: Decodable { let error: String }
            let message = (try? JSONDecoder().decode(Failure.self, from: data))?.error ?? ""
            throw NuoError.server(status: http.statusCode, message: message)
        }
    }
}
