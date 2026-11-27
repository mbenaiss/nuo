import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// A second Secure Enclave key, only for the secrets: it signs one exact call at a time and cannot sign without a
/// fresh Face ID / Touch ID, so the gateway gets proof of the owner's face, not just of a token. The device key
/// still signs refreshes and step-ups without asking.
struct ActionKey: Sendable {
    private let material: Data

    private static let service = AppIdentity.scoped("action-key")
    private static let account = "p256"

    /// Without a Secure Enclave (simulator, Macs without one) there is no key a face can guard: secrets stay closed.
    static var isSupported: Bool { SecureEnclave.isAvailable }

    var publicKeySPKI: Data {
        get throws { try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: material).publicKey.derRepresentation }
    }

    /// Asks for Face ID / Touch ID with `reason`, then signs. Cancelling throws `NuoError.stepUpCancelled`.
    func sign(_ message: String, reason: String) throws -> Data {
        let context = LAContext()
        context.localizedReason = reason
        do {
            let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: material, authenticationContext: context)
            return try key.signature(for: Data(message.utf8)).derRepresentation
        } catch let error as LAError where [.userCancel, .appCancel, .systemCancel, .userFallback, .authenticationFailed].contains(error.code) {
            throw NuoError.stepUpCancelled
        } catch {
            if (error as NSError).domain == LAErrorDomain { throw NuoError.stepUpCancelled }
            throw error
        }
    }

    /// Bound to the biometry enrolled today: adding a face or a finger later makes the key unusable, and a new one
    /// is set up (from home, behind a step-up). Macs without Touch ID fall back to the session password.
    static func create() throws -> ActionKey {
        delete()
        guard isSupported else { throw NuoError.transport(String(localized: "This device has no Secure Enclave: secrets stay locked.")) }
        let biometric = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet], nil)
        let presence = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, [.privateKeyUsage, .userPresence], nil)
        let enclave = (biometric.flatMap { try? SecureEnclave.P256.Signing.PrivateKey(accessControl: $0) })
            ?? (presence.flatMap { try? SecureEnclave.P256.Signing.PrivateKey(accessControl: $0) })
        guard let enclave else { throw NuoError.transport(String(localized: "Couldn't create the Face ID key (is a passcode set?).")) }
        let key = ActionKey(material: enclave.dataRepresentation)
        try key.save()
        return key
    }

    static func load() -> ActionKey? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return ActionKey(material: data)
    }

    static func delete() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func save() throws {
        var attributes = Self.baseQuery()
        attributes[kSecValueData as String] = material
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw NuoError.transport(String(localized: "Couldn't save the Face ID key (\(status)).")) }
    }

    private static func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let group = SharedCredentials.privateAccessGroup { query[kSecAttrAccessGroup as String] = group }
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    /// What the gateway checks (`actionMessage` in gateway/src/auth/service.ts).
    static func message(deviceId: String, nonce: String, method: String, path: String, body: Data) -> String {
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        return "nuo-action:v1:\(deviceId):\(nonce):\(method.uppercased()):\(path):\(digest)"
    }
}
