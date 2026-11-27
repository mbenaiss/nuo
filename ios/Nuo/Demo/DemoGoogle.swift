import Foundation

/// In-memory Google accounts for `-demo`; « connecting » adds an account without opening Google. Addresses are invented.
actor DemoGoogle {
    static let shared = DemoGoogle()

    private var accounts: [GoogleAccount]

    private init() {
        let now = Date()
        accounts = [
            GoogleAccount(email: "alex@example.com", services: ["gmail", "drive", "calendar"], status: "ok", connectedAt: now.addingTimeInterval(-86400 * 12), updatedAt: now.addingTimeInterval(-86400 * 12), lastUsedAt: now.addingTimeInterval(-1800)),
            GoogleAccount(email: "club.course@example.com", services: ["gmail"], status: "error", lastError: String(localized: "Access revoked or expired: reconnect this account."), connectedAt: now.addingTimeInterval(-86400 * 40), updatedAt: now.addingTimeInterval(-86400 * 2)),
        ]
    }

    func state() async -> GoogleAccountsState {
        try? await Task.sleep(for: .milliseconds(120))
        return GoogleAccountsState(configured: true, accounts: accounts)
    }

    func connect(services: [GoogleService], email: String?) -> GoogleConnectStart {
        let address = email ?? "nouveau.compte@example.com"
        let now = Date()
        if let index = accounts.firstIndex(where: { $0.email == address }) {
            let merged = Set(accounts[index].services).union(services.map(\.rawValue))
            accounts[index].services = GoogleService.allCases.map(\.rawValue).filter { merged.contains($0) }
            accounts[index].status = "ok"
            accounts[index].lastError = nil
            accounts[index].updatedAt = now
        } else {
            accounts.append(GoogleAccount(email: address, services: services.map(\.rawValue), status: "ok", connectedAt: now, updatedAt: now))
        }
        var components = URLComponents(string: "nuo://google/connected")!
        components.queryItems = [.init(name: "email", value: address), .init(name: "services", value: services.map(\.rawValue).joined(separator: ","))]
        return GoogleConnectStart(url: components.url!, expiresAt: nil)
    }

    func disconnect(email: String) throws {
        guard accounts.contains(where: { $0.email == email }) else { throw NuoError.notFound }
        accounts.removeAll { $0.email == email }
    }
}

extension DemoBackend: NuoGoogleAPI {
    func googleAccounts() async throws -> GoogleAccountsState { await DemoGoogle.shared.state() }
    func connectGoogle(services: [GoogleService], email: String?) async throws -> GoogleConnectStart { await DemoGoogle.shared.connect(services: services, email: email) }
    func disconnectGoogle(email: String) async throws { try await DemoGoogle.shared.disconnect(email: email) }
}
