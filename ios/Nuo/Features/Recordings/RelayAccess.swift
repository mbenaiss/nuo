import Foundation

/// The watch's way to the gateway while the iPhone is locked: a `relay` token signed for with the relay key, which
/// reaches a short dictation, the bots by name, and the conversations it opens (docs/protocol.md, « Relay access »).
/// Only `WatchAskRelay` uses it, and only when the app's own access cannot sign; nothing else in the app sees it.
actor RelayClient {
    static let shared = RelayClient()

    enum Failure: Error, Equatable {
        /// No relay key on this iPhone, or the gateway no longer knows it.
        case unavailable
        case unreachable
        /// Not for the relay (a bot it cannot restrict): it waits for the unlock and goes through the app.
        case outOfScope
        /// The relay's hourly limit: it waits for the unlock too.
        case limited
        case refused(status: Int, message: String)
    }

    struct BotSummary: Decodable, Sendable {
        let id: String
        let name: String
        let emoji: String
        let overview: Bool?
    }

    struct TurnView: Decodable, Sendable {
        struct Turn: Decodable, Sendable {
            let text: String?
            let currentTool: String?
            let permission: TurnSnapshot.Permission?
        }
        let turn: Turn?
        /// A tool was refused during the request (the relay can only add): it waits for the unlock.
        let waitsForUnlock: Bool?
    }

    private var token: (value: String, expiresAt: Date)?
    private var router: GatewayRouter?

    nonisolated static var isAvailable: Bool { RelayKey.load() != nil }

    private func route() async -> GatewayRoute {
        let gateway = AppIdentity.gatewayURL
        let router = router ?? GatewayRouter.fromSharedCredentials(fallbackLAN: gateway)
        self.router = router
        return await router.route()
    }

    /// A token from the relay key's signature of a fresh nonce; kept until a minute before it expires.
    private func relayToken(route: GatewayRoute) async throws -> String {
        if let token, token.expiresAt.timeIntervalSinceNow > 60 { return token.value }
        guard let key = RelayKey.load() else { throw Failure.unavailable }
        let (status, challenge) = try await call { try await AuthHTTP.send("GET", "/api/auth/challenge", route: route) }
        guard status == 200, let nonce = challenge["nonce"] as? String else { throw Failure.unreachable }
        let signature = try key.sign(RelayKey.message(deviceId: key.deviceId, nonce: nonce))
        let (minted, reply) = try await call {
            try await AuthHTTP.send("POST", "/api/auth/relay-token", route: route,
                                    body: ["deviceId": key.deviceId, "nonce": nonce, "signature": signature.base64EncodedString()])
        }
        guard minted == 200, let value = reply["token"] as? String else {
            if minted == 401 { throw Failure.unavailable }
            throw Failure.refused(status: minted, message: reply["error"] as? String ?? "")
        }
        let expiresAt = (reply["expiresAt"] as? String).flatMap(AuthHTTP.date) ?? Date().addingTimeInterval(14 * 60)
        token = (value, expiresAt)
        return value
    }

    private func call<T>(_ work: () async throws -> T) async throws -> T {
        do { return try await work() } catch { throw Failure.unreachable }
    }

    /// One request with the relay token; a token the gateway no longer takes is signed for again once.
    private func send(_ method: String, _ path: String, body: Data? = nil, contentType: String = "application/json", timeout: TimeInterval = 30) async throws -> Data {
        let route = await route()
        for attempt in 0..<2 {
            let bearer = try await relayToken(route: route)
            guard let url = URL(string: path, relativeTo: route.baseURL)?.absoluteURL else { throw Failure.unreachable }
            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.httpMethod = method
            for (name, value) in route.headers { request.setValue(value, forHTTPHeaderField: name) }
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            if let body {
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
                request.httpBody = body
            }
            let (data, response) = try await call { try await URLSession.shared.data(for: request) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, attempt == 0 {
                token = nil
                continue
            }
            guard (200..<300).contains(status) else {
                if status == 401 { throw Failure.unavailable }
                let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let message = reply?["error"] as? String ?? ""
                if status == 409, reply?["waitsForUnlock"] as? Bool == true { throw Failure.outOfScope }
                if status == 429, !message.isEmpty { throw Failure.limited }
                // A proxy's answer has no gateway message: the gateway away, not refusing.
                if status >= 500 || status == 429 || (status == 403 && message.isEmpty) { throw Failure.unreachable }
                throw Failure.refused(status: status, message: message)
            }
            return data
        }
        throw Failure.unavailable
    }

    func transcribe(_ form: TranscriptionForm, timeout: TimeInterval) async throws -> CloudTranscript {
        let data = try await send("POST", "/api/transcriptions", body: form.body, contentType: form.contentType, timeout: timeout)
        return try NuoJSON.decoder().decode(CloudTranscript.self, from: data)
    }

    func bots() async throws -> [BotSummary] {
        try NuoJSON.decoder().decode([BotSummary].self, from: try await send("GET", "/api/bots"))
    }

    func createConversation(botId: String) async throws -> String {
        struct Created: Decodable { let id: String }
        let body = try JSONEncoder().encode(["botId": botId])
        return try NuoJSON.decoder().decode(Created.self, from: try await send("POST", "/api/conversations", body: body)).id
    }

    /// The id of the request's own message: its answer is the assistant message after it.
    func prompt(conversationId: String, text: String) async throws -> String {
        struct Sent: Decodable { let messageId: String }
        let data = try await send("POST", "/api/conversations/\(conversationId)/prompt", body: try JSONEncoder().encode(["text": text]))
        return try NuoJSON.decoder().decode(Sent.self, from: data).messageId
    }

    func turn(conversationId: String) async throws -> TurnView {
        try NuoJSON.decoder().decode(TurnView.self, from: try await send("GET", "/api/conversations/\(conversationId)"))
    }

    func messages(conversationId: String) async throws -> [Message] {
        try NuoJSON.decoder().decode([Message].self, from: try await send("GET", "/api/conversations/\(conversationId)/messages"))
    }

    func answer(conversationId: String, requestId: String, optionId: String) async throws {
        _ = try await send("POST", "/api/conversations/\(conversationId)/permission",
                           body: try JSONEncoder().encode(["requestId": requestId, "optionId": optionId]))
    }

    /// The key went (revoked here or on the gateway): forget its token too.
    func reset() {
        token = nil
    }
}

/// Sets the relay key up, only after the owner said yes on a screen that explains it (offered by itself once, at home,
/// on the owner's profile; never again after « Plus tard »), behind a Face ID given for that action alone;
/// « Sécurité › Accès de relais pour la montre » shows it, revokes it and makes a new one.
@MainActor
enum RelayEnrollment {
    private static let declinedKey = "nuo.relay.declined"
    private static var checked = false

    enum EnrollmentError: Error, Equatable, LocalizedError {
        case awayFromHome
        case notOwner
        case noSecureEnclave

        var errorDescription: String? {
            switch self {
            case .awayFromHome: String(localized: "Relay access is set up from home or over the VPN.")
            case .notOwner: String(localized: "Relay access is reserved for the main profile.")
            case .noSecureEnclave: String(localized: "This device cannot keep the relay key in its secure chip.")
            }
        }
    }

    typealias Status = RelayPlan.Server

    /// Once per launch: whether to show the consent screen. Nothing is asked (no Face ID) here.
    static func shouldOffer(client: NuoClient, deviceId: String?, profileId: String?) async -> Bool {
        guard !checked, let deviceId else { return false }
        checked = true
        let isOwner = profileId == "owner"
        let declined = UserDefaults.standard.bool(forKey: declinedKey)
        guard isOwner, !declined, await atHome(client) else { return false }
        return RelayPlan.shouldOffer(local: localKey(), server: try? await status(client: client), deviceId: deviceId,
                                     isOwner: isOwner, atHome: true, declined: declined)
    }

    /// « Plus tard », or Face ID cancelled: never offered by itself again (Sécurité still sets it up).
    static func decline() {
        UserDefaults.standard.set(true, forKey: declinedKey)
    }

    static func localKey() -> RelayPlan.LocalKey {
        switch RelayKey.stored() {
        case let .key(key): (try? key.thumbprint).map { .key(deviceId: key.deviceId, thumbprint: $0) } ?? .unreadable
        case .absent: .absent
        case .unreadable: .unreadable
        }
    }

    static func status(client: NuoClient) async throws -> Status {
        try await client.request("GET", "/api/auth/relay")
    }

    private static func atHome(_ client: NuoClient) async -> Bool {
        guard let auth = client.auth else { return false }
        return await !auth.router.route().isInternet
    }

    /// A new key, sent to the gateway with a Face ID given for it; the key in use stays until the gateway took the new
    /// one, so a failure (away from home, Face ID cancelled, offline) leaves the access as it was.
    static func register(client: NuoClient, deviceId: String, profileId: String?) async throws {
        guard profileId == "owner" else { throw EnrollmentError.notOwner }
        guard await atHome(client) else { throw EnrollmentError.awayFromHome }
        let key: RelayKey
        do {
            key = try RelayKey.generate(deviceId: deviceId)
        } catch RelayKey.KeyError.noSecureEnclave {
            throw EnrollmentError.noSecureEnclave
        }
        try await client.send("POST", "/api/auth/relay", body: ["publicKey": try key.publicKeySPKI.base64EncodedString()])
        try key.install()
        UserDefaults.standard.removeObject(forKey: declinedKey)
        await RelayClient.shared.reset()
    }

    static func revoke(client: NuoClient) async throws {
        try await client.send("DELETE", "/api/auth/relay")
        RelayKey.delete()
        await RelayClient.shared.reset()
    }
}
