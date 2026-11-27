import Foundation

/// A paired device, from `GET /api/devices`.
struct PairedDevice: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var platform: String?
    var createdAt: Date
    var lastSeenAt: Date?
    var current: Bool
    /// Paired before device keys: it must pair again and can only be revoked.
    var legacy: Bool
}

/// `GET /api/auth/activity`: the « Activité de sécurité » screen.
struct SecurityActivity: Codable, Sendable {
    struct Event: Codable, Hashable, Sendable {
        var at: Date
        var type: String
        var ok: Bool
        var ip: String?
        var deviceId: String?
        var deviceName: String?
        var detail: String?
    }

    struct InternetClient: Codable, Hashable, Sendable {
        var ip: String
        var deviceId: String?
        var deviceName: String?
        var requests: Int
        var errors: Int
        var lastAt: Date
    }

    var events: [Event]
    var internet: [InternetClient]
    var recoveryCodesLeft: Int
    var totp: Bool
}

/// Device management and the security log; separate from `NuoAPI` so the demo backend opts in here.
protocol NuoSecurityAPI: Sendable {
    func devices() async throws -> [PairedDevice]
    /// Needs a fresh step-up: the client asks for Face ID when the gateway answers 403 `stepUp`.
    func revokeDevice(id: String) async throws
    func securityActivity() async throws -> SecurityActivity
}

extension NuoClient: NuoSecurityAPI {
    func devices() async throws -> [PairedDevice] { try await request("GET", "/api/devices") }
    func revokeDevice(id: String) async throws { try await send("DELETE", "/api/devices/\(id)") }
    func securityActivity() async throws -> SecurityActivity { try await request("GET", "/api/auth/activity") }
}

extension DemoBackend: NuoSecurityAPI {
    func devices() async throws -> [PairedDevice] {
        let now = Date()
        return [
            PairedDevice(id: "d-iphone", name: String(localized: "Alex's iPhone"), platform: "iOS", createdAt: now.addingTimeInterval(-86400 * 30), lastSeenAt: now, current: true, legacy: false),
            PairedDevice(id: "d-mac", name: "MacBook Pro", platform: "macOS", createdAt: now.addingTimeInterval(-86400 * 3), lastSeenAt: now.addingTimeInterval(-3600), current: false, legacy: false),
        ]
    }

    func revokeDevice(id: String) async throws {}

    func securityActivity() async throws -> SecurityActivity {
        let now = Date()
        return SecurityActivity(
            events: [
                .init(at: now.addingTimeInterval(-600), type: "refresh", ok: true, ip: "192.0.2.12", deviceName: String(localized: "Alex's iPhone")),
                .init(at: now.addingTimeInterval(-86400 * 3), type: "pair", ok: true, ip: "192.0.2.20", deviceName: "MacBook Pro", detail: "macOS"),
                .init(at: now.addingTimeInterval(-86400 * 3 - 120), type: "pair", ok: false, ip: "192.0.2.20", deviceName: "MacBook Pro", detail: "second factor"),
            ],
            internet: [.init(ip: "203.0.113.9", deviceName: String(localized: "Alex's iPhone"), requests: 42, errors: 0, lastAt: now.addingTimeInterval(-7200))],
            recoveryCodesLeft: 10,
            totp: true
        )
    }
}

/// Reasons the gateway gives for a step-up, as the Face ID prompt shows them.
enum StepUpReason {
    static func prompt(for reason: String?) -> String {
        switch reason {
        case "devices": String(localized: "Confirm to revoke a device.")
        case "finance": String(localized: "Confirm to change financial data.")
        case "commands": String(localized: "Confirm to change a command task.")
        case "docs": String(localized: "Confirm to delete a document.")
        case "secrets": String(localized: "Confirm to turn on Face ID for this device's secrets.")
        case "bots": String(localized: "Confirm to give this bot full access.")
        case "relay": String(localized: "Confirm so the Apple Watch can relay your requests through the locked iPhone.")
        default: String(localized: "Confirm this sensitive action.")
        }
    }

    /// The gateway takes the step-up back after one call: a second call needs a new Face ID even within 60 s.
    static func isSingleUse(_ reason: String?) -> Bool {
        reason == "secrets" || reason == "bots" || reason == "relay"
    }

    /// The gateway takes only a Face ID given for this very action: the step-up names it.
    static func isBound(_ reason: String?) -> Bool {
        reason == "relay"
    }
}

extension URLRequest {
    /// The same request on another address of the gateway, with the headers that address needs.
    func routed(to route: GatewayRoute) -> URLRequest {
        var copy = self
        if let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: true),
           let base = URLComponents(url: route.baseURL, resolvingAgainstBaseURL: true)
        {
            components.scheme = base.scheme
            components.host = base.host
            components.port = base.port
            copy.url = components.url ?? url
        }
        for (name, value) in route.headers { copy.setValue(value, forHTTPHeaderField: name) }
        return copy
    }
}
