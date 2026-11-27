import CryptoKit
import Foundation
import Security

/// The P-256 key that proves this device to the gateway (refresh and step-up signatures).
/// Lives in the Secure Enclave when there is one; the Keychain only keeps the enclave's wrapped blob.
/// Without an enclave (simulator, old Macs) the raw key is kept in the Keychain, this device only, while unlocked.
struct DeviceKey: Sendable {
    enum Storage: String, Sendable { case secureEnclave, software }

    let storage: Storage
    private let material: Data
    /// The gateway's id for this device, kept in the same Keychain item: UserDefaults can read empty (launch before
    /// the first unlock, reinstall) while the key is still there, and that must not look like no pairing.
    let deviceId: String?

    private static let service = AppIdentity.scoped("device-key")
    private static let account = "p256"

    /// SubjectPublicKeyInfo DER, what the gateway stores and checks signatures against.
    var publicKeySPKI: Data {
        get throws {
            switch storage {
            case .secureEnclave: try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: material).publicKey.derRepresentation
            case .software: try P256.Signing.PrivateKey(rawRepresentation: material).publicKey.derRepresentation
            }
        }
    }

    /// ECDSA P-256 / SHA-256, DER-encoded.
    func sign(_ message: Data) throws -> Data {
        switch storage {
        case .secureEnclave: try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: material).signature(for: message).derRepresentation
        case .software: try P256.Signing.PrivateKey(rawRepresentation: material).signature(for: message).derRepresentation
        }
    }

    /// A new key, not stored yet: the current pairing keeps its key until the gateway accepted the new one.
    static func generate() -> DeviceKey {
        if SecureEnclave.isAvailable, let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .privateKeyUsage, nil),
           let enclave = try? SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        {
            return DeviceKey(storage: .secureEnclave, material: enclave.dataRepresentation, deviceId: nil)
        }
        return DeviceKey(storage: .software, material: P256.Signing.PrivateKey().rawRepresentation, deviceId: nil)
    }

    /// Replaces the stored key with this one, for the device the gateway just paired.
    func store(deviceId: String) throws -> DeviceKey {
        let paired = DeviceKey(storage: storage, material: material, deviceId: deviceId)
        Self.delete()
        try paired.save()
        return paired
    }

    /// Keys stored before the device id moved into the Keychain learn it once.
    func recording(deviceId: String) -> DeviceKey {
        guard self.deviceId != deviceId else { return self }
        let update = [kSecAttrGeneric as String: Data(deviceId.utf8)] as CFDictionary
        if SecItemUpdate(Self.baseQuery(privateGroup: true) as CFDictionary, update) != errSecSuccess {
            SecItemUpdate(Self.baseQuery(privateGroup: false) as CFDictionary, update)
        }
        return DeviceKey(storage: storage, material: material, deviceId: deviceId)
    }

    static func load() -> DeviceKey? {
        if case let .found(key) = lookup() { return key }
        return nil
    }

    static func lookup() -> DeviceKeyLookup<DeviceKey> {
        let inPrivateGroup = load(privateGroup: true)
        if let key = inPrivateGroup.key { return .found(key) }
        let inDefaultGroup = load(privateGroup: false)
        return .from(statuses: [inPrivateGroup.status, inDefaultGroup.status], found: inDefaultGroup.key)
    }

    private static func load(privateGroup: Bool) -> (key: DeviceKey?, status: OSStatus) {
        var query = baseQuery(privateGroup: privateGroup)
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let attributes = item as? [String: Any],
              let data = attributes[kSecValueData as String] as? Data,
              let label = attributes[kSecAttrLabel as String] as? String,
              let storage = Storage(rawValue: label)
        else { return (nil, status) }
        let deviceId = (attributes[kSecAttrGeneric as String] as? Data).flatMap { String(data: $0, encoding: .utf8) }
        return (DeviceKey(storage: storage, material: data, deviceId: deviceId), status)
    }

    static func delete() {
        SecItemDelete(baseQuery(privateGroup: true) as CFDictionary)
        SecItemDelete(baseQuery(privateGroup: false) as CFDictionary)
    }

    private func save() throws {
        var status = errSecMissingEntitlement
        // Unsigned simulator builds may not own the private group; the default group is then the only option.
        for privateGroup in [true, false] where status == errSecMissingEntitlement {
            var attributes = Self.baseQuery(privateGroup: privateGroup)
            attributes[kSecValueData as String] = material
            attributes[kSecAttrLabel as String] = storage.rawValue
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            attributes[kSecAttrSynchronizable as String] = false
            if let deviceId { attributes[kSecAttrGeneric as String] = Data(deviceId.utf8) }
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NuoError.transport(String(localized: "Couldn't save the device key (\(status)).")) }
    }

    // The app's own access group, not the shared one: extensions never sign, they use scoped tokens.
    private static func baseQuery(privateGroup: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if privateGroup, let group = SharedCredentials.privateAccessGroup { query[kSecAttrAccessGroup as String] = group }
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }
}
