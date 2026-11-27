import Foundation

/// One env file of the gateway's secrets folder, from `GET /api/secrets`: names only, never values.
struct SecretSource: Codable, Identifiable, Hashable, Sendable {
    struct Entry: Codable, Hashable, Sendable {
        var key: String
        var exported: Bool
    }

    var id: String
    var path: String
    var modifiedAt: Date
    var mode: String
    var insecure: Bool
    var link: String?
    var usedBy: String?
    var entries: [Entry]
}

struct SecretsState: Codable, Sendable {
    /// False when the folder does not exist on the gateway.
    var configured: Bool
    var root: String
    var sources: [SecretSource]
}

enum SecretKey {
    /// Same rule as the gateway: a shell variable name.
    static func isValid(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first, key.count <= 128 else { return false }
        let letters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_")
        let allowed = letters.union(CharacterSet(charactersIn: "0123456789"))
        return letters.contains(first) && key.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func isValidFileName(_ name: String) -> Bool {
        name.range(of: #"^(?:[A-Za-z0-9][A-Za-z0-9_-]{0,40}/)?[A-Za-z0-9][A-Za-z0-9_.-]{0,60}\.env$"#, options: .regularExpression) != nil
    }

    /// `DELETE` carries no body: the file and the name travel in the query, never the value.
    static func deletePath(source: String, key: String) -> String {
        var components = URLComponents()
        components.queryItems = [.init(name: "source", value: source), .init(name: "key", value: key)]
        // URLComponents leaves "+" as it is; the gateway reads it as a space.
        let query = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B") ?? ""
        return "/api/secrets/entries?\(query)"
    }
}
