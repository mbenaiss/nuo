import Foundation
import Security

struct WatchCredentials: Equatable, Sendable {
    var gatewayURL: URL
    var token: String
}

enum WatchKeychain {
    private static let service = AppIdentity.scoped("watch")
    private static let tokenAccount = "gateway-token"
    private static let gatewayAccount = "gateway-url"

    static var credentials: WatchCredentials? {
        guard let token = load(tokenAccount), let raw = load(gatewayAccount), let url = URL(string: raw) else { return nil }
        return WatchCredentials(gatewayURL: url, token: token)
    }

    /// Shared with the complications extension, which reads the agenda and reminders itself.
    private static var accessGroup: String? {
        guard let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String, !prefix.isEmpty else { return nil }
        return prefix + AppIdentity.scoped("watch")
    }

    /// Moves items saved before the complications read them into the shared group.
    static func migrate() {
        guard let credentials, accessGroup != nil else { return }
        save(credentials)
    }

    static func save(_ credentials: WatchCredentials?) {
        store(credentials?.token, account: tokenAccount)
        store(credentials?.gatewayURL.absoluteString, account: gatewayAccount)
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func store(_ value: String?, account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var attributes = baseQuery(account)
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if let accessGroup {
            attributes[kSecAttrAccessGroup as String] = accessGroup
            if SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess { return }
            attributes.removeValue(forKey: kSecAttrAccessGroup as String)
        }
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private static func load(_ account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }
}
