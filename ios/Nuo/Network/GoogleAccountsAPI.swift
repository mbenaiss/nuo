import Foundation

enum GoogleService: String, Codable, CaseIterable, Identifiable, Sendable {
    case gmail, drive, calendar

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gmail: "Gmail"
        case .drive: "Drive"
        case .calendar: String(localized: "google.calendar", defaultValue: "Calendar")
        }
    }

    var symbol: String {
        switch self {
        case .gmail: "envelope"
        case .drive: "folder"
        case .calendar: "calendar"
        }
    }
}

/// One of the profile's Google accounts, from `GET /api/google/accounts`.
struct GoogleAccount: Codable, Identifiable, Hashable, Sendable {
    var email: String
    /// Raw names so a service added later on the gateway does not break decoding.
    var services: [String]
    var status: String
    var lastError: String?
    var connectedAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?

    var id: String { email }
    var grantedServices: [GoogleService] { GoogleService.allCases.filter { services.contains($0.rawValue) } }
    var needsReconnect: Bool { status == "error" }
}

struct GoogleAccountsState: Codable, Sendable {
    /// False until the gateway has a Google OAuth client.
    var configured: Bool
    var accounts: [GoogleAccount]
}

struct GoogleConnectStart: Codable, Sendable {
    var url: URL
    var expiresAt: Date?
}

/// What the gateway's callback sends back in `nuo://google/connected?…`.
struct GoogleConnectResult: Equatable, Sendable {
    var email: String?
    var services: [GoogleService] = []
    var missing: [GoogleService] = []
    var error: String?

    init(url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        func services(_ name: String) -> [GoogleService] { (value(name) ?? "").split(separator: ",").compactMap { GoogleService(rawValue: String($0)) } }
        email = value("email")
        self.services = services("services")
        missing = services("missing")
        error = value("error") ?? (email == nil ? "failed" : nil)
    }

    var message: String {
        switch error {
        case "denied": return String(localized: "Sign-in canceled on Google: no account added.")
        case "expired": return String(localized: "The sign-in link expired. Start again.")
        case .some: return String(localized: "Google refused the sign-in. Try again in a moment.")
        case .none:
            let account = email ?? String(localized: "Account")
            let granted = services.map(\.label).formatted(.list(type: .and))
            var text = granted.isEmpty ? String(localized: "\(account) connected.") : String(localized: "\(account) connected (\(granted)).")
            if !missing.isEmpty {
                let refused = missing.map(\.label).formatted(.list(type: .and))
                text += " " + String(localized: "\(refused) not authorized: reconnect the account and check it on the Google screen.")
            }
            return text
        }
    }
}

/// Google accounts of the profile; separate from `NuoAPI` so the demo backend opts in here.
protocol NuoGoogleAPI: Sendable {
    func googleAccounts() async throws -> GoogleAccountsState
    /// The Google consent URL to open in a web authentication session; `email` preselects the account to reconnect.
    func connectGoogle(services: [GoogleService], email: String?) async throws -> GoogleConnectStart
    /// Revokes the account's access at Google and forgets it.
    func disconnectGoogle(email: String) async throws
}

extension NuoClient: NuoGoogleAPI {
    func googleAccounts() async throws -> GoogleAccountsState { try await request("GET", "/api/google/accounts") }

    func connectGoogle(services: [GoogleService], email: String?) async throws -> GoogleConnectStart {
        struct Body: Encodable { let services: [String]; let email: String? }
        return try await request("POST", "/api/google/connect", body: Body(services: services.map(\.rawValue), email: email))
    }

    func disconnectGoogle(email: String) async throws {
        let segment = email.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? email
        try await send("DELETE", "/api/google/accounts/\(segment)")
    }
}
