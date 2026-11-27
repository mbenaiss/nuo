import Foundation
import LocalAuthentication
import os

/// Device-bound authentication with the gateway (docs/protocol.md, "Auth"): short-lived access tokens, refreshed
/// by signing a server nonce with the device key, and step-ups after a fresh Face ID / Touch ID for sensitive actions.
actor AuthSession {
    nonisolated let deviceId: String
    nonisolated let router: GatewayRouter
    private let key: DeviceKey
    private var accessToken: String?
    private var expiresAt = Date.distantPast
    private var stepUpUntil = Date.distantPast
    private var refreshing: Task<String, Error>?
    private var stepping: Task<Void, Error>?

    private static let deviceIdKey = "nuo.deviceId"
    /// Refresh this long before the gateway's 15 minutes run out, so a request never races the expiry.
    private static let refreshMargin: TimeInterval = 60

    /// Posted with the gateway's reason when the device must pair again (revoked, legacy token, unknown key).
    static let reauthNotification = Notification.Name("nuo.auth.reauthRequired")

    private init(deviceId: String, key: DeviceKey, router: GatewayRouter) {
        self.deviceId = deviceId
        self.key = key
        self.router = router
    }

    // MARK: - Lifecycle

    private static let current = Locked<AuthSession?>(nil)

    /// The paired session, if this device has one (also used before the UI exists, e.g. notification actions).
    static func restore(fallbackLAN: URL) -> AuthSession? {
        if case let .paired(session) = restoreState(fallbackLAN: fallbackLAN) { return session }
        return nil
    }

    enum RestoreState { case paired(AuthSession), unpaired, waitForUnlock }

    static func restoreState(fallbackLAN: URL) -> RestoreState {
        if let session = current.value { return .paired(session) }
        let lookup = DeviceKey.lookup()
        var storedId: String?
        if case let .found(key) = lookup { storedId = key.deviceId }
        switch PairingRestore.resolve(storedDeviceId: storedId, savedDeviceId: UserDefaults.standard.string(forKey: deviceIdKey), key: lookup) {
        case let .paired(deviceId, key):
            let session = AuthSession(deviceId: deviceId, key: key.recording(deviceId: deviceId), router: .fromSharedCredentials(fallbackLAN: fallbackLAN))
            current.value = session
            return .paired(session)
        case .unpaired:
            return .unpaired
        case .waitForUnlock:
            log.notice("device key unreadable (locked): waiting for unlock instead of pairing")
            return .waitForUnlock
        }
    }

    /// A long-lived token from a build before device keys is still around: the user must pair again.
    static var hasLegacyPairing: Bool {
        SharedCredentials.legacyToken != nil && UserDefaults.standard.string(forKey: deviceIdKey) == nil
    }

    static func forget() {
        current.value = nil
        UserDefaults.standard.removeObject(forKey: deviceIdKey)
        DeviceKey.delete()
        SharedCredentials.clearAll()
    }

    /// Pairing only works on the home network or VPN: the gateway hides /api/pair from the internet.
    static func pair(lanURL: URL, profile: String, code: String, secondFactor: String, deviceName: String) async throws -> AuthSession {
        let key = DeviceKey.generate()
        let body: [String: Any] = [
            "profile": profile,
            "code": code,
            "totp": secondFactor,
            "deviceName": deviceName,
            "platform": platform,
            "publicKey": try key.publicKeySPKI.base64EncodedString(),
        ]
        let (status, reply) = try await AuthHTTP.send("POST", "/api/pair", route: GatewayRoute(baseURL: lanURL, headers: [:], isInternet: false), body: body)
        guard status == 200, let grant = Grant(reply) else { throw pairingError(status: status, reply: reply) }
        let paired = try key.store(deviceId: grant.deviceId)
        SharedCredentials.legacyToken = nil
        SharedCredentials.gatewayURL = lanURL
        store(network: reply["network"] as? [String: Any])
        SharedCredentials.profile = parseProfile(reply["profile"])
        UserDefaults.standard.set(grant.deviceId, forKey: deviceIdKey)
        let session = AuthSession(deviceId: grant.deviceId, key: paired, router: .fromSharedCredentials(fallbackLAN: lanURL))
        await session.apply(grant)
        current.value = session
        return session
    }

    nonisolated static var platform: String {
        #if os(macOS)
        "macOS"
        #elseif os(visionOS)
        "visionOS"
        #else
        ProcessInfo.processInfo.isiOSAppOnMac ? "macOS" : "iOS"
        #endif
    }

    private static func pairingError(status: Int, reply: [String: Any]) -> NuoError {
        switch status {
        case 401: return .server(status: 401, message: String(localized: "Wrong profile, pairing code or 2FA code."))
        case 429:
            if let retry = (reply["retryAt"] as? String).flatMap(AuthHTTP.date) {
                return .server(status: 429, message: String(localized: "Too many failed attempts. Pairing is blocked until \(retry.formatted(date: .omitted, time: .shortened))."))
            }
            return .server(status: 429, message: String(localized: "Too many failed attempts. Try again in 15 minutes."))
        case 503: return .server(status: 503, message: String(localized: "Two-factor authentication isn't set up: run `bun run src/cli.ts auth-totp-setup` on the gateway host."))
        case 404: return .server(status: 404, message: String(localized: "No Nuo gateway at this address. Pairing only works from the gateway's network."))
        case 400: return .server(status: 400, message: (reply["error"] as? String) ?? String(localized: "Request refused by the gateway."))
        default: return .server(status: status, message: (reply["error"] as? String) ?? "")
        }
    }

    private static func store(network: [String: Any]?) {
        SharedCredentials.publicURL = (network?["publicURL"] as? String).flatMap(URL.init(string:))
        if let cf = network?["cfAccess"] as? [String: String], let id = cf["clientId"], let secret = cf["clientSecret"] {
            SharedCredentials.cfAccess = (id, secret)
        } else {
            SharedCredentials.cfAccess = nil
        }
    }

    private static func parseProfile(_ json: Any?) -> GatewayProfile? {
        guard let json = json as? [String: Any], let id = json["id"] as? String, let name = json["name"] as? String else { return nil }
        return GatewayProfile(id: id, name: name)
    }

    /// Devices paired before gateway profiles existed learn theirs once; errors (older gateway: 404) are ignored.
    func syncProfile() async -> GatewayProfile? {
        if let stored = SharedCredentials.profile { return stored }
        guard let current = try? await token(),
              let fetched = try? await withRoute({ route -> GatewayProfile? in
                  let (status, reply) = try await AuthHTTP.send("GET", "/api/me", route: route, token: current)
                  return status == 200 ? Self.parseProfile(reply["profile"]) : nil
              })
        else { return nil }
        SharedCredentials.profile = fetched
        return fetched
    }

    /// Picks up the internet address and Access token set on the gateway after this device was paired, so
    /// enabling remote access (or rotating its token) needs no new pairing.
    func syncNetwork() async {
        guard let current = try? await token(),
              let fetched = try? await withRoute({ route -> Bool in
                  let (status, reply) = try await AuthHTTP.send("GET", "/api/auth/network", route: route, token: current)
                  guard status == 200 else { return false }
                  Self.store(network: reply)
                  return true
              }),
              fetched
        else { return }
        await router.updateInternet(SharedCredentials.publicURL, headers: SharedCredentials.accessHeaders())
    }

    // MARK: - Tokens

    /// A valid access token, refreshed with the device key when it is about to expire.
    func token() async throws -> String {
        if let accessToken, expiresAt.timeIntervalSinceNow > Self.refreshMargin { return accessToken }
        return try await refresh()
    }

    /// Drops the token after the gateway refused it, so the next `token()` refreshes.
    func invalidate(_ token: String) {
        if token == accessToken { accessToken = nil }
    }

    @discardableResult
    func refresh() async throws -> String {
        if let refreshing { return try await refreshing.value }
        let task = Task { try await performRefresh() }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func performRefresh() async throws -> String {
        try await withRoute { try await self.performRefresh(route: $0) }
    }

    /// Runs `body` on the current route, then once on the other address when the first one is unreachable.
    private func withRoute<T: Sendable>(_ body: (GatewayRoute) async throws -> T) async throws -> T {
        let route = await router.route()
        do {
            return try await body(route)
        } catch NuoError.offline {
            guard let other = await router.alternative(to: route) else { throw NuoError.offline }
            return try await body(other)
        } catch let NuoError.server(status, _) where status == 403 && !route.isInternet {
            await router.homeRefused()
            guard let other = await router.alternative(to: route) else { throw NuoError.server(status: status, message: "") }
            return try await body(other)
        }
    }

    private func performRefresh(route: GatewayRoute) async throws -> String {
        let nonce = try await challenge(route: route)
        let signature = try key.sign(Data(Self.message("refresh", deviceId: deviceId, nonce: nonce).utf8))
        let (status, reply) = try await AuthHTTP.send("POST", "/api/auth/refresh", route: route, body: [
            "deviceId": deviceId, "nonce": nonce, "signature": signature.base64EncodedString(),
        ])
        guard status == 200, let grant = Grant(reply) else { throw failure(status: status, reply: reply) }
        apply(grant)
        return grant.accessToken
    }

    /// Fresh Face ID / Touch ID (or passcode), then a signed step-up: the new access token may call the
    /// sensitive routes for 60 seconds.
    /// `force`: the gateway already used up the current step-up (single-use routes), the deadline means nothing.
    /// `boundTo`: the action this Face ID is for, when the gateway takes only a step-up given for it (`relay`).
    func stepUp(reason: String, force: Bool = false, boundTo: String? = nil) async throws {
        if !force, stepUpUntil.timeIntervalSinceNow > 5 { return }
        if let stepping { return try await stepping.value }
        let task = Task { try await performStepUp(reason: reason, boundTo: boundTo) }
        stepping = task
        defer { stepping = nil }
        try await task.value
    }

    private func performStepUp(reason: String, boundTo: String?) async throws {
        guard await BiometricGate.confirm(reason: reason) else { throw NuoError.stepUpCancelled }
        let current = try await token()
        try await withRoute { try await self.performStepUp(route: $0, token: current, boundTo: boundTo) }
    }

    /// A "pair again" answer erases this device's key, so it is only believed when a fresh signed refresh, on
    /// every address the gateway has, gets it again: a stray 401 (another host answering on the home address
    /// away from home, a gateway mid-restart) must never unpair the device.
    func confirmRevoked() async -> Bool {
        try? await Task.sleep(for: .seconds(2))
        var routes = [await router.lanRoute]
        if let internet = await router.internetRoute { routes.append(internet) }
        var revoked = false
        for route in routes {
            guard let (status, reply) = try? await AuthHTTP.send("GET", "/api/auth/challenge", route: route),
                  status == 200, let nonce = reply["nonce"] as? String,
                  let signature = try? key.sign(Data(Self.message("refresh", deviceId: deviceId, nonce: nonce).utf8)),
                  let (refreshStatus, refreshReply) = try? await AuthHTTP.send("POST", "/api/auth/refresh", route: route, body: [
                      "deviceId": deviceId, "nonce": nonce, "signature": signature.base64EncodedString(),
                  ])
            else { continue }
            if refreshStatus == 200, let grant = Grant(refreshReply) {
                apply(grant)
                Self.log.notice("pair-again answer not confirmed by \(route.baseURL.host() ?? "?", privacy: .public): still paired")
                return false
            }
            if refreshStatus == 401, refreshReply["reauth"] as? Bool == true {
                Self.log.error("pair-again confirmed by \(route.baseURL.host() ?? "?", privacy: .public): \(refreshReply["error"] as? String ?? "", privacy: .public)")
                revoked = true
            }
        }
        return revoked
    }

    static let log = Logger(subsystem: AppIdentity.identifier, category: "auth")

    private func performStepUp(route: GatewayRoute, token current: String, boundTo: String?) async throws {
        let nonce = try await challenge(route: route)
        let signature = try key.sign(Data(Self.message("step-up", deviceId: deviceId, nonce: nonce).utf8))
        var body = ["nonce": nonce, "signature": signature.base64EncodedString()]
        if let boundTo { body["reason"] = boundTo }
        let (status, reply) = try await AuthHTTP.send("POST", "/api/auth/step-up", route: route, token: current, body: body)
        guard status == 200, let grant = Grant(reply) else { throw failure(status: status, reply: reply) }
        apply(grant)
    }

    /// A one-time nonce for a secret call signed by the action key.
    func actionNonce() async throws -> String {
        try await withRoute { try await self.challenge(route: $0) }
    }

    private func challenge(route: GatewayRoute) async throws -> String {
        let (status, reply) = try await AuthHTTP.send("GET", "/api/auth/challenge", route: route)
        guard status == 200, let nonce = reply["nonce"] as? String else { throw failure(status: status, reply: reply) }
        return nonce
    }

    private func failure(status: Int, reply: [String: Any]) -> NuoError {
        if status == 401, reply["reauth"] as? Bool == true {
            let message = (reply["error"] as? String) ?? ""
            Self.log.error("pair-again answer: \(message, privacy: .public)")
            Task { @MainActor in NotificationCenter.default.post(name: Self.reauthNotification, object: nil, userInfo: ["message": message]) }
            return .reauthRequired
        }
        return status == 401 ? .unauthorized : .server(status: status, message: (reply["error"] as? String) ?? "")
    }

    /// Lets the client report a `reauth: true` answer from any route.
    nonisolated func reportReauth(message: String) {
        Task { @MainActor in NotificationCenter.default.post(name: Self.reauthNotification, object: nil, userInfo: ["message": message]) }
    }

    private func apply(_ grant: Grant) {
        accessToken = grant.accessToken
        expiresAt = grant.expiresAt
        // A refreshed token carries no step-up: keeping the old deadline made the next sensitive call skip the
        // confirmation and get a 403 from the gateway.
        stepUpUntil = grant.stepUpUntil ?? .distantPast
        for (scope, token) in grant.extensionTokens {
            SharedCredentials.setExtensionToken(token, for: scope)
        }
    }

    nonisolated static func message(_ purpose: String, deviceId: String, nonce: String) -> String {
        "nuo-auth:v1:\(purpose):\(deviceId):\(nonce)"
    }
}

/// Access token grant of /api/pair, /api/auth/refresh and /api/auth/step-up.
private struct Grant: Sendable {
    let deviceId: String
    let accessToken: String
    let expiresAt: Date
    let stepUpUntil: Date?
    let extensionTokens: [SharedCredentials.Scope: String]

    init?(_ json: [String: Any]) {
        guard let deviceId = json["deviceId"] as? String, let token = json["accessToken"] as? String,
              let expires = (json["expiresAt"] as? String).flatMap(AuthHTTP.date)
        else { return nil }
        self.deviceId = deviceId
        accessToken = token
        expiresAt = expires
        stepUpUntil = (json["stepUpUntil"] as? String).flatMap(AuthHTTP.date)
        var tokens: [SharedCredentials.Scope: String] = [:]
        for (name, value) in (json["extensionTokens"] as? [String: [String: String]]) ?? [:] {
            if let scope = SharedCredentials.Scope(rawValue: name), let token = value["token"] { tokens[scope] = token }
        }
        extensionTokens = tokens
    }
}

/// Plain JSON calls of the auth endpoints, outside `NuoClient` (which itself depends on the session).
enum AuthHTTP {
    static func send(_ method: String, _ path: String, route: GatewayRoute, token: String? = nil, body: [String: Any]? = nil) async throws -> (Int, [String: Any]) {
        guard let url = URL(string: path, relativeTo: route.baseURL)?.absoluteURL else { throw NuoError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in route.headers { request.setValue(value, forHTTPHeaderField: name) }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw NuoError.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
    }

    static func date(_ text: String) -> Date? {
        (try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true))) ?? (try? Date(text, strategy: .iso8601))
    }
}

/// Face ID / Touch ID, falling back to the device passcode.
enum BiometricGate {
    /// What this device unlocks with, for labels ("Face ID" on iPhone, "Touch ID" on most Macs).
    static var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return String(localized: "the device passcode")
        }
    }

    static func confirm(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

/// A value shared across threads behind a lock.
final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
