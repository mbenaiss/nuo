import Foundation
import Security

/// Gateway addresses, Cloudflare Access service token and the scoped extension tokens, stored in the keychain
/// group shared by the app and its extensions (docs/protocol.md, "Extension tokens").
enum SharedCredentials {
    private static let service = AppIdentity.identifier
    private static let tokenAccount = "gateway-token"
    private static let gatewayAccount = "gateway-url"
    private static let publicAccount = "gateway-public-url"
    private static let cfIdAccount = "cf-access-client-id"
    private static let cfSecretAccount = "cf-access-client-secret"
    private static let profileIdAccount = "profile-id"
    private static let profileNameAccount = "profile-name"
    private static let groupSuffix = AppIdentity.scoped("shared")

    /// Scopes of the extension tokens the gateway issues to a device.
    enum Scope: String, Sendable, CaseIterable { case share, widgets, watch }

    /// Long-lived token of builds before device keys; only read to detect that the app must pair again.
    static var legacyToken: String? {
        get { read(account: tokenAccount) }
        set { write(newValue, account: tokenAccount) }
    }

    static func extensionToken(_ scope: Scope) -> String? { read(account: "ext-\(scope.rawValue)") }
    static func setExtensionToken(_ token: String?, for scope: Scope) { write(token, account: "ext-\(scope.rawValue)") }

    /// Home network / VPN address (Caddy).
    static var gatewayURL: URL? {
        get { read(account: gatewayAccount).flatMap(URL.init(string:)) }
        set { write(newValue?.absoluteString, account: gatewayAccount) }
    }

    /// Internet address (Cloudflare Tunnel behind Cloudflare Access), when the gateway has one.
    static var publicURL: URL? {
        get { read(account: publicAccount).flatMap(URL.init(string:)) }
        set { write(newValue?.absoluteString, account: publicAccount) }
    }

    static var cfAccess: (clientId: String, clientSecret: String)? {
        get {
            guard let id = read(account: cfIdAccount), let secret = read(account: cfSecretAccount) else { return nil }
            return (id, secret)
        }
        set {
            write(newValue?.clientId, account: cfIdAccount)
            write(newValue?.clientSecret, account: cfSecretAccount)
        }
    }

    static var profile: GatewayProfile? {
        get {
            guard let id = read(account: profileIdAccount), let name = read(account: profileNameAccount) else { return nil }
            return GatewayProfile(id: id, name: name)
        }
        set {
            write(newValue?.id, account: profileIdAccount)
            write(newValue?.name, account: profileNameAccount)
        }
    }

    /// Headers Cloudflare Access needs on every request to the internet address.
    static func accessHeaders() -> [String: String] {
        guard let cf = cfAccess else { return [:] }
        return ["CF-Access-Client-Id": cf.clientId, "CF-Access-Client-Secret": cf.clientSecret]
    }

    /// Where an extension may reach the gateway, home address first.
    static func routes() -> [GatewayRoute] {
        var routes: [GatewayRoute] = []
        if let lan = gatewayURL { routes.append(GatewayRoute(baseURL: lan, headers: [:], isInternet: false)) }
        if let internet = publicURL, internet != gatewayURL { routes.append(GatewayRoute(baseURL: internet, headers: accessHeaders(), isInternet: true)) }
        return routes
    }

    static func clearAll() {
        for account in [tokenAccount, publicAccount, cfIdAccount, cfSecretAccount, profileIdAccount, profileNameAccount] { write(nil, account: account) }
        for scope in Scope.allCases { setExtensionToken(nil, for: scope) }
    }

    /// `<TeamID>.<bundle id>`: the app's own group, which extensions cannot read.
    static let privateAccessGroup: String? = {
        guard let prefix = appIdentifierPrefix(), let bundle = Bundle.main.bundleIdentifier else { return nil }
        return "\(prefix).\(bundle)"
    }()

    /// `<TeamID>.<identifier>.shared`, or nil when the binary is not signed with the group
    /// (unsigned simulator builds), in which case items stay in the default group.
    static let accessGroup: String? = {
        guard let prefix = appIdentifierPrefix() else { return nil }
        return "\(prefix).\(groupSuffix)"
    }()

    // The team prefix is not exposed by Bundle; the access group the keychain assigns to a probe item carries it.
    private static func appIdentifierPrefix() -> String? {
        var probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(service).probe",
            kSecAttrAccount as String: "app-identifier-prefix",
        ]
        #if os(macOS)
        probe[kSecUseDataProtectionKeychain as String] = true
        #endif
        var lookup = probe
        lookup[kSecReturnAttributes as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        var status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound {
            var add = probe
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            add[kSecReturnAttributes as String] = true
            status = SecItemAdd(add as CFDictionary, &result)
        }
        guard status == errSecSuccess,
              let attributes = result as? [String: Any],
              let group = attributes[kSecAttrAccessGroup as String] as? String,
              let prefix = group.split(separator: ".").first,
              prefix.count == 10, prefix.allSatisfy({ $0.isLetter || $0.isNumber })
        else { return nil }
        return String(prefix)
    }

    private static func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    private static func write(_ value: String?, account: String) {
        // No access group on delete: also removes a copy left in the app's private group by older builds.
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if let accessGroup {
            attributes[kSecAttrAccessGroup as String] = accessGroup
            if SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess { return }
            attributes.removeValue(forKey: kSecAttrAccessGroup as String)
        }
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private static func read(account: String) -> String? {
        if let accessGroup, let value = copy(account: account, group: accessGroup) { return value }
        guard let value = copy(account: account, group: nil) else { return nil }
        // Found outside the shared group: an item saved before widgets existed. Move it so extensions can read it.
        if accessGroup != nil { write(value, account: account) }
        return value
    }

    private static func copy(account: String, group: String?) -> String? {
        var query = baseQuery(account: account)
        if let group { query[kSecAttrAccessGroup as String] = group }
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

/// One way to reach the gateway: its base URL and the headers that address needs, the user's languages included.
struct GatewayRoute: Sendable, Equatable {
    let baseURL: URL
    let headers: [String: String]
    let isInternet: Bool

    init(baseURL: URL, headers: [String: String], isInternet: Bool) {
        self.baseURL = baseURL
        var headers = headers
        if headers[GatewayLanguage.header] == nil, let languages = GatewayLanguage.acceptLanguage() {
            headers[GatewayLanguage.header] = languages
        }
        self.headers = headers
        self.isInternet = isInternet
    }
}
