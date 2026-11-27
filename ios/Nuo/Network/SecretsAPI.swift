import Foundation

/// The gateway machine's secrets; separate from `NuoAPI` so the demo backend opts in here. Every call but the
/// list is signed, before it leaves the device, by the Face ID–bound action key over that exact request; the
/// gateway accepts them from home or the VPN only.
protocol NuoSecretsAPI: Sendable {
    func secrets() async throws -> SecretsState
    func revealSecret(source: String, key: String) async throws -> String
    /// `createSource` starts a new `.env` file named `source`.
    func createSecret(source: String, key: String, value: String, createSource: Bool) async throws -> SecretSource
    func updateSecret(source: String, key: String, value: String) async throws -> SecretSource
    func deleteSecret(source: String, key: String) async throws -> SecretSource
}

private struct SecretBody: Encodable {
    let source: String
    let key: String
    var value: String?
    var createSource: Bool?
}

private struct ActionKeyBody: Encodable {
    let publicKey: String
}

extension NuoClient: NuoSecretsAPI {
    func secrets() async throws -> SecretsState { try await request("GET", "/api/secrets") }

    func revealSecret(source: String, key: String) async throws -> String {
        struct Reply: Decodable { let value: String }
        let reply: Reply = try await signed("POST", "/api/secrets/reveal", body: SecretBody(source: source, key: key), reason: String(localized: "Show \(key)"))
        return reply.value
    }

    func createSecret(source: String, key: String, value: String, createSource: Bool) async throws -> SecretSource {
        try await signed("POST", "/api/secrets/entries", body: SecretBody(source: source, key: key, value: value, createSource: createSource ? true : nil), reason: String(localized: "Add \(key)"))
    }

    func updateSecret(source: String, key: String, value: String) async throws -> SecretSource {
        try await signed("PUT", "/api/secrets/entries", body: SecretBody(source: source, key: key, value: value), reason: String(localized: "Edit \(key)"))
    }

    func deleteSecret(source: String, key: String) async throws -> SecretSource {
        try await signed("DELETE", SecretKey.deletePath(source: source, key: key), body: Optional<SecretBody>.none, reason: String(localized: "Delete \(key)"))
    }

    /// Signs then sends; the first time, or after the biometry changed, sets the action key up (step-up) and retries.
    private func signed<Reply: Decodable, Body: Encodable>(_ method: String, _ path: String, body: Body?, reason: String) async throws -> Reply {
        guard let auth else { throw NuoError.unauthorized }
        let data = try body.map { try NuoJSON.encoder().encode($0) } ?? Data()
        for attempt in 0..<2 {
            let key = try await actionKey(fresh: attempt > 0)
            let nonce = try await auth.actionNonce()
            let signature = try key.sign(ActionKey.message(deviceId: auth.deviceId, nonce: nonce, method: method, path: path, body: data), reason: reason)
            var request = try makeRequest(method, path, body: Optional<String>.none)
            if body != nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = data
            }
            request.setValue(nonce, forHTTPHeaderField: "X-Nuo-Action-Nonce")
            request.setValue(signature.base64EncodedString(), forHTTPHeaderField: "X-Nuo-Action-Signature")
            do {
                let (reply, _) = try await perform(request)
                return try NuoJSON.decoder().decode(Reply.self, from: reply)
            } catch let NuoError.server(status, message) where status == 403 && attempt == 0 && message.contains("no Face ID key") {
                continue
            } catch let NuoError.server(status, message) where status == 403 && attempt == 0 && message.contains("invalid action signature") {
                // The gateway holds another key (this device was set up again): register this one.
                continue
            }
        }
        throw NuoError.server(status: 403, message: String(localized: "The gateway rejects this device's Face ID key."))
    }

    private func actionKey(fresh: Bool) async throws -> ActionKey {
        if !fresh, let key = ActionKey.load() { return key }
        let key = try ActionKey.create()
        try await send("POST", "/api/auth/action-key", body: ActionKeyBody(publicKey: try key.publicKeySPKI.base64EncodedString()))
        return key
    }
}
