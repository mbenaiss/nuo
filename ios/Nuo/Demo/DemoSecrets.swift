import Foundation

/// In-memory secrets folder for `-demo`; every value is invented.
actor DemoSecrets {
    static let shared = DemoSecrets()

    private struct File {
        var source: SecretSource
        var values: [String: String]
    }

    private var files: [File]

    private init() {
        let now = Date()
        func file(_ id: String, link: String?, usedBy: String?, age: Double, _ pairs: [(String, String, Bool)]) -> File {
            File(
                source: SecretSource(id: id, path: "~/.secrets/\(id)", modifiedAt: now.addingTimeInterval(-age), mode: "600", insecure: false, link: link, usedBy: usedBy, entries: pairs.map { .init(key: $0.0, exported: $0.2) }),
                values: Dictionary(uniqueKeysWithValues: pairs.map { ($0.0, $0.1) })
            )
        }
        files = [
            file("global.env", link: "~/.env", usedBy: "scripts, Cloudflare, PostHog", age: 86400 * 3, [
                ("CF_TOKEN", "cf_demo_5d1c7a0e9b2f", true),
                ("OPENROUTER", "or_demo_9a8b7c6d5e", false),
                ("POSTHOG_PERSONAL_API_KEY", "phx_demo_8Qm2Lr4Tz", false),
            ]),
            file("bank.env", link: nil, usedBy: String(localized: "Finance MCP"), age: 86400 * 6, [
                ("BANK_LOGIN", "demo-studio-4821", false),
                ("BANK_SECRET_KEY", "bank_demo_k3y9Zt", false),
            ]),
            file("nuo.env", link: "~/nuo/config/env", usedBy: "nuo-gateway (EnvironmentFile)", age: 86400 * 6, [
                ("NUO_PORT", "8790", false),
                ("NUO_CF_ACCESS_CLIENT_ID", "demo.access", false),
                ("NUO_CF_ACCESS_CLIENT_SECRET", "cfaccess_demo_secret", false),
            ]),
            file("projects/fitness.env", link: "fitness/.env", usedBy: String(localized: "Fitness MCP (Coach)"), age: 86400 * 7, [
                ("WHOOP_CLIENT_ID", "whoop_demo_client", false),
                ("WHOOP_CLIENT_SECRET", "whoop_demo_secret", false),
            ]),
        ]
    }

    func state() async -> SecretsState {
        try? await Task.sleep(for: .milliseconds(120))
        return SecretsState(configured: true, root: "~/.secrets", sources: files.map(\.source))
    }

    func reveal(source: String, key: String) throws -> String {
        guard let value = files.first(where: { $0.source.id == source })?.values[key] else { throw NuoError.notFound }
        return value
    }

    func create(source: String, key: String, value: String, createSource: Bool) throws -> SecretSource {
        if !files.contains(where: { $0.source.id == source }) {
            guard createSource else { throw NuoError.notFound }
            files.append(File(source: SecretSource(id: source, path: "~/.secrets/\(source)", modifiedAt: Date(), mode: "600", insecure: false, entries: []), values: [:]))
        }
        let index = files.firstIndex { $0.source.id == source }!
        guard files[index].values[key] == nil else { throw NuoError.server(status: 409, message: "") }
        files[index].values[key] = value
        files[index].source.entries.append(.init(key: key, exported: false))
        files[index].source.modifiedAt = Date()
        return files[index].source
    }

    func update(source: String, key: String, value: String) throws -> SecretSource {
        guard let index = files.firstIndex(where: { $0.source.id == source }), files[index].values[key] != nil else { throw NuoError.notFound }
        files[index].values[key] = value
        files[index].source.modifiedAt = Date()
        return files[index].source
    }

    func delete(source: String, key: String) throws -> SecretSource {
        guard let index = files.firstIndex(where: { $0.source.id == source }), files[index].values[key] != nil else { throw NuoError.notFound }
        files[index].values[key] = nil
        files[index].source.entries.removeAll { $0.key == key }
        files[index].source.modifiedAt = Date()
        return files[index].source
    }
}

extension DemoBackend: NuoSecretsAPI {
    func secrets() async throws -> SecretsState { await DemoSecrets.shared.state() }
    func revealSecret(source: String, key: String) async throws -> String { try await DemoSecrets.shared.reveal(source: source, key: key) }
    func createSecret(source: String, key: String, value: String, createSource: Bool) async throws -> SecretSource {
        try await DemoSecrets.shared.create(source: source, key: key, value: value, createSource: createSource)
    }
    func updateSecret(source: String, key: String, value: String) async throws -> SecretSource { try await DemoSecrets.shared.update(source: source, key: key, value: value) }
    func deleteSecret(source: String, key: String) async throws -> SecretSource { try await DemoSecrets.shared.delete(source: source, key: key) }
}
