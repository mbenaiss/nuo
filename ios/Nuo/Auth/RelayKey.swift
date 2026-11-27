import CryptoKit
import Foundation
import Security

/// The relay key: a P-256 key usable from the first unlock after a restart (`AfterFirstUnlockThisDeviceOnly`),
/// apart from the device key (`WhenUnlocked`) and the Face ID key. It signs for nothing but relay tokens, which pass
/// the watch's spoken requests on while the iPhone is locked (docs/security.md, « Relay access »). Always in the
/// Secure Enclave on a device (a software key only in the simulator); the Keychain item keeps the enclave's wrapped
/// blob and the device id, readable when locked too.
struct RelayKey: Sendable {
    let deviceId: String
    private let material: Data
    private let enclave: Bool

    private static let service = AppIdentity.scoped("relay-key")
    private static let account = "p256"

    /// What the Keychain holds: a key, nothing, or something it cannot read now (then nothing is decided from it).
    enum Stored: Sendable {
        case key(RelayKey)
        case absent
        case unreadable
    }

    enum KeyError: Error, Equatable {
        /// No Secure Enclave on this device: the relay access is not offered there.
        case noSecureEnclave
        case keychain(OSStatus)
    }

    var publicKeySPKI: Data {
        get throws {
            enclave
                ? try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: material).publicKey.derRepresentation
                : try P256.Signing.PrivateKey(rawRepresentation: material).publicKey.derRepresentation
        }
    }

    /// The gateway's thumbprint of this key (`GET /api/auth/relay`): SHA-256 of the SPKI DER, base64url.
    var thumbprint: String {
        get throws { Self.thumbprint(spki: try publicKeySPKI) }
    }

    static func thumbprint(spki: Data) -> String {
        Data(SHA256.hash(data: spki)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    func sign(_ message: Data) throws -> Data {
        enclave
            ? try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: material).signature(for: message).derRepresentation
            : try P256.Signing.PrivateKey(rawRepresentation: material).signature(for: message).derRepresentation
    }

    /// What the gateway checks (`signedMessage("relay", …)` in gateway/src/auth/service.ts).
    static func message(deviceId: String, nonce: String) -> Data {
        Data("nuo-auth:v1:relay:\(deviceId):\(nonce)".utf8)
    }

    /// A new key, not stored yet: the current one stays until the gateway has taken this one (`install`).
    static func generate(deviceId: String) throws -> RelayKey {
        if SecureEnclave.isAvailable,
           let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, nil) {
            let enclaveKey = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
            return RelayKey(deviceId: deviceId, material: enclaveKey.dataRepresentation, enclave: true)
        }
        #if targetEnvironment(simulator)
        return RelayKey(deviceId: deviceId, material: P256.Signing.PrivateKey().rawRepresentation, enclave: false)
        #else
        // A software key would be readable by anyone reading the Keychain of the unlocked device.
        throw KeyError.noSecureEnclave
        #endif
    }

    /// Replaces the stored key with this one, once the gateway registered it.
    func install() throws {
        Self.delete()
        try save()
    }

    static func stored() -> Stored {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return .absent }
        guard status == errSecSuccess, let attributes = item as? [String: Any],
              let data = attributes[kSecValueData as String] as? Data,
              let generic = attributes[kSecAttrGeneric as String] as? Data, let tag = String(data: generic, encoding: .utf8)
        else { return .unreadable }
        let parts = tag.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return .unreadable }
        return .key(RelayKey(deviceId: parts[1], material: data, enclave: parts[0] == "se"))
    }

    static func load() -> RelayKey? {
        if case let .key(key) = stored() { return key }
        return nil
    }

    static func delete() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func save() throws {
        var attributes = Self.baseQuery()
        attributes[kSecValueData as String] = material
        attributes[kSecAttrGeneric as String] = Data("\(enclave ? "se" : "sw")|\(deviceId)".utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyError.keychain(status) }
    }

    private static func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // The app's own group: no extension, and so not the watch, ever reads it.
        if let group = SharedCredentials.privateAccessGroup { query[kSecAttrAccessGroup as String] = group }
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }
}
